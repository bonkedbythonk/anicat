import Foundation
import Network

/// The wire between the phone's remote and the Mac that is playing.
///
/// Newline-delimited JSON over the TCP connection Bonjour already
/// establishes. Newline is a safe delimiter precisely because `JSONEncoder`
/// escapes literal newlines inside strings as `\n`, so no encoded frame can
/// contain one: an anime title with a line break in it cannot split its own
/// frame in half.
public enum RemoteFrame: Codable, Sendable {
    /// Bumped whenever the Mac learns a verb the phone needs to know about
    /// before it can offer the control. A phone talking to an older Mac
    /// hides what that Mac cannot serve rather than drawing a button whose
    /// press is dropped by the framer with no feedback of any kind.
    public static let currentVersion = 1

    /// First frame a controller sends. Nothing else is honoured until the
    /// Mac has answered it, and a connection that never sends one is a
    /// discovery probe rather than a remote (see `RemoteHost.accept`).
    case hello(deviceId: String, deviceName: String)
    case helloAck(accepted: Bool, hostName: String)
    case command(RemoteCommand)
    case state(RemoteState)
    /// What this Mac can actually do, sent straight after `helloAck`.
    ///
    /// A separate frame rather than more fields on `helloAck`: adding an
    /// associated value to an existing case changes how that case decodes,
    /// so an older peer would fail on the one frame the handshake cannot
    /// afford to lose. An older Mac sends no `hostInfo` at all and the phone
    /// reads that as version 0, which is exactly what it is.
    case hostInfo(version: Int, features: [String])
    /// The audio and subtitle tracks of whatever the Mac has open, answered
    /// on request and again after a selection.
    ///
    /// Pulled rather than pushed on the 1 Hz state tick: the Mac reads them
    /// through `onFetchTracks`, which is a callback with a completion
    /// handler and not a stored list, so a tick that had to fetch would ask
    /// mpv for its whole track list once a second for the length of an
    /// episode to serve a sheet nobody has open.
    case tracks(audio: [RemoteTrack], subtitle: [RemoteTrack])
    /// "Here are my remembered releases, send me yours." Sent by whichever
    /// side dialled out.
    case syncOffer([SyncRelease])
    case syncReply([SyncRelease])

    // MARK: Streaming from the Mac
    //
    // Two frames on the control connection ask the Mac to resolve an episode
    // and hand back a token; the rest happen on their own short-lived
    // connections, one per range request the phone's player makes.

    case streamResolve(id: String, ask: StreamAsk)
    case streamResolved(id: String, grant: StreamGrant?, error: String?)
    /// Sent when the phone stops playing, so the Mac stops honouring the
    /// token. Also implied by the control connection dropping.
    case streamRelease(token: String)

    /// Opens a data connection: authenticates, names the grant and asks for
    /// one byte range, all in the first frame.
    ///
    /// Its own frame rather than an ordinary `hello`: that path answers with
    /// a `helloAck` and a state snapshot and starts the 1 Hz push, none of
    /// which a connection that exists to carry video wants.
    case helloData(deviceId: String, token: String, start: Int64, end: Int64)
    /// The Mac's answer on a data connection. **Everything after this
    /// frame's newline is raw video**, so both ends stop feeding the framer
    /// at this point -- an MKV is full of `0x0A`, and a framer left running
    /// would quietly eat the file looking for JSON.
    case dataHeader(length: Int64, contentType: String)
    case dataError(String)
}

/// What the phone asks the Mac to resolve. The same fields `StreamRequest`
/// carries, minus `preload`: a resolve the phone is about to play is never
/// speculative, and it must take the Mac's playing-file pin or
/// `retain_recent` can evict the file out from under the phone.
public struct StreamAsk: Codable, Sendable {
    public var catalog: String
    public var catalogId: Int64
    public var episode: Int64
    public var title: String?
    public var preferDub: Bool
    public var chosenName: String?
    public var resumeFraction: Double?

    public init(
        catalog: String,
        catalogId: Int64,
        episode: Int64,
        title: String?,
        preferDub: Bool,
        chosenName: String?,
        resumeFraction: Double?
    ) {
        self.catalog = catalog
        self.catalogId = catalogId
        self.episode = episode
        self.title = title
        self.preferDub = preferDub
        self.chosenName = chosenName
        self.resumeFraction = resumeFraction
    }
}

/// Permission to read one resolved file, and what it takes to serve it.
public struct StreamGrant: Codable, Sendable {
    /// A UUID, never a counter. It is the only thing between a data
    /// connection and a file, and a predictable one would be a weaker check
    /// than the device pairing it sits behind.
    public var token: String
    public var totalLength: Int64
    public var contentType: String

    public init(token: String, totalLength: Int64, contentType: String) {
        self.token = token
        self.totalLength = totalLength
        self.contentType = contentType
    }
}

