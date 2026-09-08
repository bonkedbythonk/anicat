import SwiftUI

/// "Has this scroll view passed N points?", as a `Bool`.
///
/// `ResponsiveScrollingPatch` makes scroll updates arrive at the display's
/// full rate, so anything that stores the raw offset in `@State` re-evaluates
/// the owning page body once per tick — on the detail page that is the banner,
/// the poster column and every tab section, ~120 times a second. The offset is
/// reduced to a `Bool` before it reaches the caller's state, so the page body
/// runs twice per crossing instead.
struct ScrollPassedThreshold: ViewModifier {
    let threshold: CGFloat
    @Binding var passed: Bool

    func body(content: Content) -> some View {
        content.onScrollGeometryChange(for: Bool.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top > threshold
        } action: { _, isPassed in
            if passed != isPassed { passed = isPassed }
        }
    }
}

extension View {
    /// Reports whether the enclosing scroll view has scrolled past
    /// `threshold` points.
    func scrollPassedThreshold(_ threshold: CGFloat, passed: Binding<Bool>) -> some View {
        modifier(ScrollPassedThreshold(threshold: threshold, passed: passed))
    }
}
