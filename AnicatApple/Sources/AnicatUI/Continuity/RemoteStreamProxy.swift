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
    /// The ranges currently in flight.
    ///
    /// Held because nothing else does. Every callback inside a pump captures
    /// `self` weakly -- it has to, or the pump and its connection would
    /// retain each other -- so a pump nobody stores is deallocated the moment
    /// `run()` returns, and the `.ready` handler that sends the Mac its
    /// `helloData` finds `self` already gone. The Mac is then never told what
    /// to send, and the player waits out its own read timeout on a socket
    /// that will never speak.
    private var pumps: [ObjectIdentifier: RemoteStreamPump] = [:]

    private init() {}

    /// Waiters for the port, from calls made before the listener is ready.
    private var readyWaiters: [CheckedContinuation<UInt16?, Never>] = []

    /// Starts the server if it is not already up and returns its port.
    ///
    /// Awaits `.ready` rather than reading `listener.port` straight after
    /// `start()`: the port is not assigned until then, so the old
    /// synchronous read handed back 0 and the player was pointed at
    /// `http://127.0.0.1:0/...`, which ffmpeg rejects with "Port missing in
    /// uri". Non-nil-but-useless is the worst answer this can give -- the
    /// caller falls back to a local resolve on nil, and 0 sailed past that.
    @discardableResult
    func start() async -> UInt16? {
        if let port { return port }
        // A start already in flight: wait on the same `.ready` rather than
        // binding a second listener.
        if listener != nil {
            return await withCheckedContinuation { readyWaiters.append($0) }
        }
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
                        // A rawValue of 0 is not a port anything can be
                        // opened on; treat it as a failure to bind.
                        let bound = listener.port?.rawValue
                        self?.port = (bound ?? 0) == 0 ? nil : bound
                        self?.flushWaiters()
                    case .failed, .cancelled:
                        self?.port = nil
                        self?.listener = nil
                        self?.flushWaiters()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
            return await withCheckedContinuation { readyWaiters.append($0) }
        } catch {
            print("[RemoteStream] proxy could not bind loopback: \(error)")
            return nil
        }
    }

    /// Hands every waiting caller whatever the listener settled on.
    private func flushWaiters() {
        let waiting = readyWaiters
        readyWaiters.removeAll()
        for continuation in waiting { continuation.resume(returning: port) }
    }

    /// Registers a grant and returns the URL to hand mpv.
    func url(for grant: StreamGrant, on node: BonjourDiscovery.DiscoveredNode) async -> URL? {
        guard let port = await start() else { return nil }
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
        guard let entry = grants[token] else {
            print("[RemoteStream] no grant for token \(token); answering 404")
            return respond(connection, status: 404)
        }

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

        // The node as Bonjour knows it *now*, not as it was when the grant
        // was made. The Mac picks a fresh control port on every launch, so a
        // Mac restarted between the resolve and the first range left the
        // pump dialling a port nothing was listening on any more.
        let live = BonjourDiscovery.shared.discoveredMacNode
        let node = (live?.id == entry.node.id ? live : nil) ?? entry.node

        let pump = RemoteStreamPump(
            player: connection,
            node: node,
            token: token,
            start: start,
            end: end,
            total: total,
            contentType: entry.grant.contentType
        )
        pumps[ObjectIdentifier(pump)] = pump
        pump.onFinish = { [weak self] finished in
            self?.pumps.removeValue(forKey: ObjectIdentifier(finished))
        }
        pump.run()
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

    /// Told when this range is done, so the proxy can stop holding it.
    var onFinish: ((RemoteStreamPump) -> Void)?

    private var host: NWConnection?
    /// Escapes `.preparing`. A TCP connect to a port nothing listens on --
    /// a Mac restarted since the grant -- sits there forever: Network
    /// framework reports neither `.ready` nor `.failed`, so the player waited
    /// on a socket that was never going to speak. This is the only thing that
    /// ends that wait.
    private var connectDeadline: Task<Void, Never>?
    private static let connectTimeout: Duration = .seconds(5)
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
        print("[RemoteStream] dialling host \(node.host):\(node.controlPort) for \(start)-\(end)")
        let host = NWConnection(to: endpoint, using: .tcp)
        self.host = host
        host.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self else { return }
                switch state {
                case .ready:
                    self.connectDeadline?.cancel()
                    self.connectDeadline = nil
                    host.sendFrame(.helloData(
                        deviceId: RemoteClient.deviceId,
                        token: self.token,
                        start: self.start,
                        end: self.end
                    ))
                case .failed(let error):
                    print("[RemoteStream] host connection failed: \(error)")
                    self.tearDown()
                case .waiting(let error):
                    print("[RemoteStream] host connection waiting: \(error)")
                case .cancelled:
                    self.tearDown()
                default:
                    break
                }
            }
        }
        host.start(queue: .main)
        connectDeadline = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.connectDeadline != nil else { return }
                print("[RemoteStream] host did not answer in \(Self.connectTimeout); giving up")
                self.tearDown()
            }
        }
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
                    if error != nil {
                        print("[RemoteStream] host read ended: \(String(describing: error))")
                    }
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

    /// Ends both sides.
    ///
    /// A teardown before the 206 header went out is a failure the player has
    /// no way to see: mpv is still waiting for a response line, and cancelling
    /// underneath it reads as a stall rather than an error. Answering 502
    /// first is what turns an endless spinner into a playback error the app
    /// already knows how to show.
    private var isFinished = false

    private func tearDown() {
        guard !isFinished else { return }
        isFinished = true
        connectDeadline?.cancel()
        connectDeadline = nil
        host?.cancel()
        host = nil
        if !isRaw {
            let head = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            player.send(content: Data(head.utf8), completion: .contentProcessed { [player] _ in
                player.cancel()
            })
        } else {
            player.cancel()
        }
        onFinish?(self)
    }
}
#endif
