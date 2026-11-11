#if os(macOS)
import Foundation
import Network

/// Serves the episode being encoded to the TV as HLS: a VOD playlist that
/// lists every segment to the end of the episode up front, cut from the
/// encoder's growing fragmented MP4. The init segment is the file before the
/// first `moof`; segment N is the Nth `moof`+`mdat`, one GOP, which the
/// encoder places every `segmentDuration` exactly.
///
/// One growing file sent as a single progressive download, LIVE, was what
/// came before. The TV's player rewound to the stream's start after a stall
/// (365 s back, with or without re-requesting byte 0), showed a LIVE badge
/// for want of a length, and every recovery was a restart. A segment the TV
/// lost it can fetch again; the FFmpeg in MPVKit has no HLS muxer, which is
/// why the segments are cut here.
///
/// A request for a segment not encoded yet is held until it is, so the
/// playlist can promise the whole episode. Anything outside the current
/// random token gets a 404; the token changes with every restart.
final class CastStreamServer: @unchecked Sendable {
    struct Stream {
        let file: URL
        let token: String
        let mediaPlaylist: String
        let audio: Bool
        let megabits: Int
        let isFinished: @Sendable () -> Bool
        /// The TV asked for segment N: the encoder must be allowed that far,
        /// or its throttle and a greedy buffer wait on each other.
        let wants: @Sendable (Int) -> Void
    }

    private let queue = DispatchQueue(label: "anicat.cast.server")
    private var listener: NWListener?
    // Below: queue-confined.
    private var stream: Stream?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    /// Top-level box index of the current file.
    private var scanned: UInt64 = 0
    private var pendingMoof: UInt64?
    private var initEnd: UInt64?
    private var fragments: [Range<UInt64>] = []
    private var lastSegment = -1

