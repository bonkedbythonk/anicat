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
    /// First frame a controller sends. Nothing else is honoured until the
    /// Mac has answered it, and a connection that never sends one is a
    /// discovery probe rather than a remote (see `RemoteHost.accept`).
    case hello(deviceId: String, deviceName: String)
    case helloAck(accepted: Bool, hostName: String)
    case command(RemoteCommand)
    case state(RemoteState)
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
    /// An `anicat://` address, so "play this on the Mac" reuses `DeepLink`
    /// and `handleDeepLink` stays the only thing that knows how to reach a
    /// screen.
    case open(link: String)
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
        isBuffering: Bool = false
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
