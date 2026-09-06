import SwiftUI

/// "Has this scroll view passed N points?", as a `Bool`.
///
/// `ResponsiveScrollingPatch` makes scroll updates arrive at the display's
/// full rate, so anything that stores the raw offset in `@State` re-evaluates
/// the owning page body once per tick — on the detail page that is the banner,
/// the poster column and every tab section, ~120 times a second. Both paths
/// here reduce the offset to a `Bool` before it reaches the caller's state, so
/// the page body runs twice per crossing instead.
struct ScrollPassedThreshold: ViewModifier {
    let threshold: CGFloat
    @Binding var passed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 15.0, iOS 18.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top > threshold
            } action: { _, isPassed in
                if passed != isPassed { passed = isPassed }
            }
        } else {
            // macOS 14 has no scroll geometry to observe; the caller puts a
            // `ScrollThresholdProbe` at the top of the content instead.
            content
        }
    }
}

/// The macOS 14 half of `ScrollPassedThreshold`: a zero-height marker at the
/// top of the scrolled content that reports the same crossing from its own
/// frame. Its body — which draws nothing — is what re-runs per scroll tick,
/// and the comparison against `threshold` happens there, so the crossing still
/// reaches the caller as a `Bool` that changes twice.
struct ScrollThresholdProbe: View {
    let threshold: CGFloat
    @Binding var passed: Bool

    var body: some View {
        GeometryReader { proxy in
            let crossed = -proxy.frame(in: .scrollView).minY > threshold
            Color.clear
                .onChange(of: crossed) { _, isCrossed in
                    if passed != isCrossed { passed = isCrossed }
                }
        }
        .frame(height: 0)
    }
}

extension View {
    /// Reports whether the enclosing scroll view has scrolled past
    /// `threshold` points. On macOS 14 this modifier does nothing on its own —
    /// pair it with a `ScrollThresholdProbe` inside the scrolled content.
    func scrollPassedThreshold(_ threshold: CGFloat, passed: Binding<Bool>) -> some View {
        modifier(ScrollPassedThreshold(threshold: threshold, passed: passed))
    }
}
