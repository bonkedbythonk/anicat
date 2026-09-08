#if os(iOS)
import Foundation
import Network

/// A loopback HTTP server on the phone that mpv reads instead of the local
/// engine, backed by a Mac on the same Wi-Fi.
///
/// mpv cannot be handed a socket this app owns, so the bytes have to arrive
/// as HTTP from somewhere. They arrive from here: every range request the
/// player makes opens one connection to the Mac's Bonjour listener, which is
/// already paired and already approved, and the Mac relays the range out of
/// its own loopback range server. The engine's file server never leaves
/// `127.0.0.1` on either machine.
@MainActor
final class RemoteStreamProxy {
    static let shared = RemoteStreamProxy()

    private var listener: NWListener?
    private(set) var port: UInt16?
    /// Grants this phone holds, by token. The proxy answers for these and
    /// nothing else, so a request for an unknown path is a 404 rather than
    /// an attempt to reach the Mac.
    private var grants: [String: (grant: StreamGrant, node: BonjourDiscovery.DiscoveredNode)] = [:]

    private init() {}

    /// Starts the server if it is not already up and returns its port.
    @discardableResult
    func start() -> UInt16? {
        if let port { return port }
        do {
            let params = NWParameters.tcp
            // Loopback, explicitly. Without this the listener answers on
            // every interface, and while the token would still gate it, a
            // video proxy reachable from the Wi-Fi is precisely what this
            // whole design exists to avoid.
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.port = listener.port?.rawValue
                    case .failed, .cancelled:
                        self?.port = nil
                        self?.listener = nil
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            return listener.port?.rawValue
        } catch {
            print("[RemoteStream] proxy could not bind loopback: \(error)")
            return nil
        }
    }

    /// Registers a grant and returns the URL to hand mpv.
    func url(for grant: StreamGrant, on node: BonjourDiscovery.DiscoveredNode) -> URL? {
        guard let port = start() ?? port else { return nil }
        grants[grant.token] = (grant, node)
        return URL(string: "http://127.0.0.1:\(port)/s/\(grant.token)")
    }

    /// Forgets a grant. The Mac is told separately; this is what stops the
    /// proxy answering for it locally.
    func release(token: String) {
        grants.removeValue(forKey: token)
    }

    func releaseAll() {
        grants.removeAll()
    }

    // MARK: - One player request

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) {
            [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            guard error == nil else { connection.cancel(); return }
            // Headers end at the blank line. mpv sends no body, so nothing
            // after it is ours to read.
            guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if isComplete { connection.cancel(); return }
                Task { @MainActor in self?.readRequest(connection, buffer: buffer) }
                return
            }
            let head = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
            Task { @MainActor in self?.serve(head, on: connection) }
        }
    }

    private func serve(_ head: String, on connection: NWConnection) {
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: true).map(String.init)
        guard let requestLine = lines.first else { return respond(connection, status: 400) }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return respond(connection, status: 405)
        }
        let token = String(parts[1].split(separator: "/").last ?? "")
        guard let entry = grants[token] else { return respond(connection, status: 404) }

        let total = entry.grant.totalLength
        let (start, end) = Self.range(from: lines, total: total)
        guard start <= end, start >= 0, end < total else { return respond(connection, status: 416) }

        if parts[0] == "HEAD" {
            return respond(
                connection,
                status: 200,
                headers: [
                    "Content-Type": entry.grant.contentType,
                    "Accept-Ranges": "bytes",
                    "Content-Length": "\(total)",
                ]
            )
        }

        RemoteStreamPump(
            player: connection,
            node: entry.node,
            token: token,
            start: start,
            end: end,
            total: total,
            contentType: entry.grant.contentType
        ).run()
    }

    /// `Range: bytes=a-b`, with both halves optional, defaulted to the whole
    /// file. mpv opens with no range at all and then seeks with open-ended
    /// ones, so both forms have to work or the first read never starts.
    static func range(from lines: [String], total: Int64) -> (Int64, Int64) {
        guard let header = lines.first(where: { $0.lowercased().hasPrefix("range:") }),
              let spec = header.split(separator: "=").last else {
            return (0, max(total - 1, 0))
        }
        let halves = spec.split(separator: "-", omittingEmptySubsequences: false)
        let start = halves.first.flatMap { Int64($0.trimmingCharacters(in: .whitespaces)) } ?? 0
        let end = halves.count > 1
            ? (Int64(halves[1].trimmingCharacters(in: .whitespaces)) ?? total - 1)
            : total - 1
        return (start, min(end, max(total - 1, 0)))
    }

    private func respond(
        _ connection: NWConnection,
        status: Int,
        headers: [String: String] = [:]
    ) {
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        for (key, value) in headers { head += "\(key): \(value)\r\n" }
        if headers["Content-Length"] == nil { head += "Content-Length: 0\r\n" }
        head += "Connection: close\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 416: return "Range Not Satisfiable"
        default: return "Error"
        }
    }
}

