#if os(macOS)
import Foundation
import Network
import Observation

/// Play on TV: the picture goes to a Chromecast, upscaled; the sound stays
/// on the Mac (AirPods included).
///
/// The Mac player keeps playing the episode with `vid=no`. Everything
/// `AppModel` drives from its position (progress, the 85% watched mark,
/// skip, auto-next, Discord, Now Playing) keeps working because nothing
/// about that player changes but its picture. A `CastEncoder` turns the
/// same stream URL into a growing 4K fragmented MP4 that `CastStreamServer`
/// hands to the TV as HLS segments.
///
/// The TV is the clock: the receiver cannot be steered finely, mpv can. The
/// loop below extrapolates the receiver's position between status polls and
/// nudges the Mac's `speed` a few percent to close small drift; past half a
/// second it pauses the Mac (TV behind) or seeks it forward (TV ahead). Seeks, pauses and episode changes go the other way:
/// a seek restarts the encode at the new position and loads it on the TV.
@MainActor
@Observable
final class CastSession {
    enum Phase: Equatable {
        case idle, connecting, starting, playing, buffering
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var device: CastDevice?
    var isActive: Bool { device != nil }
    let discovery = CastDiscovery()

    /// How far the Mac's sound runs behind the TV's position, in seconds.
    /// The TV shows a frame some time after its receiver reports it, and
    /// that delay is the TV's own: there is no way to read it, so it is the
    /// viewer's to set.
    var audioDelay: Double = UserDefaults.standard.double(forKey: CastSession.audioDelayKey) {
        didSet { UserDefaults.standard.set(audioDelay, forKey: Self.audioDelayKey) }
    }
    static let audioDelayKey = "anicat_cast_audio_delay"

    /// Where the sound plays: false is the Mac (AirPods included), the
    /// stream stays silent and the Mac player is the one heard; true puts
    /// the audio track in the stream and mutes the Mac, which keeps playing
    /// for progress, skip and auto-next. Switching mid-cast restarts the
    /// stream, since the audio is part of the encode.
    var soundOnTV: Bool = UserDefaults.standard.bool(forKey: CastSession.soundOnTVKey) {
        didSet {
            guard soundOnTV != oldValue else { return }
            UserDefaults.standard.set(soundOnTV, forKey: Self.soundOnTVKey)
            guard isActive, phase != .connecting, let controller else { return }
            applyMacSound()
            beginStream(at: controller.currentTime)
        }
    }
    static let soundOnTVKey = "anicat_cast_sound_on_tv"

    /// The delay applies to the Mac's sound only; with the sound in the
    /// stream, picture and sound already arrive together.
    private var macAudioDelay: Double { soundOnTV ? 0 : audioDelay }

    private func applyMacSound() {
        guard let controller else { return }
        controller.onSetMuted?(soundOnTV || controller.isMuted)
    }

    @ObservationIgnored weak var controller: PlayerController?
    @ObservationIgnored private var channel: CastChannel?
    @ObservationIgnored private var server: CastStreamServer?
    @ObservationIgnored private var port: UInt16 = 0
    @ObservationIgnored private var encoder: CastEncoder?
    @ObservationIgnored private var output: URL?
    /// The mpv `path` being encoded; a different one means the player moved
    /// to another episode.
    @ObservationIgnored private var sourcePath: String?
    /// Episode time at the stream's 0.
    @ObservationIgnored private var streamBase: Double = 0
    @ObservationIgnored private var lastStatus: CastChannel.MediaStatus?
    /// Between a LOAD and the TV's first PLAYING: the Mac is held, and no
    /// sync, pause or seek is sent on.
    @ObservationIgnored private var awaitingStart = false
    /// The Mac is paused by this session (TV buffering, stream starting),
    /// not by the viewer.
    @ObservationIgnored private var holdingMac = false
    /// The TV is paused by this session while the Mac waits for data.
    @ObservationIgnored private var holdingTV = false
    @ObservationIgnored private var lastHoldChange: TimeInterval = 0
    @ObservationIgnored private var viewerPaused = false
    @ObservationIgnored private var lastViewerChange: TimeInterval = 0
    @ObservationIgnored private var lastSyncSeek: TimeInterval = 0
    @ObservationIgnored private var appliedSpeed: Double = 1
    @ObservationIgnored private var syncCount = 0
    @ObservationIgnored private var replacedMediaSession: Int?
    /// Index into `bitrates` for this cast; reset on every new cast, since
    /// the Wi-Fi that failed tonight may be fine tomorrow.
    @ObservationIgnored private var bitrateStep = 0
    @ObservationIgnored private var bufferingSince: TimeInterval?