/// One remembered release on the wire.
///
/// Deliberately its own type rather than the generated `FfiResolvedRelease`.
/// Conforming a type from another module to `Codable` after the fact works
/// but ties the wire format to whatever the bindings happen to look like,
/// and the bindings are a build artifact that is regenerated from the
/// compiled library on every `ffi.rs` change.
public struct SyncRelease: Codable, Sendable {
    public var catalog: String
    public var catalogId: Int64
    public var episodeNumber: Int64
    public var name: String
    public var magnet: String?
    public var torrentUrl: String?
    public var assumeBatch: Bool
    public var preferDub: Bool
    public var resolvedAt: String

    public init(
        catalog: String,
        catalogId: Int64,
        episodeNumber: Int64,
        name: String,
        magnet: String?,
        torrentUrl: String?,
        assumeBatch: Bool,
        preferDub: Bool,
        resolvedAt: String
    ) {
        self.catalog = catalog
        self.catalogId = catalogId
        self.episodeNumber = episodeNumber
        self.name = name
        self.magnet = magnet
        self.torrentUrl = torrentUrl
        self.assumeBatch = assumeBatch
        self.preferDub = preferDub
        self.resolvedAt = resolvedAt
    }
}

/// One selectable track on the wire.
///
/// Its own type rather than `PlayerTrack`, for the reason `SyncRelease`
/// gives: the wire format should not move when a player-side type does.
public struct RemoteTrack: Codable, Sendable, Identifiable, Hashable {
    /// mpv's own track id, in the string form `aid` and `sid` take.
    public var id: String
    public var lang: String?
    public var title: String?
    public var isSelected: Bool
    public var isForced: Bool

    public init(id: String, lang: String?, title: String?, isSelected: Bool, isForced: Bool) {
        self.id = id
        self.lang = lang
        self.title = title
        self.isSelected = isSelected
        self.isForced = isForced
    }

    /// The `sid` value that turns subtitles off. mpv spells it as a word,
    /// not an empty string.
    public static let off = "no"
}

/// Names for the optional verbs a Mac may or may not serve, as they travel
/// in `hostInfo`.
///
/// Strings on the wire and not an enum: an older peer must be able to carry
/// a name it has never heard of through `Codable` untouched, and a
/// `RawRepresentable` enum would refuse the frame outright.
public enum RemoteFeature {
    public static let speed = "speed"
    public static let tracks = "tracks"
    public static let skip = "skip"
    public static let autoNext = "autoNext"
    public static let browse = "browse"
    public static let fling = "fling"
}

/// What the phone can ask the Mac to do.
///
/// Deliberately the same verbs `PlayerController` already exposes rather
/// than anything mpv-level: the remote drives the app the way the app's own
/// chrome does, so auto-skip, progress recording and Discord presence all
/// keep working with no second path through them.
public enum RemoteCommand: Codable, Sendable {
    case playPause
    case seek(to: Double)
    case seekBy(Double)
    case nextEpisode
    case previousEpisode
    case setVolume(Double)
    case toggleMute
    case stop
    case setPlaybackRate(Double)
    /// Takes the offer the Mac's own Skip pill is making, which is why it
    /// carries no window of its own: the phone can only skip what the Mac is
    /// already showing a pill for, and a window sent from here would race
    /// the position the Mac has since moved to.
    case skipPendingWindow
    /// Explicit value rather than a toggle. A toggle sent twice by a phone
    /// on a flaky Wi-Fi lands where it started, and the phone's switch is
    /// drawn from what the Mac reports.
    case setAutoPlayNext(Bool)
    /// Asks for a `tracks` frame. Sent when the picker opens, not on a timer.
    case requestTracks
    case selectAudioTrack(String)
    /// nil turns subtitles off.
    case selectSubtitleTrack(String?)
    /// An `anicat://` address, so "play this on the Mac" reuses `DeepLink`
    /// and `handleDeepLink` stays the only thing that knows how to reach a
    /// screen.
    case open(link: String)
    /// The same address, plus where the phone had got to. Handing an episode
    /// over mid-play: the Mac opens it through `handleDeepLink` like any
    /// other link and then lands on this second rather than on whatever its
    /// own registry remembers, which is where *it* last stopped watching and
    /// not where the person carrying the phone is now.
    case openAt(link: String, seconds: Double)
}

/// What the Mac tells the phone it is doing.
public struct RemoteState: Codable, Sendable {
    public var hasPlayback: Bool
    public var isPlaying: Bool
    public var title: String
    public var episodeNumber: Int
    public var episodeTitle: String
    public var currentTime: Double
    public var duration: Double
    public var hasNext: Bool
    public var hasPrevious: Bool
    public var volume: Double
    public var isMuted: Bool
    public var isBuffering: Bool
    public var playbackRate: Double
    public var autoPlayNextEnabled: Bool
    /// What the Mac's Skip pill is offering right now ("Opening", "Ending",
    /// or the chapter's own name), nil when it is offering nothing. The
    /// label rather than the window: the phone draws a button, it does not
    /// need to know where the jump lands.
    public var skipLabel: String?
    /// The playing title's cover, as the Mac resolved it -- page, registry
    /// or the resolve itself. Sent as a URL string rather than left for the
    /// phone to look up by id: the Mac has already done that work for its
    /// own Now Playing tile, and a second lookup could disagree with it.
    public var coverUrl: String?