/// Carries one range: player connection on one side, a fresh connection to
/// the Mac on the other.
///
/// A connection per range rather than one multiplexed channel. Ranges
/// interleave when mpv seeks, and multiplexing them over the control socket
/// would mean inventing request ids, ordering and cancellation on top of a
/// stream that also carries player commands. A short-lived connection per
/// read costs a TCP handshake on a LAN and nothing else.
@MainActor
private final class RemoteStreamPump {
    private let player: NWConnection
    private let node: BonjourDiscovery.DiscoveredNode
    private let token: String
    private let start: Int64
    private let end: Int64
    private let total: Int64
    private let contentType: String

    private var host: NWConnection?
    private var framer = RemoteFramer()
    /// Set the moment the Mac's `dataHeader` lands. Everything the socket
    /// delivers after that newline is video, and feeding it to the framer
    /// would have it hunt for JSON inside an MKV -- which is full of `0x0A`
    /// and fails silently, eating the file.
    private var isRaw = false

    init(
        player: NWConnection,
        node: BonjourDiscovery.DiscoveredNode,
        token: String,
        start: Int64,
        end: Int64,
        total: Int64,
        contentType: String
    ) {
        self.player = player
        self.node = node
        self.token = token
        self.start = start
        self.end = end
        self.total = total
        self.contentType = contentType
    }

    func run() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(node.host),
            port: NWEndpoint.Port(rawValue: node.controlPort) ?? .any
        )
        let host = NWConnection(to: endpoint, using: .tcp)
        self.host = host
        host.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    host.sendFrame(.helloData(
                        deviceId: RemoteClient.deviceId,
                        token: self.token,
                        start: self.start,
                        end: self.end
                    ))
                case .failed, .cancelled:
                    self.tearDown()
                default:
                    break
                }
            }
        }
        host.start(queue: .main)
        receiveFromHost()
    }

    /// Reads one chunk from the Mac and does not ask for the next until mpv
    /// has taken it. That ordering is the phone's half of the backpressure;
    /// the Mac's half is `StreamRelay` suspending its `URLSessionDataTask`
    /// between chunks. Without both, a Mac serving from a warm cache reads
    /// at disk speed, the Wi-Fi cannot keep up, and the rest of the episode
    /// queues in memory on one side or the other.
    private func receiveFromHost() {
        host?.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if isComplete || error != nil {
                    self.tearDown()
                    return
                }
                guard let data, !data.isEmpty else {
                    self.receiveFromHost()
                    return
                }
                self.handle(data)
            }
        }
    }

    private func handle(_ data: Data) {
        guard !isRaw else { return forward(data) }
        // The header is one JSON line; whatever follows it in this same read
        // is already video and must bypass the framer.
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else {
            _ = framer.ingest(data)
            return
        }
        let line = data[..<data.index(after: newline)]
        let rest = data[data.index(after: newline)...]
        for frame in framer.ingest(Data(line)) {
            switch frame {
            case .dataHeader(let length, let type):
                isRaw = true
                sendPlayerHeader(length: length, contentType: type)
            case .dataError(let message):
                print("[RemoteStream] host refused the range: \(message)")
                tearDown()
                return
            default:
                break
            }
        }
        if isRaw, !rest.isEmpty {
            forward(Data(rest))
        } else {
            receiveFromHost()
        }
    }

    private func sendPlayerHeader(length: Int64, contentType: String) {
        let head = """
        HTTP/1.1 206 Partial Content\r
        Content-Type: \(contentType)\r
        Accept-Ranges: bytes\r
        Content-Length: \(length)\r
        Content-Range: bytes \(start)-\(end)/\(total)\r
        Connection: close\r
        \r

        """
        player.send(content: Data(head.utf8), completion: .idempotent)
    }

    private func forward(_ data: Data) {
        player.send(content: data, completion: .contentProcessed { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if error != nil {
                    self.tearDown()
                    return
                }
                self.receiveFromHost()
            }
        })
    }

    private func tearDown() {
        host?.cancel()
        host = nil
        player.cancel()
    }
}
#endif