    /// Mb/s, highest first. 14 kept up over the 55POS9002's Wi-Fi most of
    /// one evening and then fell to about 2 Mb/s delivered (23 s of video in
    /// 150 s, the Mac's send queue frozen at 669 KB). 4K HEVC anime holds up
    /// well at 10; the lower steps trade detail for not stopping.
    private static let bitrates = [10, 7, 5]
    /// Stalling this long means the link is not keeping up, rather than the
    /// TV filling its buffer after a seek. Measured from the first BUFFERING
    /// and cleared only by `recoveredAfter` of unbroken play: the stuck TV
    /// flipped PLAYING/BUFFERING every half second, which a "continuous
    /// buffering" rule never sees.
    private static let stallLimit: TimeInterval = 6
    private static let recoveredAfter: TimeInterval = 3
    /// Encoded seconds past the TV that rule out a slow source.
    private static let healthyLead: Double = 15
    @ObservationIgnored private var playingSince: TimeInterval = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    @ObservationIgnored private var seekTask: Task<Void, Never>?
    /// A viewer seek is waiting out its debounce. The Mac is already at the
    /// new spot and the TV is not, so the sync must not chase the TV: it
    /// seeked the Mac back 5-9 s within the 900 ms, the viewer seeked again,
    /// and one scrub became seven stream restarts in 25 s.
    @ObservationIgnored private var seekPending = false
    /// The Mac is paused until then to let a TV that fell behind catch up.
    @ObservationIgnored private var catchUpUntil: TimeInterval = 0
    /// Further off than any sync correction: the TV did not drift, it
    /// restarted. After a stall the TV's player rewinds to the stream's
    /// start by itself (365 s back, with or without re-requesting the file),
    /// and following it jumped the Mac 66 s back to where the cast began.
    private static let restartDrift: Double = 5

    private static var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    /// How far the encode may run past the TV. Enough to ride out a Wi-Fi
    /// hiccup or a slow stretch of torrent; more only heats the Mac.
    private static let encodeLead: Double = 60

    func start(_ device: CastDevice) {
        if isActive { stop() }
        guard let controller, controller.onReadProperty != nil else { return }
        self.device = device
        phase = .connecting
        // Picking a TV means watching. Taking the player's pause state over
        // started casts paused: the click that opens the picker pauses the
        // video when it lands as the controls fade, and in both casts the
        // owner started that way the Mac stayed paused and silent.
        viewerPaused = false
        bitrateStep = 0
        // A cast that ended with the app (quit or killed mid-stream) never
        // ran `stop`, and left its 160 MB file behind.
        try? FileManager.default.removeItem(at: Self.cacheDirectory)
        generation += 1
        let generation = generation
        Task {
            do {
                let server = CastStreamServer()
                let port = try await server.start()
                self.server = server
                self.port = port
                // The first connection a freshly launched app makes to the TV
                // can sit in "preparing" indefinitely, Local Network allowed
                // or not, while a second one made moments later connects at
                // once: on most launches of one evening the first attempt
                // timed out, and every retry in the same process connected
                // within a second. Why is not known.
                // So a short first try, then a fresh connection.
                var channel = makeChannel(device.endpoint)
                do {
                    try await channel.open(timeout: .seconds(5))
                } catch {
                    guard generation == self.generation else { return }
                    AppLog.write("[cast] first connect stalled (\(error.localizedDescription)), retrying")
                    channel.close()
                    channel = makeChannel(device.endpoint)
                    try await channel.open(timeout: .seconds(20))
                }
                guard generation == self.generation else { return }
                AppLog.write("[cast] connected to \(device.name)")
                controller.onSetVideoEnabled?(false)
                applyMacSound()
                beginStream(at: controller.currentTime)
                startSyncLoop()
            } catch {
                guard generation == self.generation else { return }
                fail("Could not reach \(device.name): \(error.localizedDescription). Check that the TV is on and on this network.")
            }
        }
    }

    private func makeChannel(_ endpoint: NWEndpoint) -> CastChannel {
        let channel = CastChannel(endpoint: endpoint)
        channel.onMediaStatus = { [weak self] status in self?.handle(status) }
        channel.onLoadFailed = { [weak self] reason in self?.fail("The TV refused the stream (\(reason))") }
        channel.onClosed = { [weak self] reason in self?.fail("Casting ended: \(reason)") }
        self.channel = channel
        return channel
    }

