#if os(macOS)
import Foundation
import Network

/// One Cast V2 connection to a Chromecast receiver: TLS on port 8009,
/// length-prefixed protobuf `CastMessage`s carrying JSON. Only the Default
/// Media Receiver is driven, so the whole protocol here is CONNECT, LAUNCH,
/// LOAD, PLAY/PAUSE/STOP, GET_STATUS and the heartbeat.
///
/// The protobuf is written by hand: `CastMessage` has six fields, all
/// strings or enums, and a generated dependency for that is more code than
/// the encoder below.
@MainActor
final class CastChannel {
    struct MediaStatus {
        var playerState: String
        var idleReason: String?
        var currentTime: Double
        /// `ProcessInfo.systemUptime` when the message arrived. The sync
        /// loop extrapolates the receiver's clock from here between polls.
        var receivedAt: TimeInterval
        /// The receiver numbers each LOAD; the session uses it to tell the
        /// stream it replaced from the one it just asked for.
        var mediaSessionId: Int?
    }

    /// The media session of the last status received, nil before any LOAD.
    var currentMediaSessionId: Int? { mediaSessionId }

    var onMediaStatus: ((MediaStatus) -> Void)?
    var onLoadFailed: ((String) -> Void)?
    /// The connection dropped or the receiver app went away (someone pressed
    /// Back on the TV remote, or another sender took the TV over).
    var onClosed: ((String) -> Void)?

    private static let defaultReceiver = "CC1AD845"
    private enum Namespace {
        static let connection = "urn:x-cast:com.google.cast.tp.connection"
        static let heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat"
        static let receiver = "urn:x-cast:com.google.cast.receiver"
        static let media = "urn:x-cast:com.google.cast.media"
    }

