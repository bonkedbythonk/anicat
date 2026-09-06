import Foundation
import Network
import Observation

@Observable
public final class BonjourDiscovery: @unchecked Sendable {
    public static let shared = BonjourDiscovery()

    public static let serviceType = "_anicat-stream._tcp"
    public static let serviceDomain = "local."

    // Published State
    public var discoveredMacNode: DiscoveredNode?
    public var isAdvertising: Bool = false

    public struct DiscoveredNode: Identifiable, Sendable {
        public let id: String
        public let name: String
        public let host: String
        public let port: UInt16

        public var streamBaseURL: URL? {
            URL(string: "http://\(host):\(port)")
        }
    }

    private var listener: NWListener?
    private var browser: NWBrowser?
    // Resolve attempts in flight for the current browse-result set. Kept so a
    // stale/unreachable candidate (asleep, firewalled) that never reaches
    // `.ready` can be cancelled — both when a sibling candidate resolves first
    // and when a fresh `browseResultsChangedHandler` fire supersedes the
    // whole batch — instead of leaking a connection that self-retains via its
    // own `stateUpdateHandler` closure forever.
    private var pendingResolves: [NWConnection] = []

    private init() {}

    // MARK: - macOS: Advertise Local Swarm Server

    /// TXT-record key carrying the stream server's port. The listener that
    /// publishes the service binds a port of its own, so the advertised
    /// endpoint's port is not the one a peer should fetch from.
    static let streamPortTXTKey = "port"

    /// Advertises the Mac's running torrent stream server over Bonjour.
    ///
    /// `port` is the Rust range server's port, which it has already bound.
    /// The listener is given `.any` instead: binding the same port a second
    /// time is EADDRINUSE, which `NWListener` surfaced as
    /// "Advertising failed: POSIXErrorCode 22 Invalid argument" on every
    /// single launch, so the service was never published at all.
    public func startAdvertising(port: UInt16, nodeName: String = Platform.deviceName) {
        guard listener == nil else { return }

        do {
            let tcpOptions = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.includePeerToPeer = true

            let listener = try NWListener(using: params, on: .any)
            var txtRecord = NWTXTRecord()
            txtRecord[Self.streamPortTXTKey] = String(port)
            listener.service = NWListener.Service(
                name: nodeName,
                type: Self.serviceType,
                domain: Self.serviceDomain,
                txtRecord: txtRecord
            )

            // The listener exists only to publish the service and to give a
            // browsing peer something to connect to so its host address
            // resolves. Nothing is ever served over these connections, and a
            // connection left neither accepted nor cancelled holds a socket
            // for as long as the peer keeps it open.
            listener.newConnectionHandler = { connection in
                connection.cancel()
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isAdvertising = true
                        print("[Bonjour] Advertising Anicat local stream node, stream port \(port)")
                    case .failed(let error):
                        self?.isAdvertising = false
                        print("[Bonjour] Advertising failed: \(error)")
                    default:
                        break
                    }
                }
            }

            listener.start(queue: .main)
            self.listener = listener
        } catch {
            print("[Bonjour] Failed to create NWListener: \(error)")
        }
    }

    public func stopAdvertising() {
        listener?.cancel()
        listener = nil
        isAdvertising = false
    }

    // MARK: - iOS: Browse for Running Mac Node on Local Wi-Fi

    /// Starts scanning local Wi-Fi for an active Anicat Mac instance to offload torrent streaming.
    public func startBrowsing() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = true

        // `.bonjourWithTXTRecord`, not `.bonjour`: the plain descriptor
        // reports every result with `metadata == .none`, and the stream port
        // is only in the TXT record.
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: Self.serviceType, domain: Self.serviceDomain),
            using: params
        )

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            guard let self else { return }
            // A fresh result set replaces the candidates being tried, not
            // adds to them — cancel whatever the previous batch still had in
            // flight so a peer dropped from this update can't keep resolving
            // in the background.
            self.pendingResolves.forEach { $0.cancel() }
            self.pendingResolves.removeAll()

            // `NWBrowser` hands back unresolved `.service` endpoints — no
            // host or port yet, just enough to name each peer. Try every
            // candidate concurrently rather than committing to the first:
            // mDNS can list a stale/unreachable Mac (asleep, off the LAN
            // segment, firewalled) before a perfectly reachable one, and that
            // candidate would otherwise never reach `.ready` while blocking
            // every other candidate from ever being attempted.
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint else { continue }
                // The peer's stream port comes from the TXT record, not from
                // the resolved endpoint: the advertising listener binds its
                // own port precisely because it cannot bind the stream
                // server's (see `startAdvertising`), so the endpoint's port
                // belongs to a listener that serves nothing.
                let advertisedPort = Self.streamPort(from: result.metadata)
                let connection = NWConnection(to: result.endpoint, using: .tcp)
                connection.stateUpdateHandler = { [weak self, weak connection] state in
                    guard let self, let connection else { return }
                    switch state {
                    case .ready:
                        // First candidate to resolve wins; tear down every
                        // other in-flight attempt from this batch.
                        self.pendingResolves.removeAll { $0 === connection }
                        self.pendingResolves.forEach { $0.cancel() }
                        self.pendingResolves.removeAll()
                        defer { connection.cancel() }
                        guard case .hostPort(let host, let port) = connection.currentPath?.remoteEndpoint else { return }
                        let hostString: String
                        switch host {
                        case .ipv4(let addr): hostString = "\(addr)"
                        case .ipv6(let addr): hostString = "\(addr)"
                        case .name(let n, _): hostString = n
                        @unknown default: return
                        }
                        // A peer old enough to have advertised on the stream
                        // port itself publishes no TXT record, and for that
                        // one the endpoint's port is the right answer.
                        let streamPort = advertisedPort ?? port.rawValue
                        Task { @MainActor in
                            self.discoveredMacNode = DiscoveredNode(
                                id: name,
                                name: name,
                                host: hostString,
                                port: streamPort
                            )
                            print("[Bonjour] Discovered local Mac stream server: \(name) at \(hostString):\(streamPort)")
                        }
                    case .failed, .cancelled:
                        self.pendingResolves.removeAll { $0 === connection }
                    default:
                        break
                    }
                }
                connection.start(queue: .main)
                self.pendingResolves.append(connection)
            }
        }

        browser.start(queue: .main)
        self.browser = browser
    }

    /// Reads the stream port a peer published in its Bonjour TXT record.
    /// `nil` for anything that did not publish one, or published something
    /// that is not a port.
    static func streamPort(from metadata: NWBrowser.Result.Metadata) -> UInt16? {
        guard case .bonjour(let txtRecord) = metadata,
              let raw = txtRecord[streamPortTXTKey],
              let port = UInt16(raw), port > 0 else { return nil }
        return port
    }

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredMacNode = nil
    }
}
