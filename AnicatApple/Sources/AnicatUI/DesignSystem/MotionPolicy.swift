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
        cachedReduceMotion = UIAccessibility.isReduceMotionEnabled
        cachedReduceTransparency = UIAccessibility.isReduceTransparencyEnabled
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
}

// MARK: - House curves

public extension Animation {
    /// The house curve for an occasion, already collapsed to a fade when the
    /// system has asked for reduced motion. Prefer this over naming
    /// `.snappy`/`.smooth`/`.spring` at a call site: those ignore the setting.
    static func sumi(_ kind: SumiMotion) -> Animation {
        guard !MotionPolicy.reduce else { return MotionPolicy.reducedFade }
        switch kind {
        case .tab:
            return .snappy(duration: 0.25, extraBounce: 0)
        case .page:
            return .smooth(duration: 0.35)
        case .pop:
            return .spring(response: 0.30, dampingFraction: 0.82)
        case .morph:
            return .spring(response: 0.38, dampingFraction: 0.86)
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
