import Foundation
#if os(macOS)
import AppKit

/// The player's own key handling, for the things the app-wide monitor in
/// `RootView.handleKeyDown` does not claim.
///
/// It cannot go in that monitor: this is scoped to a mounted player and to
/// state (`pendingSkipWindow`, the next-episode card) that only exists while
/// one is up. It also deliberately claims nothing that monitor already
/// handles — space, the arrows (with or without Shift), m/f/n/p, Shift+V,
/// the digits and the section letters are all taken there, and two local
/// monitors racing for one key would resolve in whichever order AppKit
/// happened to dispatch them. Return, S, J and L are the keys left over.
/// J/L for the long seek rather than Shift+arrows because that monitor's
/// arrow branch does not look at Shift: it would take Shift+Left as its
/// own 10s and the race above decides whether this one adds 30 more.
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
    /// J and L: 30 seconds back and forward, 60 with Shift. Runs after
    /// `onKey` has declined the press, so a key that dismissed the
    /// next-episode card still seeks, the same way it would still play or
    /// pause in the app-wide monitor.
    public var onSeek: ((_ seconds: Double) -> Void)?
    /// Set while the player is the mini-player. The rest of the app is
    /// usable behind it and the app-wide monitor's section letters work
    /// there; L is Library, and with this monitor still claiming L as a 30s
    /// seek the two raced for the same press.
    public var isSuspended = false

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
        guard !isSuspended else { return event }
        // Typing "Blue Lock" into Search over the mini-player, or into the
        // Cmd-K palette over the full player, seeked 30s and swallowed the
        // "l". The same guard `RootView.handleKeyDown` puts in front of its
        // own single-letter keys.
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSText || responder is NSTextField {
            return event
        }
        let flags = event.modifierFlags
        guard !flags.contains(.command), !flags.contains(.control), !flags.contains(.option) else {
            return event
        }
        // 36 is Return, 76 the numeric keypad's Enter — the same key as far
        // as anyone pressing it is concerned.
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if onKey?(isReturn || chars == "s") ?? false {
            return nil
        }
        let magnitude: Double = flags.contains(.shift) ? 60 : 30
        switch chars {
        case "j":
            onSeek?(-magnitude)
            return nil
        case "l":
            onSeek?(magnitude)
            return nil
        default:
            return event
        }
    }
}
#endif
