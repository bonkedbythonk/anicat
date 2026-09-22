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
    private var suppressOrigin: CGPoint?

    var isScrollActive: Bool {
        CACurrentMediaTime() - lastScrollTime < 0.15
    }

    /// Ignore hover *activation* until the pointer actually moves.
    ///
    /// Closing a page re-enables hit testing on the feed underneath, and the
    /// card the pointer happens to be resting over then lights up on its own
    /// -- a 3% scale and a 2pt lift, arriving as its own animation a beat
    /// after the transition has finished. Measured on a recording of the
    /// close: the transition settled after 183ms, then 750ms later the poster
    /// under the cursor grew. It reads as the page tweaking back into place,
    /// which is what it was mistaken for.
    ///
    /// Hover is meant to answer "the pointer is on this"; nothing moved, so
    /// nothing should light up until something does.
    func suppressHoverUntilPointerMoves() {
        suppressOrigin = NSEvent.mouseLocation
    }

    /// Clears itself on the first check made after a real move, so a pointer
    /// that never moves again stays suppressed and one that twitches once is
    /// released immediately.
    var shouldIgnoreHoverActivation: Bool {
        guard let origin = suppressOrigin else { return false }
        let now = NSEvent.mouseLocation
        // Two points, not zero: a stationary mouse still reports sub-pixel
        // jitter on some devices, which would release this at once.
        if hypot(now.x - origin.x, now.y - origin.y) > 2 {
            suppressOrigin = nil
            return false
        }
        return true
    }

    private var settle: DispatchWorkItem?

    private init() {
        // The tap, not a local monitor: responsive scrolling keeps trackpad
        // events off the main thread's monitors, so hover was firing all
        // through a scroll again.
        monitor = ScrollEventTap.shared.subscribe { [weak self] _ in
            guard let self else { return }
            lastScrollTime = CACurrentMediaTime()
            if !ScrollActivity.shared.isScrolling { ScrollActivity.shared.isScrolling = true }
            settle?.cancel()
            let item = DispatchWorkItem { ScrollActivity.shared.isScrolling = false }
            settle = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
        }
    }
}

/// Whether a scroll gesture is in progress, as one observable flag every
/// hover site reads.
///
/// SwiftUI re-runs hover hit-testing for every registered hover responder
/// on every frame that moves content under the pointer, and a shelf page
/// registers one per card. Time Profiler on a driven scroll of the home
/// page (release, 2026-09-19): 17% of main-thread time was that dispatch,
/// `HoverResponder.containsGlobalPoints` and `NSScrollView hitTest`, for
/// hover states `StableHoverModifier` was going to ignore anyway. Taking
/// the cards out of hit-testing for the length of the gesture removes the
/// responders from the walk. A flag rather than the monitor's timestamp so
/// the sites re-evaluate twice per gesture, not once per frame.
@MainActor @Observable
final class ScrollActivity {
    static let shared = ScrollActivity()
    /// `ANICAT_NO_HOVER_GATE=1` keeps every card hit-testable through a
    /// scroll, for same-binary A/B profiles.
    static let gateDisabled = DebugHooks.env("ANICAT_NO_HOVER_GATE") != nil
    var isScrolling = false
    private init() {}
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
        // Out of hit-testing while a gesture runs (see `ScrollActivity`).
        // A click cannot land on a moving card anyway; the 120 ms tail is
        // the gap between the last event of a stopped finger and a click.
        content.onContinuousHover { phase in
            switch phase {
            case .active:
                guard !HoverActivityMonitor.shared.isScrollActive,
                      !HoverActivityMonitor.shared.shouldIgnoreHoverActivation,
                      !isHovering else { return }
                isHovering = true
                perform(true)
            case .ended:
                guard isHovering else { return }
                isHovering = false
                perform(false)
            }
        }
        // Outermost, so the hover responder itself is what leaves the
        // hit-test walk: under the responder it excluded only the content
        // and the walk still visited every card (17% -> 13%, measured).
        .allowsHitTesting(ScrollActivity.gateDisabled || !ScrollActivity.shared.isScrolling)
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
