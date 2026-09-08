import Foundation
import Network
import Observation

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

    static let pairedDevicesKey = "anicat_remote_paired_devices"

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
            apply(command)
        case .syncOffer(let rows):
            guard session.isApproved else { return }
            // Merge first, then answer with everything this Mac knows --
            // including what just arrived. The other device drops its own
            // rows back on the floor as older-or-equal, so one round trip
            // leaves both sides holding the same set.
            RemoteSync.merge(rows)
            session.connection.sendFrame(.syncReply(RemoteSync.export()))
        case .helloAck, .state, .syncReply:
            // Host-to-controller frames. A peer sending them is confused;
            // ignoring is cheaper than disconnecting over it.
            break
        }
    }

    private func drop(_ key: ObjectIdentifier) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        session.connection.cancel()
        if pendingPairing?.id == session.deviceId { pendingPairing = nil }
        refreshAttachment()
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
        case .open(let link):
            guard let url = URL(string: link), let deepLink = DeepLink(url: url) else { return }
            model.handleDeepLink(deepLink)
        }
        // Straight back rather than waiting for the next tick: the phone's
        // own button state is driven by what the Mac reports, so a full
        // second of a play button that has not flipped yet reads as a
        // dropped press and gets pressed again.
        pushState()
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
        let state = snapshot()
        for session in sessions.values where session.isApproved {
            session.connection.sendFrame(.state(state))
        }
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
                isBuffering: true
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
            isBuffering: controller.isBuffering
        )
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
