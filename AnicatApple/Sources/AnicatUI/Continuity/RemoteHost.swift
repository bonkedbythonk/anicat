#if os(macOS)
import AppKit
#endif
import Foundation
import Network
import Observation
import AnicatCoreKit

/// The Mac's side of the phone remote: accepts controllers on the Bonjour
/// listener, applies their commands to the running player, and pushes back
/// what is on screen.
///
/// Commands go through `PlayerController`'s own public verbs rather than
/// anywhere near mpv, so a press on the phone takes exactly the path the
/// Mac's own chrome takes -- progress recording, auto-skip, Discord presence
/// and the next-episode preload all keep working with no second route
/// through them to keep in step. That includes `showControlsBriefly()`:
/// pausing from the couch pops the Mac's overlay up, which is the
/// confirmation you want from across the room.
@MainActor
@Observable
public final class RemoteHost {
    public static let shared = RemoteHost()

    /// A controller that has said hello and is not on the approved list.
    /// Drives the alert in `RootView`; nothing it sent is acted on until the
    /// answer comes back.
    public struct PairingRequest: Identifiable, Sendable {
        public let id: String
        public let deviceName: String
    }

    public private(set) var pendingPairing: PairingRequest?
    /// The name of whichever remote is currently attached, for the status
    /// row in Settings. Nil when nothing is controlling this Mac.
    public private(set) var attachedRemoteName: String?

    private var sessions: [ObjectIdentifier: Session] = [:]
    private var pushTask: Task<Void, Never>?
    /// Tokens a phone may read a resolved file with, and the loopback URL
    /// each one stands for. Minted per resolve, dropped when the phone says
    /// it stopped or when its control connection goes -- otherwise a phone
    /// that watched one episode would hold a handle to that file for the
    /// life of the process.
    private var streamGrants: [String: URL] = [:]
    /// Where a flung episode should land, held until the file is actually
    /// open. Seeking straight after `handleDeepLink` seeks the *outgoing*
    /// file -- the link only starts a resolve, and mpv is still on whatever
    /// was playing (or on nothing) for as long as that takes.
    private var pendingSeek: Double?
    private var relays: [ObjectIdentifier: StreamRelay] = [:]

    static let pairedDevicesKey = "anicat_remote_paired_devices"

    /// The optional verbs this build serves, announced in `hostInfo`. A verb
    /// goes in here in the same commit that teaches `apply` to honour it, so
    /// the two cannot drift.
    static let features: Set<String> = [
        RemoteFeature.speed,
        RemoteFeature.skip,
        RemoteFeature.autoNext,
        RemoteFeature.tracks,
        RemoteFeature.fling,
        RemoteFeature.upscale,
    ]

    private init() {}

    // MARK: - Accepting controllers

