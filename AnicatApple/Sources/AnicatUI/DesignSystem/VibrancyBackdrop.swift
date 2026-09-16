import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The sidebar's backdrop: a macOS vibrancy material with a tint over it.
///
/// This is the one place in the skin that is deliberately translucent.
/// `tauri.conf.json` gives the window `windowEffects: ["sidebar", "mica"]`,
/// and `index.css`'s `[data-vibrancy] .glass-fixed` rule then paints
/// `rgba(22, 19, 16, 0.62)` on top — so the Tauri sidebar is 62% ink over an
/// `NSVisualEffectView`, picking up the desktop behind the window as it moves.
///
/// A solid `#1E1A15` fill (the `--surface-color` the non-vibrancy rule uses)
/// is what the port shipped first, and it is the single largest reason the two
/// apps read as different products: the real sidebar shifts with whatever is
/// behind the window, and a flat one never does.
public struct VibrancyBackdrop: View {
    /// `followsWindowActiveState` in the Tauri config: the material goes inert
    /// when the window loses key, which is the standard macOS sidebar
    /// behaviour and something a flat fill cannot imitate.
    public init() {}

    public var body: some View {
        ZStack {
            #if os(macOS)
            VisualEffectView(material: .sidebar, blending: .behindWindow)
            #else
            VisualEffectView()
            #endif
            // The palette's ground at 62%, not a fixed ink: hard-coded
            // #161310 under Paper left the sidebar dark with dark text on it,
            // unreadable, while the rest of the window went light.
            SumiTheme.background.opacity(0.62)
        }
    }
}

#if os(macOS)
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        // `.followsWindowActiveState` matches the Tauri window effect's own
        // state; `.active` would keep the sidebar vivid on an inactive window,
        // which no other macOS app does.
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}
#else
/// The iOS twin. There is no desktop behind an iOS window, so nothing
/// corresponds to `.behindWindow` and the material can only blur the app's
/// own content underneath the sidebar. `.systemThinMaterial` is the closest
/// stand-in for AppKit's `.sidebar` and, like it, follows light/dark itself.
struct VisualEffectView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
    }

    func updateUIView(_ view: UIVisualEffectView, context: Context) {}
}
#endif
