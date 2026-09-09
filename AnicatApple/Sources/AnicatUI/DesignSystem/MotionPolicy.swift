import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Motion kinds

/// The four movements the app makes. Naming the *occasion* rather than a
/// curve is the point: a call site says what it is animating and this file
/// stays the only place that decides how, including whether it moves at all.
public enum SumiMotion: Sendable {
    /// Switching a sidebar section or a tab rail. Short, no overshoot.
    case tab
    /// Pushing or popping a whole page.
    case page
    /// A pill, badge or indicator settling into place.
    case pop
    /// A `matchedGeometryEffect` hand-off, the poster morph above all.
    case morph
    /// The same hand-off run backwards: a poster returning to the card it
    /// came from. Critically damped, where `morph` is not. A spring at 0.86
    /// damping overshoots its target and rings back -- lively on the way out
    /// of a card, and on the way back the owner described it as the page
    /// vibrating before it went into place. Arriving somewhere it already
    /// was does not want a bounce.
    case morphReturn
}

// MARK: - Policy

/// Whether the system has asked for less movement and less transparency.
///
/// The flags are cached in plain storage and refreshed by a notification
/// observer rather than read live: `NSWorkspace.shared` is main-actor
/// isolated, and reading it from `Animation.sumi(_:)` would make every call
/// site main-actor too — including the ones inside `NSViewRepresentable`
/// coordinators and animation modifiers that are not.
public enum MotionPolicy {
    nonisolated(unsafe) private static var cachedReduceMotion = false
    nonisolated(unsafe) private static var cachedReduceTransparency = false

    /// True when the user has asked for reduced motion. Reading this starts
    /// the observer on first use, so nothing has to remember to call a setup
    /// function from the app's launch path.
    public static var reduce: Bool {
        _ = bootstrap
        return cachedReduceMotion
    }

    public static var reduceTransparency: Bool {
        _ = bootstrap
        return cachedReduceTransparency
    }

    private static let bootstrap: Void = {
        #if os(macOS)
        // The observer fires on the main queue and the first read is normally
        // from a view body, so take the launch value synchronously when we are
        // already on the main thread and let the observer fill it in otherwise.
        // A wrong `false` for one frame is a smoother animation, not a crash.
        if Thread.isMainThread {
            MainActor.assumeIsolated { refresh() }
        } else {
            Task { @MainActor in refresh() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { refresh() }
        }
        #elseif canImport(UIKit)
        // Same shape as the macOS branch: the first read hops to the main
        // actor rather than asserting it, since the bootstrap can run from
        // wherever the first `reduce` read happens.
        Task { @MainActor in
            cachedReduceMotion = UIAccessibility.isReduceMotionEnabled
            cachedReduceTransparency = UIAccessibility.isReduceTransparencyEnabled
        }
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            // The observer block is Sendable and the UIKit flags are
            // main-actor isolated; the queue is main, so the isolation is
            // asserted rather than hopped to, same as the macOS branch.
            MainActor.assumeIsolated { cachedReduceMotion = UIAccessibility.isReduceMotionEnabled }
        }
        NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { cachedReduceTransparency = UIAccessibility.isReduceTransparencyEnabled }
        }
        #endif
    }()

    #if os(macOS)
    @MainActor
    private static func refresh() {
        let workspace = NSWorkspace.shared
        cachedReduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        cachedReduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
    }
    #endif

    /// The fade every animation collapses to under reduced motion. A duration
    /// rather than `nil`: dropping the animation entirely makes state changes
    /// snap, which reads as a glitch rather than as calm.
    public static let reducedFade: Animation = .easeInOut(duration: 0.2)

    /// A multiplier on every house curve: whatever `anicat_slow_motion` is
    /// set to, and 1 otherwise. It is here rather than in a branch
    /// somebody re-adds by hand each time because a 0.26s close cannot be
    /// judged by eye: five sessions in a row changed a curve, shipped it, and
    /// asked the owner whether it was better. Anything that times itself
    /// against a house curve has to scale with it (see
    /// `RootView.detailFadeOut`), or slow motion pulls the pair apart and
    /// shows a defect that does not exist at 1x.
    /// `defaults write com.anicat.app anicat_slow_motion 8` and relaunch; any
    /// value below 1 is ignored. `UserDefaults` rather than an environment
    /// variable because the app is normally started by Launch Services (the
    /// Dock, `open`, `dev-run.sh`), which does not forward one -- an
    /// `ANICAT_SLOW_MOTION=1 open -n Anicat.app` runs at full speed and looks
    /// like the transition is fine.
    public static let slowMotion: Double = {
        let factor = UserDefaults.standard.double(forKey: "anicat_slow_motion")
        return factor > 1 ? factor : 1
    }()
}

// MARK: - House curves

public extension Animation {
    /// The house curve for an occasion, already collapsed to a fade when the
    /// system has asked for reduced motion. Prefer this over naming
    /// `.snappy`/`.smooth`/`.spring` at a call site: those ignore the setting.
    ///
    /// It cannot cover `phaseAnimator`, `keyframeAnimator` or
    /// `scrollTransition`, which take an animation per phase, per track or a
    /// closure, and so never hand the policy one value to collapse. A phase animator added without its own reduced-motion
    /// path is an accessibility regression; hold it at a single phase — there
    /// is then nothing to advance to — rather than giving it a zero-duration
    /// curve, which still ticks.
    static func sumi(_ kind: SumiMotion) -> Animation {
        guard !MotionPolicy.reduce else { return MotionPolicy.reducedFade }
        let scale = MotionPolicy.slowMotion
        switch kind {
        case .tab:
            return .snappy(duration: 0.25 * scale, extraBounce: 0)
        case .page:
            return .smooth(duration: 0.35 * scale)
        case .pop:
            return .spring(response: 0.30 * scale, dampingFraction: 0.82)
        case .morph:
            return .spring(response: 0.38 * scale, dampingFraction: 0.86)
        case .morphReturn:
            // A duration, not a response, and it has to stay equal to
            // `RootView.detailFadeOut`: the page carrying this poster is
            // removed when that fade ends, so a morph still moving at that
            // moment is cut off rather than finished. A spring has no
            // duration to match against, which is what made the old
            // `response: 0.32` version land after the page had already gone.
            return .smooth(duration: 0.26 * scale)
        }
    }
}

public extension View {
    /// Applies a transition, or a plain opacity fade when the system has asked
    /// for reduced motion. Anything that slides, scales or offsets on
    /// appearance should go through here rather than naming `.transition`
    /// directly.
    @ViewBuilder
    func sumiTransition(_ transition: AnyTransition) -> some View {
        self.transition(MotionPolicy.reduce ? .opacity : transition)
    }

    /// Renders a background material only when the system allows it, and a
    /// solid card fill otherwise. The reduce-transparency setting exists
    /// because a blurred panel over a bright poster is unreadable, and every
    /// vibrancy backdrop in the app is exactly that case.
    @ViewBuilder
    func sumiMaterialBackground(_ material: Material, fallback: Color = SumiTheme.card) -> some View {
        if MotionPolicy.reduceTransparency {
            self.background(fallback)
        } else {
            self.background(material)
        }
    }
}
