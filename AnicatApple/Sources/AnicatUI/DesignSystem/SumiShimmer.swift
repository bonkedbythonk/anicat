import SwiftUI

/// The sweep that tells a skeleton apart from a view that has simply stopped
/// loading.
///
/// Applied to a whole grid, shelf or list rather than to each placeholder:
/// one band crossing the container reads as a single surface being filled in,
/// where twelve card-sized bands read as twelve separate spinners. It also
/// keeps the `.mask` — which draws the skeleton a second time — to one per
/// container instead of one per card.
private struct ShimmerModifier: ViewModifier {
    /// Unit-point travel. The band starts and ends fully off the view so it
    /// never appears to spawn or die mid-surface; a 0...1 range popped a
    /// highlight into existence at the left edge on every pass.
    private static let travelStart: CGFloat = -0.6
    private static let travelEnd: CGFloat = 1.6
    /// Half the band's width, also in unit points. Wider than this and a
    /// 180pt shelf card is lit end to end, which is a fade, not a sweep.
    private static let halfWidth: CGFloat = 0.35

    let period: Double

    /// The live setting rather than `MotionPolicy.reduce`: that one is a
    /// cached static read from a notification observer, so flipping Reduce
    /// Motion while a skeleton is on screen would not re-render this view.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = ShimmerModifier.travelStart

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content
                .overlay {
                    // Tinted with `foreground`, not white: the band has to
                    // read against Washi Paper as well as against Sumi Ink,
                    // and on the light palette a white sweep is invisible.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: SumiTheme.foreground.opacity(0.10), location: 0.5),
                            .init(color: .clear, location: 1)
                        ],
                        startPoint: UnitPoint(x: phase - Self.halfWidth, y: 0),
                        endPoint: UnitPoint(x: phase + Self.halfWidth, y: 1)
                    )
                    .allowsHitTesting(false)
                }
                .mask(content)
                .onAppear {
                    withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                        phase = Self.travelEnd
                    }
                }
        }
    }
}

public extension View {
    /// Sweeps a highlight across a loading placeholder, or leaves it still
    /// when the system has asked for reduced motion.
    ///
    /// Belongs on the outermost container of a set of placeholders, never on
    /// real content: it masks what it is applied to, so anything with a
    /// background of its own is lit along with the bars.
    func sumiShimmer(period: Double = 1.4) -> some View {
        modifier(ShimmerModifier(period: period))
    }
}
