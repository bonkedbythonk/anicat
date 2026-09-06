import Foundation
#if os(macOS)
import AppKit

/// The player's own key handling, for the two things the app-wide monitor in
/// `RootView.handleKeyDown` does not claim.
///
/// It cannot go in that monitor: this is scoped to a mounted player and to
/// state (`pendingSkipWindow`, the next-episode card) that only exists while
/// one is up. It also deliberately claims nothing that monitor already
/// handles — space, the arrows, m/f/n/p, Shift+V, the digits and the section
/// letters are all taken there, and two local monitors racing for one key
/// would resolve in whichever order AppKit happened to dispatch them.
/// Return and S are the keys left over.
///
/// One closure for every press rather than a skip callback beside an
/// any-key one: the next-episode card's "any key cancels" and the Skip pill
/// both want Return, and two callbacks would have to agree on which ran
/// first to decide that. Deciding it in one place is what makes the card
/// supersede the pill, which is the rule while both could be on screen.
@MainActor
public final class PlayerKeyMonitor {
    /// `isSkipKey` is Return or S. Answers whether to consume the event —
    /// false passes it on, so a key that did nothing here still reaches the
    /// app-wide monitor.
    public var onKey: ((_ isSkipKey: Bool) -> Bool)?

    private var monitor: Any?

    public init() {}

    public func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    public func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
    }

    deinit {
        // `NSEvent.removeMonitor` is documented as main-thread-only and this
        // object is only ever released from a SwiftUI `@State` teardown,
        // which is on the main thread; the isolation is asserted rather than
        // hopped to so the removal cannot land after another player has
        // installed its own monitor.
        MainActor.assumeIsolated { stop() }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return event
        }
        // 36 is Return, 76 the numeric keypad's Enter — the same key as far
        // as anyone pressing it is concerned.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let isS = (event.charactersIgnoringModifiers?.lowercased() ?? "") == "s"
        return (onKey?(isReturn || isS) ?? false) ? nil : event
    }
}
#endif