    public init(
        hasPlayback: Bool = false,
        isPlaying: Bool = false,
        title: String = "",
        episodeNumber: Int = 0,
        episodeTitle: String = "",
        currentTime: Double = 0,
        duration: Double = 0,
        hasNext: Bool = false,
        hasPrevious: Bool = false,
        volume: Double = 1,
        isMuted: Bool = false,
        isBuffering: Bool = false,
        playbackRate: Double = 1,
        autoPlayNextEnabled: Bool = true,
        skipLabel: String? = nil,
        coverUrl: String? = nil
    ) {
        self.hasPlayback = hasPlayback
        self.isPlaying = isPlaying
        self.title = title
        self.episodeNumber = episodeNumber
        self.episodeTitle = episodeTitle
        self.currentTime = currentTime
        self.duration = duration
        self.hasNext = hasNext
        self.hasPrevious = hasPrevious
        self.volume = volume
        self.isMuted = isMuted
        self.isBuffering = isBuffering
        self.playbackRate = playbackRate
        self.autoPlayNextEnabled = autoPlayNextEnabled
        self.skipLabel = skipLabel
        self.coverUrl = coverUrl
    }

    /// Decoded field by field with a default for every one, rather than
    /// letting the synthesised initialiser require them all.
    ///
    /// The two apps are built and installed separately -- one phone install
    /// away from a Mac pushing a state with a key the phone has never heard
    /// of, or missing one the phone now expects. A missing key throws, and
    /// `RemoteFramer.ingest` drops a frame that fails to decode *silently*,
    /// so the whole remote would go blank and stay blank with nothing logged
    /// anywhere. Every field added here from now on must be optional or
    /// carry a default for exactly that reason.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hasPlayback = try c.decodeIfPresent(Bool.self, forKey: .hasPlayback) ?? false
        isPlaying = try c.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber) ?? 0
        episodeTitle = try c.decodeIfPresent(String.self, forKey: .episodeTitle) ?? ""
        currentTime = try c.decodeIfPresent(Double.self, forKey: .currentTime) ?? 0
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        hasNext = try c.decodeIfPresent(Bool.self, forKey: .hasNext) ?? false
        hasPrevious = try c.decodeIfPresent(Bool.self, forKey: .hasPrevious) ?? false
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? 1
        isMuted = try c.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        isBuffering = try c.decodeIfPresent(Bool.self, forKey: .isBuffering) ?? false
        playbackRate = try c.decodeIfPresent(Double.self, forKey: .playbackRate) ?? 1
        autoPlayNextEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoPlayNextEnabled) ?? true
        skipLabel = try c.decodeIfPresent(String.self, forKey: .skipLabel)
        coverUrl = try c.decodeIfPresent(String.self, forKey: .coverUrl)
    }
}

/// Reads length-agnostic newline-delimited frames off a stream.
///
/// TCP is a byte stream, not a message stream: one `receive` can hand back
/// half a frame, or three of them at once. Everything that reads this
/// protocol goes through here so neither end has to rediscover that.
public struct RemoteFramer: Sendable {
    private var buffer = Data()

    public init() {}

    private static let delimiter = UInt8(ascii: "\n")

    /// Appends received bytes and returns whatever complete frames they
    /// completed. A frame that fails to decode is dropped rather than
    /// killing the connection — a peer from a future build may send a case
    /// this one has never heard of, and the rest of the stream is still
    /// perfectly readable.
    public mutating func ingest(_ data: Data) -> [RemoteFrame] {
        buffer.append(data)
        var frames: [RemoteFrame] = []
        while let index = buffer.firstIndex(of: Self.delimiter) {
            let line = buffer[buffer.startIndex..<index]
            buffer.removeSubrange(buffer.startIndex...index)
            guard !line.isEmpty else { continue }
            if let frame = try? JSONDecoder().decode(RemoteFrame.self, from: Data(line)) {
                frames.append(frame)
            }
        }
        return frames
    }

    public static func encode(_ frame: RemoteFrame) -> Data? {
        guard var data = try? JSONEncoder().encode(frame) else { return nil }
        data.append(delimiter)
        return data
    }
}

public extension NWConnection {
    /// Sends one frame, dropping it silently if it cannot be encoded.
    /// `.idempotent` and not a completion handler: every caller here is
    /// fire-and-forget state or a control verb, and the connection's own
    /// state handler is what reports a dead peer.
    func sendFrame(_ frame: RemoteFrame) {
        guard let data = RemoteFramer.encode(frame) else { return }
        send(content: data, completion: .idempotent)
    }
}
