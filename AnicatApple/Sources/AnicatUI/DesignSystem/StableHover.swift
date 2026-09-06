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

    // The modifier owns the entered/left state instead of leaving it to the
    // callback, because `onContinuousHover` reports `.active` on every
    // pointer sample rather than once per edge. MediaCard's callback starts
    // `prefetchDetail`, which reads the detail disk cache on the main actor
    // before its own in-flight guard, so passing every sample through would
    // be a disk hit per mouse move across a poster.
    @State private var isHovering = false

    func body(content: Content) -> some View {
        // `.onHover` reports edges only, so a suppressed "entered" was lost
        // for good: the pointer was already inside the card, no further
        // enter event was coming, and hover stayed off until the pointer
        // left and came back. That is the "stop scrolling, move the mouse
        // inside the card, nothing happens" case. `.onContinuousHover` keeps
        // reporting while the pointer is inside, so a sample dropped during
        // a scroll is retried by the next one the pointer's own movement
        // produces — no queue, no timer, and a pointer that never moves
        // again correctly stays un-hovered.
        content.onContinuousHover { phase in
            switch phase {
            case .active:
                guard !HoverActivityMonitor.shared.isScrollActive, !isHovering else { return }
                isHovering = true
                perform(true)
            case .ended:
                guard isHovering else { return }
                isHovering = false
                perform(false)
            }
        }
    }
}

public extension View {
    /// Like `.onHover`, but ignores the moment scrolled content passes under
    /// a stationary pointer instead of the pointer moving over it. Entering
    /// is reported once, on the first pointer sample inside the view that
    /// does not land in a scroll; leaving is reported once, and only if
    /// entering was.
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
