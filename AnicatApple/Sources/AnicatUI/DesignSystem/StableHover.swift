import SwiftUI
#if os(macOS)
import AppKit

/// Tracks scroll-wheel activity so hover state can ignore the moment a
/// stationary pointer is scrolled under, rather than tracked over.
///
/// On macOS, `.onHover` fires whenever content moves under a *stationary*
/// pointer, not just when the pointer itself moves. Scrolling a poster grid
/// or shelf with the mouse resting over it makes whatever card passes under
/// the cursor toggle its hover state every frame, animating scale/opacity
/// the whole way down. A local event monitor on `.scrollWheel` is the signal
/// available without also having to reason about window `acceptsMouseMovedEvents`.
@MainActor
final class HoverActivityMonitor {
    static let shared = HoverActivityMonitor()

    private var lastScrollTime: Double = 0
    private var monitor: Any?

    var isScrollActive: Bool {
        CACurrentMediaTime() - lastScrollTime < 0.15
    }

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self] event in
            self?.lastScrollTime = CACurrentMediaTime()
            return event
        }
    }
}

private struct StableHoverModifier: ViewModifier {
    let perform: (Bool) -> Void

    func body(content: Content) -> some View {
        content.onHover { hovering in
            if hovering && HoverActivityMonitor.shared.isScrollActive { return }
            perform(hovering)
        }
    }
}

public extension View {
    /// Like `.onHover`, but drops the "entered" edge when it fires because
    /// scrolled content passed under a stationary pointer instead of the
    /// pointer moving over it. `false` (left) transitions always pass through,
    /// so a card mid-animation still resets when scrolled away.
    func stableHover(perform: @escaping (Bool) -> Void) -> some View {
        modifier(StableHoverModifier(perform: perform))
    }
}
#else
public extension View {
    func stableHover(perform: @escaping (Bool) -> Void) -> some View {
        self
    }
}
#endif