    /// Starts listening and answers the port.
    func start() async throws -> UInt16 {
        let listener = try NWListener(using: .tcp, on: .any)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        return try await withCheckedThrowingContinuation { continuation in
            // Cleared on the first answer, so the continuation resumes once.
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Points the server at a new stream; connections to the old one close.
    func serve(_ stream: Stream) {
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            self.stream = stream
            scanned = 0
            pendingMoof = nil
            initEnd = nil
            fragments = []
            lastSegment = -1
        }
    }

    func stop() {
        queue.async { [self] in
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
            stream = nil
        }
    }

    // MARK: - Box index

    /// Reads top-level box headers past what is indexed. A box counts once
    /// all of it is on disk; the encoder appends, so nothing indexed changes.
    private func scan() {
        guard let stream, let handle = try? FileHandle(forReadingFrom: stream.file) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        while scanned + 8 <= size {
            try? handle.seek(toOffset: scanned)
            guard let head = try? handle.read(upToCount: 16), head.count >= 8 else { return }
            var length = UInt64(head.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) })
            let type = String(decoding: head[4..<8], as: UTF8.self)
            if length == 1 {
                guard head.count == 16 else { return }
                length = head[8..<16].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            }
            // 0 is "to the end of the file", a box still being written.
            guard length >= 8, scanned + length <= size else { return }
            switch type {
            case "moof":
                if initEnd == nil { initEnd = scanned }
                pendingMoof = scanned
            case "mdat":
                if let start = pendingMoof { fragments.append(start..<(scanned + length)) }
                pendingMoof = nil
            default:
                break
            }
            scanned += length
        }
    }

    /// The HLS `CODECS` value for the video, from the init segment's `hvcC`
    /// and sample entry, and its size. Read, not assumed: the DASH attempt
    /// went out with an empty codecs field and the TV refused it.
    private func videoInfo(_ initSegment: Data) -> (codec: String, width: Int, height: Int)? {
        let bytes = [UInt8](initSegment)
        func find(_ tag: String) -> Int? {
            let needle = Array(tag.utf8)
            guard bytes.count >= needle.count else { return nil }
            return (0...(bytes.count - needle.count)).first { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }
        }
        guard let config = find("hvcC"), config + 17 <= bytes.count else { return nil }
        let entry = find("hev1") ?? find("hvc1")
        let c = config + 4
        let profile = bytes[c + 1]
        let compatibility = bytes[(c + 2)..<(c + 6)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << bit) != 0 { reversed |= 1 << (31 - bit) }
        var constraints = Array(bytes[(c + 6)..<(c + 12)])
        while constraints.last == 0 { constraints.removeLast() }
        let tag = entry.map { String(decoding: bytes[$0..<($0 + 4)], as: UTF8.self) } ?? "hev1"
        var codec = "\(tag).\(profile & 0x1F).\(String(reversed, radix: 16).uppercased()).\(profile & 0x20 != 0 ? "H" : "L")\(bytes[c + 12])"
        if !constraints.isEmpty { codec += "." + constraints.map { String($0, radix: 16).uppercased() }.joined(separator: ".") }
        var width = 0, height = 0
        if let entry, entry + 32 <= bytes.count {
            width = Int(bytes[entry + 28]) << 8 | Int(bytes[entry + 29])
            height = Int(bytes[entry + 30]) << 8 | Int(bytes[entry + 31])
        }
        return (codec, width, height)
    }

    // MARK: - HTTP

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.connections.removeValue(forKey: ObjectIdentifier(connection))
            default:
                break
            }
        }
        connection.start(queue: queue)
        readRequest(connection, head: Data())
    }

    private func readRequest(_ connection: NWConnection, head: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var head = head
            if let data { head.append(data) }
            if let end = head.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, to: String(decoding: head[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || head.count > 16_384 {
                connection.cancel()
            } else {
                self.readRequest(connection, head: head)
            }
        }
    }

    private static let cors = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Range\r\nAccess-Control-Expose-Headers: Content-Length\r\n"

    private func respond(_ connection: NWConnection, to request: String) {
        let parts = request.split(separator: "\r\n").first?.split(separator: " ") ?? []
        guard parts.count >= 2, let stream else { return status(connection, "404 Not Found") }
        let method = String(parts[0])
        // A player behind a CORS preflight fails with no clear error when
        // the OPTIONS goes unanswered.
        if method == "OPTIONS" { return status(connection, "200 OK") }
        let prefix = "/\(stream.token)/"
        guard parts[1].hasPrefix(prefix) else { return status(connection, "404 Not Found") }
        let name = String(parts[1].dropFirst(prefix.count))
        let head = method == "HEAD"

        switch name {
        case "index.m3u8":
            AppLog.write("[cast] TV asked for the playlist")
            waitForInit(connection, since: .now()) { [self] range in
                guard let range, let initData = read(stream.file, range),
                      let video = videoInfo(initData) else { return status(connection, "503 Service Unavailable") }
                var codecs = video.codec
                if stream.audio { codecs += ",mp4a.40.2" }
                AppLog.write("[cast] playlist codecs \(codecs), \(video.width)x\(video.height)")
                let resolution = video.width > 0 ? ",RESOLUTION=\(video.width)x\(video.height)" : ""
                let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-STREAM-INF:BANDWIDTH=\((stream.megabits + 2) * 1_000_000),CODECS=\"\(codecs)\"\(resolution)\nmedia.m3u8\n"
                send(connection, Data(master.utf8), type: "application/vnd.apple.mpegurl", head: head)
            }
        case "media.m3u8":
            send(connection, Data(stream.mediaPlaylist.utf8), type: "application/vnd.apple.mpegurl", head: head)
        case "init.mp4":
            AppLog.write("[cast] TV asked for the init segment")
            waitForInit(connection, since: .now()) { [self] range in
                guard let range else { return status(connection, "503 Service Unavailable") }
                sendFile(connection, stream.file, range, head: head)
            }
        default:
            guard name.hasSuffix(".m4s"), let index = Int(name.dropLast(4)), index >= 0 else {
                return status(connection, "404 Not Found")
            }
            // Asking again for one already sent is the player going back:
            // the old rewind bug's signature if it shows up mid-play.
            if index <= lastSegment { AppLog.write("[cast] TV asked again for segment \(index) (had \(lastSegment))") }
            lastSegment = max(lastSegment, index)
            stream.wants(index)
            waitForSegment(index, connection, since: .now()) { [self] range, waited in
                guard let range else {
                    let finished = stream.isFinished()
                    AppLog.write("[cast] segment \(index) \(finished ? "past the end" : "not ready after \(waited) ms")")
                    return status(connection, finished ? "404 Not Found" : "503 Service Unavailable")
                }
                if waited > 500 { AppLog.write("[cast] segment \(index) waited \(waited) ms") }
                sendFile(connection, stream.file, range, head: head)
            }
        }
    }

    private func waitForInit(_ connection: NWConnection, since start: DispatchTime, then done: @escaping (Range<UInt64>?) -> Void) {
        scan()
        if let end = initEnd { return done(0..<end) }
        guard let stream, !stream.isFinished(), Self.elapsed(since: start) < 15_000 else { return done(nil) }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.waitForInit(connection, since: start, then: done) }
    }

    /// Held up to 15 s, then a 503 the player retries.
    private func waitForSegment(_ index: Int, _ connection: NWConnection, since start: DispatchTime,
                                then done: @escaping (Range<UInt64>?, Int) -> Void) {
        guard connections[ObjectIdentifier(connection)] != nil else { return }
        scan()
        let waited = Self.elapsed(since: start)
        if index < fragments.count { return done(fragments[index], waited) }
        guard let stream, !stream.isFinished(), waited < 15_000 else { return done(nil, waited) }
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForSegment(index, connection, since: start, then: done)
        }
    }

    private static func elapsed(since start: DispatchTime) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    private func read(_ file: URL, _ range: Range<UInt64>) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: range.lowerBound)
        return try? handle.read(upToCount: Int(range.count))
    }

    private func status(_ connection: NWConnection, _ status: String) {
        let head = "HTTP/1.1 \(status)\r\n\(Self.cors)Content-Length: 0\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func send(_ connection: NWConnection, _ body: Data, type: String, head: Bool) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\n\(Self.cors)Connection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + (head ? Data() : body), isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    /// A byte range of the encoder's file with a known length, in 1 MB
    /// sends so a 4K segment is never held in memory whole.
    private func sendFile(_ connection: NWConnection, _ file: URL, _ range: Range<UInt64>, head: Bool) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: \(range.count)\r\nCache-Control: no-store\r\n\(Self.cors)Connection: close\r\n\r\n"
        guard !head, let handle = try? FileHandle(forReadingFrom: file) else {
            return connection.send(content: Data(header.utf8), isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
        }
        try? handle.seek(toOffset: range.lowerBound)
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); return connection.cancel() }
            self?.pump(connection, handle, remaining: UInt64(range.count))
        })
    }

    private func pump(_ connection: NWConnection, _ handle: FileHandle, remaining: UInt64) {
        guard remaining > 0, connections[ObjectIdentifier(connection)] != nil else {
            try? handle.close()
            connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        let data = (try? handle.read(upToCount: Int(min(remaining, 1 << 20)))) ?? Data()
        guard !data.isEmpty else { try? handle.close(); return connection.cancel() }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else { try? handle.close(); return connection.cancel() }
            self?.pump(connection, handle, remaining: remaining - UInt64(data.count))
        })
    }
}
#endif