    /// Takes over a connection the Bonjour listener accepted.
    ///
    /// **Most connections handed here are not remotes.** `startBrowsing`
    /// resolves a peer by opening a connection, reading the host and port off
    /// it and cancelling without ever sending a byte, so every browse cycle
    /// on every phone on the LAN arrives here. That is why pairing is gated
    /// on the first `hello` frame and not on the accept: prompting per
    /// connection would throw an approval alert on the Mac every few seconds
    /// with nobody having touched anything.
    public func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        let session = Session(connection: connection)
        sessions[key] = session

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(key) }
            default:
                break
            }
        }
        connection.start(queue: .main)
        receive(session, key: key)
    }

    private func receive(_ session: Session, key: ObjectIdentifier) {
        session.connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                let frames = session.framer.ingest(data)
                Task { @MainActor in
                    for frame in frames { self.handle(frame, from: session, key: key) }
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in self.drop(key) }
                return
            }
            self.receive(session, key: key)
        }
    }

    private func handle(_ frame: RemoteFrame, from session: Session, key: ObjectIdentifier) {
        switch frame {
        case .hello(let deviceId, let deviceName):
            session.deviceId = deviceId
            session.deviceName = deviceName
            if Self.pairedDevices().contains(deviceId) {
                approve(session)
            } else {
                pendingPairing = PairingRequest(id: deviceId, deviceName: deviceName)
            }
        case .command(let command):
            // An unapproved controller is answered by silence, not by an
            // error: telling an unpaired device that it reached a real
            // Anicat is more than it needs to know.
            guard session.isApproved else { return }
            switch command {
            case .requestTracks:
                sendTracks(to: session)
            case .selectAudioTrack(let id):
                AppModel.shared?.playerController.onSelectAudioTrack?(id)
                // mpv applies the change before it reports it, so the answer
                // is fetched fresh rather than echoed back from here: a list
                // built from what we just asked for would show a selection
                // that had not happened if the track failed to load.
                sendTracks(to: session)
            case .selectSubtitleTrack(let id):
                AppModel.shared?.playerController.onSelectSubtitleTrack?(id)
                sendTracks(to: session)
            default:
                apply(command)
            }
        case .streamResolve(let id, let ask):
            guard session.isApproved else { return }
            Task { await self.grantStream(id: id, ask: ask, to: session) }
        case .streamRelease(let token):
            guard session.isApproved else { return }
            streamGrants.removeValue(forKey: token)
        case .helloData(let deviceId, let token, let start, let end):
            // Authenticated the same way a controller is -- the paired set,
            // not a secret of its own -- plus a token that names one file.
            // Deliberately not routed through `approve`: that answers with a
            // state snapshot and starts the 1 Hz push, and this connection
            // carries video and then closes.
            guard Self.pairedDevices().contains(deviceId), let url = streamGrants[token] else {
                session.connection.sendFrame(.dataError("not granted"))
                session.connection.cancel()
                return
            }
            sessions.removeValue(forKey: key)
            let relay = StreamRelay(connection: session.connection) { [weak self] in
                Task { @MainActor in self?.relays.removeValue(forKey: key) }
            }
            relays[key] = relay
            relay.start(url: url, start: start, end: end)
        case .syncOffer(let rows):
            guard session.isApproved else { return }
            // Merge first, then answer with everything this Mac knows --
            // including what just arrived. The other device drops its own
            // rows back on the floor as older-or-equal, so one round trip
            // leaves both sides holding the same set.
            RemoteSync.merge(rows)
            session.connection.sendFrame(.syncReply(RemoteSync.export()))
        case .helloAck, .hostInfo, .tracks, .state, .syncReply, .streamResolved, .dataHeader, .dataError:
            // Host-to-controller frames. A peer sending them is confused;
            // ignoring is cheaper than disconnecting over it.
            break
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        if let relay = relays.removeValue(forKey: key) { relay.cancel() }
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.connection.cancel()
        if pendingPairing?.id == session.deviceId { pendingPairing = nil }
        // A controller going away takes its grants with it. Data connections
        // are short-lived and already closed by the time this runs; what
        // this stops is a phone that quit mid-episode leaving a live handle
        // to a file behind it.
        if session.isApproved, !sessions.values.contains(where: { $0.isApproved }) {
            streamGrants.removeAll()
        }
        refreshAttachment()
    }

    /// Resolves an episode on this Mac and answers with a token the phone
    /// can read it through.
    ///
    /// `preload: false` on purpose: the phone is about to play this, so the
    /// file has to take `TorrentManager::playing_file` or `retain_recent`
    /// can evict it from under the reader. That pin is all `set_playing`
    /// does -- Discord presence and progress recording are Swift-side and
    /// are not touched here, so the Mac does not publish itself as watching
    /// something a phone is streaming.
    private func grantStream(id: String, ask: StreamAsk, to session: Session) async {
        guard let engine = AppModel.shared?.engine else {
            session.connection.sendFrame(.streamResolved(id: id, grant: nil, error: "engine not ready"))
            return
        }
        let request = StreamRequest(
            catalog: Self.catalog(named: ask.catalog) ?? .anilist,
            catalogId: ask.catalogId,
            episode: ask.episode,
            title: ask.title,
            preferDub: ask.preferDub,
            chosenName: ask.chosenName,
            resumeFraction: ask.resumeFraction,
            preload: false
        )
        do {
            let handle = try await engine.resolveStream(req: request)
            guard let url = URL(string: handle.url) else {
                session.connection.sendFrame(.streamResolved(id: id, grant: nil, error: "bad stream url"))
                return
            }
            // One byte, purely to read `Content-Range: bytes 0-0/TOTAL` back.
            // The route is registered for GET only, so a HEAD is a 405 and
            // there is no other way to learn the length from here.
            let (total, type) = try await Self.probe(url)
            let token = UUID().uuidString
            streamGrants[token] = url
            session.connection.sendFrame(.streamResolved(
                id: id,
                grant: StreamGrant(token: token, totalLength: total, contentType: type),
                error: nil
            ))
        } catch {
            session.connection.sendFrame(.streamResolved(id: id, grant: nil, error: error.localizedDescription))
        }
    }

    private static func probe(_ url: URL) async throws -> (Int64, String) {
        var request = URLRequest(url: url)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let range = http.value(forHTTPHeaderField: "Content-Range"),
              let total = range.split(separator: "/").last.flatMap({ Int64($0) }) else {
            throw NSError(
                domain: "Anicat",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "range server did not report a length"]
            )
        }
        return (total, http.value(forHTTPHeaderField: "Content-Type") ?? "video/x-matroska")
    }

    private static func catalog(named name: String) -> FfiCatalog? {
        switch name {
        case "anilist": return .anilist
        case "tmdb_movie": return .tmdbMovie
        case "tmdb_tv": return .tmdbTv
        case "mangadex": return .mangaDex
        default: return nil
        }
    }

    // MARK: - Pairing

    public func answerPairing(approved: Bool) {
        guard let request = pendingPairing else { return }
        pendingPairing = nil
        guard let session = sessions.values.first(where: { $0.deviceId == request.id }) else { return }
        if approved {
            var devices = Self.pairedDevices()
            devices.insert(request.id)
            UserDefaults.standard.set(Array(devices), forKey: Self.pairedDevicesKey)
            approve(session)
        } else {
            session.connection.sendFrame(.helloAck(accepted: false, hostName: Platform.deviceName))
            session.connection.cancel()
        }
    }

    /// Forgets every paired phone. Their next command is ignored and their
    /// next hello prompts again.
    public func unpairAll() {
        UserDefaults.standard.removeObject(forKey: Self.pairedDevicesKey)
        for session in sessions.values where session.isApproved {
            session.isApproved = false
            session.connection.cancel()
        }
        sessions = sessions.filter { !$0.value.isApproved }
        refreshAttachment()
    }

    public static func pairedDevices() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: pairedDevicesKey) ?? [])
    }

    private func approve(_ session: Session) {
        session.isApproved = true
        session.connection.sendFrame(.helloAck(accepted: true, hostName: Platform.deviceName))
        session.connection.sendFrame(.hostInfo(
            version: RemoteFrame.currentVersion,
            features: Array(Self.features)
        ))
        session.connection.sendFrame(.state(snapshot()))
        refreshAttachment()
        startPushing()
    }

    private func refreshAttachment() {
        attachedRemoteName = sessions.values.first { $0.isApproved }?.deviceName
        if attachedRemoteName == nil {
            pushTask?.cancel()
            pushTask = nil
        }
    }

    // MARK: - Commands

    private func apply(_ command: RemoteCommand) {
        guard let model = AppModel.shared else { return }
        let controller = model.playerController
        switch command {
        case .playPause: controller.togglePlayPause()
        case .seek(let seconds): controller.seek(to: seconds)
        case .seekBy(let delta): controller.seekRelative(by: delta)
        case .nextEpisode: controller.nextEpisode()
        case .previousEpisode: controller.previousEpisode()
        case .setVolume(let volume): controller.setVolume(volume)
        case .toggleMute: controller.toggleMute()
        case .stop: model.stopPlayback()
        case .setPlaybackRate(let rate): controller.setPlaybackRate(rate)
        case .skipPendingWindow: controller.skipPendingWindow()
        case .setAutoPlayNext(let enabled):
            guard controller.autoPlayNextEnabled != enabled else { break }
            controller.toggleAutoPlayNext()
        case .setUpscaling(let enabled):
            guard controller.isAnime4KEnabled != enabled else { break }
            // `toggleAnime4K`, not the stored property: it is what writes
            // `anicat_gpu_upscaling` and re-applies the shader chain to the
            // running file. Setting the property alone changes a Bool and
            // leaves the picture exactly as it was.
            controller.toggleAnime4K()
        case .requestTracks, .selectAudioTrack, .selectSubtitleTrack:
            // Answered in `handle`, which is the only place that knows which
            // controller asked and therefore where the `tracks` frame goes.
            return
        case .open(let link):
            guard let url = URL(string: link), let deepLink = DeepLink(url: url) else { return }
            Self.comeForward()
            model.handleDeepLink(deepLink)
        case .openAt(let link, let seconds):
            guard let url = URL(string: link), let deepLink = DeepLink(url: url) else { return }
            Self.comeForward()
            model.handleDeepLink(deepLink)
            pendingSeek = seconds
        }
        // Straight back rather than waiting for the next tick: the phone's
        // own button state is driven by what the Mac reports, so a full
        // second of a play button that has not flipped yet reads as a
        // dropped press and gets pressed again.
        pushState()
    }

    /// Reads the open file's tracks and answers one controller with them.
    private func sendTracks(to session: Session) {
        guard let controller = AppModel.shared?.playerController else { return }
        guard let fetch = controller.onFetchTracks else {
            session.connection.sendFrame(.tracks(audio: [], subtitle: []))
            return
        }
        fetch { audio, subtitle in
            session.connection.sendFrame(.tracks(
                audio: audio.map(Self.wire),
                subtitle: subtitle.map(Self.wire)
            ))
        }
    }

    private static func wire(_ track: PlayerTrack) -> RemoteTrack {
        RemoteTrack(
            id: track.id,
            lang: track.lang,
            title: track.title,
            isSelected: track.isSelected,
            isForced: track.isForced
        )
    }

    /// Brings the Mac's window forward before a remotely started play.
    ///
    /// The fullscreen entrance, the hidden toolbar and the hidden pointer all
    /// hang off `activeStreamURL` in `RootView`, and every one of them is a
    /// no-op for an app that is not active: AppKit will not run a fullscreen
    /// transition for a background app, so a stream started from the couch
    /// opened in a window with the menu bar still across the top and the
    /// cursor sitting on the picture. Nobody is at this keyboard -- the
    /// request came from a phone -- so there is no work here to steal focus
    /// from.
    /// Nothing to do on iOS, where this type exists only because the file
    /// compiles for both: a phone is never the host.
    private static func comeForward() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        AppWindow.main?.makeKeyAndOrderFront(nil)
        #endif
    }

    // MARK: - State

    /// One second, not the position tick rate. `onPositionChange` fires many
    /// times a second for the whole episode, and a socket write per tick buys
    /// a scrubber nobody can see move that precisely.
    private static let pushInterval = Duration.seconds(1)

    private func startPushing() {
        guard pushTask == nil else { return }
        pushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pushInterval)
                guard let self else { return }
                self.pushState()
            }
        }
    }

    /// Sends the current state to every approved controller. Called on the
    /// tick and straight after any command.
    public func pushState() {
        applyPendingSeekIfReady()
        let state = snapshot()
        for session in sessions.values where session.isApproved {
            session.connection.sendFrame(.state(state))
        }
    }

    /// Lands a flung episode once the new file is open.
    ///
    /// Driven off the 1 Hz push rather than a callback because
    /// `awaitingNewFile` -- which `resolveAndPlay` holds until
    /// MPV_EVENT_FILE_LOADED -- is exactly the flag that says the seek would
    /// otherwise hit the outgoing file, and nothing here is notified when it
    /// clears. A second of latency on a handover that already took a resolve
    /// is not worth a second notification path.
    private func applyPendingSeekIfReady() {
        guard let seconds = pendingSeek,
              let model = AppModel.shared,
              model.activeStreamURL != nil else { return }
        let controller = model.playerController
        guard !controller.awaitingNewFile, controller.duration > 0 else { return }
        pendingSeek = nil
        controller.seek(to: min(seconds, controller.duration))
    }

    private func snapshot() -> RemoteState {
        guard let model = AppModel.shared, model.activeStreamURL != nil else {
            return RemoteState()
        }
        let controller = model.playerController
        // `awaitingNewFile` is set from `resolveAndPlay` until
        // MPV_EVENT_FILE_LOADED because the outgoing file's last tick would
        // otherwise be read as the new episode's. Echoing time-pos over the
        // wire during that window puts the same stale number on the phone --
        // 1438 of 1440 for an episode that just started. Title and episode
        // are already the new ones, so only the clock is withheld.
        if controller.awaitingNewFile {
            return RemoteState(
                hasPlayback: true,
                isPlaying: controller.isPlaying,
                title: controller.title,
                episodeNumber: controller.episodeNumber,
                episodeTitle: controller.episodeTitle,
                hasNext: controller.hasNextEpisode,
                hasPrevious: controller.hasPreviousEpisode,
                volume: controller.volume,
                isMuted: controller.isMuted,
                isBuffering: true,
                playbackRate: controller.playbackRate,
                autoPlayNextEnabled: controller.autoPlayNextEnabled,
                upscalingEnabled: controller.isAnime4KEnabled
            )
        }
        return RemoteState(
            hasPlayback: true,
            isPlaying: controller.isPlaying,
            title: controller.title,
            episodeNumber: controller.episodeNumber,
            episodeTitle: controller.episodeTitle,
            currentTime: controller.currentTime,
            duration: controller.duration,
            hasNext: controller.hasNextEpisode,
            hasPrevious: controller.hasPreviousEpisode,
            volume: controller.volume,
            isMuted: controller.isMuted,
            isBuffering: controller.isBuffering,
            playbackRate: controller.playbackRate,
            autoPlayNextEnabled: controller.autoPlayNextEnabled,
            upscalingEnabled: controller.isAnime4KEnabled,
            skipLabel: Self.skipLabel(for: controller),
            coverUrl: Self.coverURL(for: model)?.absoluteString
        )
    }

    /// The playing title's cover, resolved the same way the Mac's own Now
    /// Playing tile resolves it: the open page first, then what the resolve
    /// carried, then the registry. Sharing that order is the point -- two
    /// lookups that could disagree would show the phone a different poster
    /// from the one on the Mac's own lock screen.
    private static func coverURL(for model: AppModel) -> URL? {
        guard let catalogId = model.currentPlaybackCatalogId else { return nil }
        let pageCover = model.selectedMediaDetails?.id == catalogId
            ? model.selectedMediaDetails?.coverURL
            : nil
        return pageCover ?? model.playbackCoverURL
            ?? model.registryCover(catalog: model.currentPlaybackCatalog, id: catalogId)
    }

    /// The offer the Mac's own Skip pill is making, or nil.
    ///
    /// Gated exactly like `PlayerView.skipPillWindow`: with auto-skip on the
    /// jump has already happened by the time a phone could press anything,
    /// and during the next-episode countdown the pill is not on screen. A
    /// remote button that outlived the Mac's own would seek into the middle
    /// of a window nobody is in any more.
    private static func skipLabel(for controller: PlayerController) -> String? {
        guard !controller.autoSkipEnabled, !controller.nextEpisodeCountdown.isVisible else { return nil }
        return controller.pendingSkipWindow?.flashLabel
    }

    /// One controller's connection and the parser state that belongs to it.
    /// A class because the framer is mutated from the receive callback and
    /// every session needs its own half-frame buffer.
    ///
    /// `@unchecked Sendable` because the connection is started on `.main`,
    /// so the receive callback that mutates `framer` and the MainActor that
    /// reads the rest are the same queue -- but the compiler cannot see that
    /// a `DispatchQueue.main` callback and `@MainActor` are the same place.
    private final class Session: @unchecked Sendable {
        let connection: NWConnection
        var framer = RemoteFramer()
        var deviceId: String?
        var deviceName: String?
        var isApproved = false

        init(connection: NWConnection) {
            self.connection = connection
        }
    }
}
