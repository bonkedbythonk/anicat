import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The chrome's own colours, fixed to the dark palette. The player is
/// always drawn on black and its bars on black scrims, and under the Paper
/// theme `SumiTheme.foreground` resolved to ink: dark text on a dark scrim,
/// so the controls vanished. The popovers keep the theme's colours, since
/// their own material follows the appearance.
enum PlayerChrome {
    static var foreground: Color { SumiPalette.ink.foreground }
    static var muted: Color { SumiPalette.ink.muted }

    /// What a transient card over the picture sits on when the system
    /// refuses materials. Dark enough to hold white text over a white
    /// frame; the material path below carries the same job by blurring.
    static let scrimFallback = Color.black.opacity(0.72)
    static let scrimEdge = Color.white.opacity(0.12)
}

extension View {
    /// The one ground for anything that floats over the picture: the seek
    /// flash, the HUD badge, the skip and Up Next cards, the seek tooltip.
    ///
    /// They used to carry five hand-picked blacks between 0.55 and 0.85,
    /// and side by side (a HUD badge fading while the Up Next card was up)
    /// read as five different components. Glass over the picture, pinned
    /// dark so the material does not flip to its light look on a white
    /// frame, with the ink chrome's hairline; a solid scrim under Reduce
    /// Transparency, where a blurred panel over a bright shot is unreadable.
    func playerScrim<S: InsettableShape>(_ shape: S) -> some View {
        self.sumiMaterialBackground(.ultraThinMaterial, fallback: PlayerChrome.scrimFallback)
            .environment(\.colorScheme, .dark)
            .clipShape(shape)
            .overlay(shape.strokeBorder(PlayerChrome.scrimEdge, lineWidth: 1))
    }
}


extension View {
    /// Contrast for a bar with nothing painted behind it.
    ///
    /// Two shadows, not one: the tight pass darkens the pixel a glyph's
    /// edge lands on, which is what keeps 13pt text off a bright glow, and
    /// the wide pass lifts the whole bar off a busy one. A single wide
    /// shadow left the small labels smeared rather than legible, and a
    /// single tight one did nothing at all against a pale letterbox.
    /// `PlayerChrome` pins the chrome's foreground to the ink palette, so
    /// the halo is always dark under light content, never dark on dark.
    func chromeLegibility() -> some View {
        shadow(color: Color.black.opacity(0.75), radius: 2)
            .shadow(color: Color.black.opacity(0.45), radius: 10, y: 1)
    }

    /// Holds the chrome up while the pointer rests on a bar, and restarts
    /// the autohide countdown when it leaves.
    ///
    /// Only the bar's own rect, not the letterbox gap it sits in: pinning
    /// the whole gap meant a pointer parked anywhere along a 1512 pt strip
    /// of black kept the transport on screen for the rest of the episode.
    @ViewBuilder
    func chromeHoverPin(isOver: Binding<Bool>, controller: PlayerController) -> some View {
        #if os(macOS)
        onHover { hovering in
            isOver.wrappedValue = hovering
            if !hovering {
                controller.showControlsBriefly()
            }
        }
        #else
        self
        #endif
    }
}
