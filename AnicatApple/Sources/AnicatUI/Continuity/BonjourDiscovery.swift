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

    /// Advertises the Mac's running torrent stream server over Bonjour.
    public func startAdvertising(port: UInt16, nodeName: String = Host.current().localizedName ?? "MacBook") {
        guard listener == nil else { return }

        do {
            let tcpOptions = NWProtocolTCP.Options()
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.includePeerToPeer = true

            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.service = NWListener.Service(
                name: nodeName,
                type: Self.serviceType,
                domain: Self.serviceDomain
            )

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isAdvertising = true
                        print("[Bonjour] Advertising Anicat local stream node on port \(port)")
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

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: Self.serviceDomain),
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
                        Task { @MainActor in
                            self.discoveredMacNode = DiscoveredNode(
                                id: name,
                                name: name,
                                host: hostString,
                                port: port.rawValue
                            )
                            print("[Bonjour] Discovered local Mac stream server: \(name) at \(hostString):\(port.rawValue)")
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

    public func stopBrowsing() {
        browser?.cancel()
        browser = nil
        discoveredMacNode = nil
    }
}