    private let connection: NWConnection
    private var buffer = Data()
    private var requestId = 1
    private var loadRequestId: Int?
    private var transportId: String?
    private var mediaSessionId: Int?
    private var launchContinuation: CheckedContinuation<Void, Error>?
    private var heartbeat: Task<Void, Never>?
    private var closed = false

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // A receiver presents a certificate signed by Google's device CA,
        // which is not in the system trust store, so default validation
        // refuses every Chromecast. Every sender accepts it the same way;
        // the LAN is the trust boundary, as it is for the stream itself.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in
            complete(true)
        }, .main)
        let parameters = NWParameters(tls: tls)
        // The stream URL names this Mac by the local address of this
        // connection, and an IPv6 link-local one does not survive being put
        // in a URL for the receiver.
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        connection = NWConnection(to: endpoint, using: parameters)
    }

    /// The address of this Mac on the interface that reaches the TV: the
    /// stream URL handed to the receiver has to name it.
    var localHost: String? {
        guard case .hostPort(.ipv4(let address), _)? = connection.currentPath?.localEndpoint else { return nil }
        // A connection made through a Bonjour name reports addresses with the
        // interface attached ("192.168.2.56%en0"), which is no use in a URL.
        return "\(address)".split(separator: "%").first.map(String.init)
    }

    /// Connects, launches the Default Media Receiver and joins its session.
    func open(timeout: Duration) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            launchContinuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.handle(state) }
            }
            connection.start(queue: .main)
            Task { @MainActor [weak self] in
                // Without a deadline a TV that accepts TCP and never answers
                // the LAUNCH left the picker on "Connecting" for good.
                try? await Task.sleep(for: timeout)
                guard let self, self.launchContinuation != nil else { return }
                self.fail("no answer from the TV (connection \(self.connection.state))")
            }
        }
    }

    /// An HLS VOD playlist of fMP4 segments. Without the two segment
    /// formats the receiver assumes MPEG-TS. BUFFERED: the playlist lists
    /// the whole rest of the episode, so the length is real; the climbing
    /// total and the LIVE badge belonged to the single growing file.
    func load(url: String, duration: Double) {
        loadRequestId = requestId
        sendMedia(["type": "LOAD", "autoplay": true,
                   "media": ["contentId": url, "contentType": "application/x-mpegurl", "streamType": "BUFFERED",
                             "duration": duration, "hlsSegmentFormat": "fmp4", "hlsVideoSegmentFormat": "fmp4"]])
    }

    /// The stream the last LOAD named is being replaced before the TV
    /// answered it; its failure, when the server cuts it, is not the cast's.
    /// Switching Motion while the TV was still opening a stream ended the
    /// cast with LOAD_FAILED 30 ms after the new encode began.
    func supersedeLoad() { loadRequestId = nil }

    func play() { sendMediaCommand("PLAY") }
    func pause() { sendMediaCommand("PAUSE") }
    func requestStatus() { sendMediaCommand("GET_STATUS") }

    /// Ends the receiver app, which returns the TV to whatever it showed
    /// before, then drops the connection.
    func close() {
        guard !closed else { return }
        // The session has already stopped; the receiver's goodbye must not
        // come back as a failure.
        onMediaStatus = nil
        onLoadFailed = nil
        onClosed = nil
        guard let transportId else { teardown(); return }
        // Torn down once the STOP is on the wire: cancelling right after
        // queueing it dropped it, and the TV played on after the player
        // was closed.
        send(to: "receiver-0", namespace: Namespace.receiver,
             ["type": "STOP", "sessionId": transportId]) { [weak self] in self?.teardown() }
        heartbeat?.cancel()
    }

    private func teardown() {
        closed = true
        heartbeat?.cancel()
        connection.cancel()
    }

    private func handle(_ state: NWConnection.State) {
        switch state {
        case .ready:
            send(to: "receiver-0", namespace: Namespace.connection, ["type": "CONNECT"])
            send(to: "receiver-0", namespace: Namespace.receiver, ["type": "LAUNCH", "appId": Self.defaultReceiver])
            receive()
            heartbeat = Task { @MainActor [weak self] in
                // The receiver drops a sender it has not heard from in
                // about ten seconds.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    self?.send(to: "receiver-0", namespace: Namespace.heartbeat, ["type": "PING"])
                }
            }
        case .failed(let error), .waiting(let error):
            fail("connection: \(error.localizedDescription)")
        case .cancelled:
            break
        default:
            break
        }
    }

    private func fail(_ reason: String) {
        if let launchContinuation {
            self.launchContinuation = nil
            launchContinuation.resume(throwing: CastError(reason))
        } else if !closed {
            onClosed?(reason)
        }
        teardown()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data { self.buffer.append(data); self.drain() }
                if let error { self.fail("receive: \(error.localizedDescription)"); return }
                if isComplete { self.fail("receiver closed the connection"); return }
                self.receive()
            }
        }
    }

    private func drain() {
        while buffer.count >= 4 {
            let length = buffer.prefix(4).reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count >= 4 + length else { return }
            let frame = buffer.subdata(in: buffer.startIndex + 4 ..< buffer.startIndex + 4 + length)
            buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 4 + length)
            let fields = Self.decode(frame)
            guard let json = fields[6]?.data(using: .utf8),
                  let payload = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { continue }
            dispatch(namespace: fields[4] ?? "", source: fields[2] ?? "", payload: payload)
        }
    }

    private func dispatch(namespace: String, source: String, payload: [String: Any]) {
        let type = payload["type"] as? String
        switch (namespace, type) {
        case (Namespace.heartbeat, "PING"):
            send(to: source, namespace: Namespace.heartbeat, ["type": "PONG"])
        case (Namespace.connection, "CLOSE"):
            fail("receiver closed the session")
        case (Namespace.receiver, "RECEIVER_STATUS"):
            let status = payload["status"] as? [String: Any]
            let apps = status?["applications"] as? [[String: Any]] ?? []
            let ours = apps.first { $0["appId"] as? String == Self.defaultReceiver }
            if let id = ours?["transportId"] as? String, transportId == nil {
                transportId = id
                send(to: id, namespace: Namespace.connection, ["type": "CONNECT"])
                launchContinuation?.resume()
                launchContinuation = nil
            } else if ours == nil, transportId != nil {
                fail("the TV left the cast")
            }
        case (Namespace.receiver, "LAUNCH_ERROR"):
            fail("launch: \(payload["reason"] as? String ?? "refused")")
        case (Namespace.media, "MEDIA_STATUS"):
            let now = ProcessInfo.processInfo.systemUptime
            for entry in payload["status"] as? [[String: Any]] ?? [] {
                if let id = entry["mediaSessionId"] as? Int { mediaSessionId = id }
                onMediaStatus?(MediaStatus(
                    playerState: entry["playerState"] as? String ?? "IDLE",
                    idleReason: entry["idleReason"] as? String,
                    currentTime: entry["currentTime"] as? Double ?? 0,
                    receivedAt: now,
                    mediaSessionId: entry["mediaSessionId"] as? Int))
            }
        case (Namespace.media, "LOAD_FAILED") where payload["requestId"] as? Int == loadRequestId:
            onLoadFailed?("LOAD_FAILED")
        case (Namespace.media, "LOAD_FAILED"):
            // A load an even newer seek has replaced: the stream server cut
            // its connection when the next encode began. Three seeks in two
            // seconds ended a cast this way.
            AppLog.write("[cast] superseded load failed, ignored")
        case (Namespace.media, "INVALID_REQUEST"):
            // Only a refused LOAD ends the cast. One arrived 0.3 s after the
            // TV had opened a seek's new stream, most likely the answer to a
            // poll still naming the replaced stream's session, and ended a
            // cast the TV was playing. LOAD_CANCELLED is the old stream's
            // load being superseded by that same seek, not a failure.
            let reason = payload["reason"] as? String ?? "?"
            if payload["requestId"] as? Int == loadRequestId {
                onLoadFailed?("INVALID_REQUEST \(reason)")
            } else {
                AppLog.write("[cast] TV ignored a request: \(reason)")
            }
        default:
            break
        }
    }

    private func sendMediaCommand(_ type: String) {
        guard let mediaSessionId else { return }
        sendMedia(["type": type, "mediaSessionId": mediaSessionId])
    }

    private func sendMedia(_ payload: [String: Any]) {
        guard let transportId else { return }
        send(to: transportId, namespace: Namespace.media, payload)
    }

    private func send(to destination: String, namespace: String, _ payload: [String: Any],
                      then sent: (@MainActor () -> Void)? = nil) {
        guard !closed else { return }
        var payload = payload
        if namespace != Namespace.heartbeat && namespace != Namespace.connection {
            payload["requestId"] = requestId
            requestId += 1
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: json, encoding: .utf8) else { return }
        var message = Data()
        message += Self.varint(1 << 3) + Self.varint(0)            // protocol_version CASTV2_1_0
        message += Self.string(2, "sender-0")
        message += Self.string(3, destination)
        message += Self.string(4, namespace)
        message += Self.varint(5 << 3) + Self.varint(0)            // payload_type STRING
        message += Self.string(6, text)
        var length = UInt32(message.count).bigEndian
        let frame = Data(bytes: &length, count: 4) + message
        connection.send(content: frame, completion: .contentProcessed { _ in
            if let sent { MainActor.assumeIsolated { sent() } }
        })
    }

    private static func varint(_ value: Int) -> Data {
        var value = UInt64(value)
        var out = Data()
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            out.append(byte)
        } while value != 0
        return out
    }

    private static func string(_ field: Int, _ text: String) -> Data {
        let bytes = Data(text.utf8)
        return varint(field << 3 | 2) + varint(bytes.count) + bytes
    }

    /// Field number to value, strings only; the enums are not read.
    private static func decode(_ data: Data) -> [Int: String] {
        var fields: [Int: String] = [:]
        var index = data.startIndex
        func readVarint() -> Int? {
            var result = 0, shift = 0
            while index < data.endIndex {
                let byte = data[index]
                index += 1
                result |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }
        while index < data.endIndex, let key = readVarint() {
            guard let value = readVarint() else { break }
            if key & 7 == 2 {
                let end = min(index + value, data.endIndex)
                fields[key >> 3] = String(data: data[index ..< end], encoding: .utf8)
                index = end
            }
        }
        return fields
    }
}

struct CastError: LocalizedError {
    let reason: String
    init(_ reason: String) { self.reason = reason }
    var errorDescription: String? { reason }
}
#endif