    func stop() {
        guard isActive else { return }
        generation += 1
        syncTask?.cancel()
        seekTask?.cancel()
        encoder?.cancel()
        server?.stop()
        channel?.close()
        syncTask = nil
        encoder = nil
        server = nil
        channel = nil
        lastStatus = nil
        sourcePath = nil
        awaitingStart = false
        seekPending = false
        if holdingMac { hold(false) }
        if let controller {
            controller.onSetVideoEnabled?(true)
            controller.onSetMuted?(controller.isMuted)
            controller.onSetSpeed?(controller.playbackRate)
        }
        appliedSpeed = 1
        removeOutput()
        device = nil
        phase = .idle
        AppLog.write("[cast] stopped")
    }

    // MARK: - From the player

    /// Every pause edge of `PlayerController.isPlaying`.
    func playingChanged(_ playing: Bool) {
        // mpv echoes the session's own holds back through its `pause`
        // observer a moment later; those are not the viewer's.
        guard isActive, !holdingMac, !awaitingStart, Self.now - lastHoldChange > 0.5,
              Self.now > catchUpUntil + 0.5 else { return }
        viewerPaused = !playing
        lastViewerChange = Self.now
        // The viewer's own pause or play overrules a hold for the Mac's
        // buffering; left set, it would have stopped all sync for good.
        holdingTV = false
        playing ? channel?.play() : channel?.pause()
    }

    /// A seek the viewer (or skip) asked for. Scrubbing calls this per drag
    /// tick, and each restart is a new encode, so only where the drag
    /// settles is played.
    func viewerSeeked(to position: Double) {
        // While connecting there is no stream to move yet, and the connect
        // starts from wherever the player is once it lands. An auto-skip
        // during the connect started a stream on the unopened channel.
        guard isActive, phase != .connecting else { return }
        seekTask?.cancel()
        seekPending = true
        let file = sourcePath
        seekTask = Task { [weak self] in
            // Long enough to cover a run of +5 s presses (the owner's came
            // 0.6 and 1.4 s apart): each restart costs the TV two seconds
            // of black, so one restart at the end beats three on the way.
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let self else { return }
            // A new file is loading: the next-file restart in the sync
            // places the stream, and it waits for this flag to clear.
            guard self.controller?.awaitingNewFile == false else {
                self.seekPending = false
                return
            }
            // The seek was for the file playing when it was made; if the
            // player has moved on, it means nothing for the new one.
            let now = await self.readProperties(["path"])["path"]
            guard !Task.isCancelled else { return }
            guard now == file else {
                self.seekPending = false
                AppLog.write("[cast] dropped a seek made for the previous file")
                return
            }
            self.beginStream(at: position)
        }
    }

    // MARK: - Stream

