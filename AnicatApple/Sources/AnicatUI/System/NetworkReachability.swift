import Foundation
import Network

/// Watches the network path and reports the moment connectivity comes back.
///
/// The app had no notion of this at all. A shelf that failed to load stayed
/// failed until the viewer pulled to refresh or relaunched: the engine's
/// retries cover a stalled *swarm* (see `torrent/mod.rs`'s two-sample window
/// after a wake or a VPN reconnect), but nothing re-ran a catalog fetch that
/// had already returned an error. Closing a laptop over lunch, or walking
/// out of Wi-Fi range with the phone, left an empty home screen behind.
///
/// Only the offline -> online edge is interesting. `NWPathMonitor` reports
/// its current path immediately on start and then on every change, including
/// interface changes that never went down (Wi-Fi to cellular hand-off), so
/// firing on "satisfied" alone would refresh the catalog on launch and again
/// every time the phone changed radios.
@MainActor
@Observable
public final class NetworkReachability {
    /// One monitor for the process. `NWPathMonitor` costs a system callback
    /// per path change per instance, and the play path needs to read the
    /// same answer the reconnect hook is driven from.
    public static let shared = NetworkReachability()

    public private(set) var isOnline = true
    /// True on cellular and on a personal hotspot alike.
    ///
    /// `isExpensive`, not `usesInterfaceType(.cellular)`: tethering to a
    /// phone puts the traffic on the same bill and reports as Wi-Fi, and an
    /// episode is well over a gigabyte either way.
    public private(set) var isExpensive = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.anicat.reachability")
    private var started = false
    /// Called when the path goes from unsatisfied to satisfied.
    private var onReconnect: (@MainActor () -> Void)?

    public init() {}

    public func start(onReconnect: @escaping @MainActor () -> Void) {
        guard !started else { return }
        started = true
        self.onReconnect = onReconnect
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            let expensive = path.isExpensive
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasOffline = !self.isOnline
                self.isOnline = satisfied
                self.isExpensive = expensive
                if satisfied && wasOffline {
                    self.onReconnect?()
                }
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }
}
