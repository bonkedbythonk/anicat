import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Feedback defaults

/// The key the haptics switch in Settings writes. Spelled literally at the
/// Mac's `@AppStorage` -- the property wrapper needs a literal -- so the two
/// must agree.
public enum FeedbackDefaults {
    public static let hapticsKey = "anicat_haptics"

    public static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
    }
}

// MARK: - Haptics

/// The two gesture haptics, separate from `SumiHaptics.selection` (which is
/// the tap/selection tick every control already fires and has no toggle).
/// These two ride continuous gestures, so they need a way to be turned off
/// without silencing the rest of the app.
public enum AppHaptics {
    public static var isEnabled: Bool { FeedbackDefaults.hapticsEnabled }

    /// The three app events a phone makes felt. Nothing on the Mac: its
    /// trackpad only ticks under a finger, and these fire after the click.
    public enum Moment: Sendable {
        case watchedTick
        case error
        case playerOpen
    }

    /// A phone in a pocket shows nothing, so the watched mark and the error
    /// are the two moments that need to be felt; the player open is the one
    /// the finger is already on.
    @MainActor
    public static func play(_ moment: Moment) {
        #if os(iOS)
        guard isEnabled else { return }
        switch moment {
        case .watchedTick:
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        case .error:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        case .playerOpen:
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        #endif
    }

    /// The moment a horizontal drag crosses the distance that will commit a
    /// back navigation. `.alignment` is the snap pattern, which is what
    /// "you have crossed the line" feels like on a trackpad.
    @MainActor
    public static func swipeThreshold() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #elseif os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// A scrub landing on a chapter or a skip boundary. `.levelChange` is the
    /// heavier of the two patterns, so a seek reads as a bigger event than a
    /// swipe crossing its threshold.
    @MainActor
    public static func seekSnap() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #elseif os(iOS)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }
}