    private func beginStream(at position: Double) {
        guard let controller, let server, let channel else { return }
        generation += 1
        let generation = generation
        encoder?.cancel()
        removeOutput()
        awaitingStart = true
        seekPending = false
        phase = .starting
        bufferingSince = nil
        holdingTV = false
        hold(true)
        replacedMediaSession = channel.currentMediaSessionId
        channel.supersedeLoad()
        Task {
            let props = await readProperties(["path", "sid", "height", "container-fps", "sub-ass-style-overrides", "sub-scale", "aid"])
            guard generation == self.generation, let url = props["path"] else { return }
            let directory = Self.cacheDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let token = UUID().uuidString
            let output = directory.appendingPathComponent("\(token).mp4")
            FileManager.default.createFile(atPath: output.path, contents: nil)

            let height = props["height"].flatMap(Int.init) ?? 0
            let upscale = controller.isAnime4KEnabled && !controller.isLiveAction && height < 2160
            var subtitleOptions = SubtitleStyle.current.textOptions
            if let overrides = props["sub-ass-style-overrides"] { subtitleOptions.append(("sub-ass-style-overrides", overrides)) }
            if let scale = props["sub-scale"] { subtitleOptions.append(("sub-scale", scale)) }
            let fps = props["container-fps"].flatMap(Double.init) ?? 24
            let encoder = CastEncoder()
            encoder.setLimit(position + Self.encodeLead)
            encoder.start(CastEncoder.Job(
                url: url,
                start: position,
                output: output,
                subtitleId: props["sid"].flatMap { $0 == "no" ? nil : $0 },
                audioId: soundOnTV ? props["aid"].flatMap { $0 == "no" ? nil : $0 } : nil,
                subtitleOptions: subtitleOptions,
                videoFilter: CastEncoder.videoFilter(shaderPath: upscale ? Self.shaderFile() : nil),
                fps: fps,
                megabits: Self.bitrates[bitrateStep]))
            self.encoder = encoder
            self.output = output
            sourcePath = url
            streamBase = position
            lastStatus = nil
            // Every segment to the end of the episode, listed before any of
            // them exists: a VOD playlist, so the TV knows the length and
            // treats a lost segment as one to fetch again.
            let segment = Double(CastEncoder.gop(fps: fps)) / (fps > 0 ? fps : 24)
            let remaining = max(controller.duration - position, segment)
            let count = Int((remaining / segment).rounded(.up))
            var playlist = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:\(Int(segment.rounded(.up)))\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-MAP:URI=\"init.mp4\"\n"
            for index in 0..<count {
                let length = index == count - 1 ? remaining - segment * Double(count - 1) : segment
                playlist += String(format: "#EXTINF:%.3f,\n%d.m4s\n", length, index)
            }
            playlist += "#EXT-X-ENDLIST\n"
            let base = position
            server.serve(CastStreamServer.Stream(
                file: output, token: token, mediaPlaylist: playlist, audio: soundOnTV,
                megabits: Self.bitrates[bitrateStep],
                isFinished: { [encoder] in encoder.isFinished },
                wants: { [encoder] index in encoder.setLimit(base + segment * Double(index + 1) + 10) }))
            AppLog.write("[cast] encoding from \(Int(position))s, upscale \(upscale), \(Self.bitrates[bitrateStep]) Mb/s")

            // The first fragment is a whole two-second GOP. LOADing before it
            // exists has the receiver open the URL, read only the header and
            // report a failed load.
            for _ in 0..<80 {
                let size = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
                if size > 1_000_000 || encoder.isFinished { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard generation == self.generation else { return }
            guard let host = channel.localHost else {
                fail("No network address for this Mac")
                return
            }
            channel.load(url: "http://\(host):\(port)/\(token)/index.m3u8", duration: remaining)
        }
    }

    private func handle(_ status: CastChannel.MediaStatus) {
        guard isActive else { return }
        // After a seek the TV goes on reporting the old stream until the new
        // LOAD lands. Its PLAYING was read as the new one starting (the Mac
        // jumped by the old stream's whole position), and its ERROR, when
        // the server cut it off, ended the cast.
        if let replaced = replacedMediaSession {
            guard status.mediaSessionId != replaced else { return }
            replacedMediaSession = nil
        }
        lastStatus = status
        switch status.playerState {
        case "PLAYING":
            if awaitingStart {
                awaitingStart = false
                // Never into the last seconds: a stream started at the end of
                // a file is a bug upstream, and following it there makes
                // autoplay mark the episode watched and move on.
                let target = streamBase + status.currentTime - macAudioDelay
                if let duration = controller?.duration, duration > 0, target > duration - 3 {
                    AppLog.write("[cast] refused to move the Mac to \(Int(target))s of \(Int(duration))s")
                } else {
                    controller?.onSeek?(target)
                }
                lastSyncSeek = Self.now
                AppLog.write("[cast] TV playing")
                // LOAD always autoplays; a cast started (or a seek made) while
                // paused left the TV playing under a paused Mac.
                if viewerPaused { channel?.pause() }
            }
            if phase == .buffering { AppLog.write(String(format: "[cast] TV playing again at %.2fs", streamBase + status.currentTime)) }
            if phase != .playing { playingSince = Self.now }
            phase = .playing
            if holdingMac {
                hold(false)
            } else if !awaitingStart, viewerPaused, controller?.isPlaying == false,
                      Self.now - lastViewerChange > 2 {
                // Played on the TV's own remote: follow it, as for a pause.
                // Without this the TV played on under a silent, paused Mac.
                // The two seconds keep a status sent before a pause from the
                // Mac had landed from undoing that pause.
                viewerPaused = false
                controller?.play()
            }
        case "BUFFERING":
            guard !awaitingStart else { return }
            if phase != .buffering { AppLog.write(String(format: "[cast] TV buffering at %.2fs", streamBase + status.currentTime)) }
            phase = .buffering
            if bufferingSince == nil { bufferingSince = Self.now }
            hold(true)
        case "PAUSED":
            // Paused on the TV's own remote: follow it. Not when this session
            // paused it for the Mac's own buffering.
            if !awaitingStart, !holdingMac, !holdingTV, controller?.isPlaying == true {
                viewerPaused = true
                controller?.pause()
            }
        case "IDLE":
            // While a stream is starting, an ERROR is the one it replaced,
            // cut off by the server: a seek during a stream the TV had opened
            // but not yet played ended the cast, its session not known yet to
            // filter by. A refused new stream answers with LOAD_FAILED.
            if status.idleReason == "ERROR", !awaitingStart { fail("The TV stopped the stream") }
        default:
            break
        }
    }

    private func startSyncLoop() {
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, self.isActive else { return }
                tick += 1
                if tick % 4 == 0 { self.channel?.requestStatus() }
                await self.sync()
            }
        }
    }

