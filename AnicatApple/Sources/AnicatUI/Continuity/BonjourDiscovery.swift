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
                        print("[Bonjour] Advertising AniCat local stream node on port \(port)")
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

    /// Starts scanning local Wi-Fi for an active AniCat Mac instance to offload torrent streaming.
    public func startBrowsing() {
        guard browser == nil else { return }

        let params = NWParameters()
        params.includePeerToPeer = true

        let browser = NWBrowser(
            for: .bonjour(type: Self.serviceType, domain: Self.serviceDomain),
            using: params
        )

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            Task { @MainActor in
                for result in results {
                    if case .service(let name, _, _, _) = result.endpoint {
                        // Resolved service
                        if let resolvedPort = self?.extractPort(from: result.endpoint) {
                            self?.discoveredMacNode = DiscoveredNode(
                                id: name,
                                name: name,
                                host: "localhost",
                                port: resolvedPort
                            )
                            print("[Bonjour] Discovered local Mac stream server: \(name) on port \(resolvedPort)")
                            return
                        }
                    }
                }
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

    private func extractPort(from endpoint: NWEndpoint) -> UInt16? {
        if case .hostPort(_, let port) = endpoint {
            return port.rawValue
        }
        return nil
    }
}