    private func sync() async {
        // The player went away (closed, or its surface torn down): there is
        // nothing left to cast.
        guard let controller, controller.onReadProperty != nil else {
            stop()
            return
        }
        guard !awaitingStart, !seekPending, !controller.awaitingNewFile, Self.now > catchUpUntil else { return }
        if phase == .playing, Self.now - playingSince > Self.recoveredAfter { bufferingSince = nil }
        if let since = bufferingSince, Self.now - since > Self.stallLimit {
            // Only a stall with video already waiting is the link's fault.
            // A new torrent episode starved the encoder itself (3-5 s ahead,
            // first fragment 8 s after each start), and restarting threw
            // that progress away: five restarts from the same 0:16 in a
            // minute, the Mac held silent through all of them.
            let tv = streamBase + (lastStatus?.currentTime ?? 0)
            if let encoder, encoder.position - tv > Self.healthyLead {
                stepDownBitrate()
                return
            }
        }
        let props = await readProperties(["path", "time-pos", "paused-for-cache"])
        guard isActive, !awaitingStart, !seekPending else { return }
        if let path = props["path"], path != sourcePath {
            // A seek still pending for the old file belongs to it. Autoplay
            // jumps the finishing episode to its end; that jump, landing on
            // the new episode, started its stream at 24:13, the Mac followed
            // the TV there, autoplay fired again, and episodes 5 and 6 were
            // marked watched on AniList in under a minute.
            seekTask?.cancel()
            var start = props["time-pos"].flatMap(Double.init) ?? 0
            if controller.duration > 0, start > controller.duration - 5 { start = 0 }
            AppLog.write("[cast] next file, restarting the stream at \(Int(start))s")
            beginStream(at: start)
            return
        }
        // The other direction of a buffering hold: the Mac's own copy of a
        // torrent still downloading waits for pieces, mpv pauses for cache,
        // and the TV played on while the sync kept seeking a Mac that could
        // not play, which is silence. Hold the TV until the Mac has data.
        let macCaching = props["paused-for-cache"] == "yes"
        if macCaching != holdingTV, !holdingMac, !viewerPaused {
            holdingTV = macCaching
            lastHoldChange = Self.now
            AppLog.write("[cast] Mac \(macCaching ? "waiting for data, holding the TV" : "has data again, resuming the TV")")
            macCaching ? channel?.pause() : channel?.play()
        }
        if holdingTV { return }
        guard let status = lastStatus, status.playerState == "PLAYING", !holdingMac, controller.isPlaying,
              let mac = props["time-pos"].flatMap(Double.init) else { return }
        let tv = streamBase + status.currentTime + (Self.now - status.receivedAt)
        encoder?.setLimit(tv + Self.encodeLead)
        let target = tv - macAudioDelay
        let drift = mac - target
        syncCount += 1
        if syncCount % 20 == 0 {
            AppLog.write(String(format: "[cast] drift %+.3fs speed %.3f, encoder %.0fs ahead", drift, appliedSpeed, (encoder?.position ?? tv) - tv))
        }
        if abs(drift) > Self.restartDrift, status.currentTime > Self.restartDrift,
           let encoder, tv < encoder.position {
            // A seek on the TV's own remote: 20 s back, nothing asked again
            // (it was still in the TV's buffer). Restarting at the Mac's spot
            // undid it with six seconds of black. Followed while the TV is
            // inside what is encoded and not back at the stream's start,
            // which is where its own rewind after a stall lands.
            guard Self.now - lastSyncSeek > 2 else { return }
            lastSyncSeek = Self.now
            setSpeed(1)
            AppLog.write(String(format: "[cast] TV seeked %+.0fs by itself, Mac follows to %.0fs", -drift, tv))
            controller.onSeek?(target)
        } else if abs(drift) > Self.restartDrift {
            AppLog.write(String(format: "[cast] TV %.0fs off the Mac, restarting the stream at the Mac's %.0fs", -drift, mac))
            beginStream(at: mac)
        } else if abs(drift) > 0.5 {
            // A seek takes mpv a moment to land; seeking again before it has
            // reads the old position and chases it.
            guard Self.now - lastSyncSeek > 2 else { return }
            // Logged every time: the owner saw "sets back the episode a
            // second and replays parts", and the 5 s drift sample cannot
            // tell a Mac correction from the TV jumping.
            setSpeed(1)
            lastSyncSeek = Self.now
            if drift > 0 {
                // The Mac is ahead: the TV slowed down without reporting
                // BUFFERING (0.98 s of video in 2.1 s). Seeking the Mac back
                // replayed the last half second of sound, which the owner
                // heard; a pause the length of the gap is silence instead.
                AppLog.write(String(format: "[cast] Mac paused %.2fs for the TV to catch up (TV %.2fs)", drift, tv))
                catchUpUntil = Self.now + drift
                lastHoldChange = Self.now
                controller.onSetPause?(true)
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(drift))
                    // A hold for the TV's buffering, or the viewer's pause,
                    // that began meanwhile keeps the Mac paused.
                    guard let self, self.isActive, !self.holdingMac, !self.viewerPaused else { return }
                    self.lastHoldChange = Self.now
                    self.controller?.onSetPause?(false)
                }
            } else {
                AppLog.write(String(format: "[cast] Mac seek %+.2fs to the TV (TV %.2fs)", -drift, tv))
                controller.onSeek?(target)
            }
        } else if abs(drift) > 0.03 {
            // Ahead plays slower, behind faster; at most 5%, which mpv's
            // scaletempo keeps at pitch.
            setSpeed(1 - max(-0.05, min(0.05, drift * 0.5)))
        } else {
            setSpeed(1)
        }
    }

    /// Restarts the stream at a lower bitrate from where the TV stopped. Even
    /// at the lowest step a restart is the right move: the TV stuck at
    /// 21:22 never resumed by itself, its player had stopped reading.
    private func stepDownBitrate() {
        bufferingSince = nil
        let resume = streamBase + (lastStatus?.currentTime ?? 0)
        if bitrateStep < Self.bitrates.count - 1 {
            bitrateStep += 1
            controller?.flashHUD("Slow Wi-Fi to the TV: lowering quality", symbol: "wifi.exclamationmark")
        }
        AppLog.write("[cast] TV buffered over \(Int(Self.stallLimit))s, restarting at \(Self.bitrates[bitrateStep]) Mb/s from \(Int(resume))s")
        beginStream(at: resume)
    }

    private func setSpeed(_ speed: Double) {
        guard abs(speed - appliedSpeed) > 0.002 else { return }
        appliedSpeed = speed
        controller?.onSetSpeed?(speed)
    }

    private func hold(_ on: Bool) {
        guard on != holdingMac else { return }
        holdingMac = on
        lastHoldChange = Self.now
        if on {
            controller?.onSetPause?(true)
        } else if !viewerPaused {
            controller?.onSetPause?(false)
        }
    }

    private func fail(_ message: String) {
        AppLog.write("[cast] \(message)")
        stop()
        phase = .failed(message)
        controller?.flashHUD(message, symbol: "tv")
    }

    // MARK: - Helpers

    /// mpv property reads block on its core lock, so they run off the main
    /// actor.
    private func readProperties(_ names: [String]) async -> [String: String] {
        guard let read = controller?.onReadProperty else { return [:] }
        return await Task.detached {
            var values: [String: String] = [:]
            for name in names { values[name] = read(name) }
            return values
        }.value
    }

    private func removeOutput() {
        if let output { try? FileManager.default.removeItem(at: output) }
        output = nil
    }

    /// About 2.5 GB an episode at 14 Mb/s, so Caches, and each file is
    /// deleted as soon as the stream it fed is replaced.
    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anicat/cast", isDirectory: true)
    }

    /// The libplacebo filter takes one shader file, so the player's chain is
    /// joined into one, in order.
    private static func shaderFile() -> String? {
        let paths = Anime4KPreset.on.resolveMpvShaderString().split(separator: ":").map(String.init)
        guard !paths.isEmpty else { return nil }
        var combined = Data()
        for path in paths {
            guard let data = FileManager.default.contents(atPath: path) else { return nil }
            combined += data + Data("\n".utf8)
        }
        let file = cacheDirectory.appendingPathComponent("anime4k.glsl")
        guard (try? combined.write(to: file)) != nil else { return nil }
        return file.path
    }
}
#endif
