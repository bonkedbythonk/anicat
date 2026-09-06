import SwiftUI

/// Motion shared by the navigation shell and the grids that swap contents
/// under it: the section entrance and the staggered card entrance.

/// Which section the rail was on before the current one, so the incoming
/// section can slide in the direction of travel.
///
/// This cannot be view state. `RootView` gives the section content an
/// `.id(currentNavSection)`, so the entire subtree — and every `@State` in it
/// — is destroyed by the very change whose direction it would have to
/// describe, and a fresh `@State` has nothing to compare against. Written
/// only from `onAppear`, which runs once per materialisation and never for the
/// outgoing side.
@MainActor
private enum SectionTravel {
    static var lastIndex: Int?

    /// +1 moving down the rail, -1 moving up, 0 for the first section of the
    /// launch (nothing was left, so nothing should slide).
    static func direction(to index: Int) -> CGFloat {
        guard let last = lastIndex, last != index else { return 0 }
        return index > last ? 1 : -1
    }
}

/// Slides a section's content 10pt in the direction of travel down the
/// sidebar: a section further down the rail enters from below, one further up
/// enters from above. The fade is the content column's own `.transition`.
///
/// The offset is driven by state that settles on appear rather than by an
/// `AnyTransition`: the identity swap happens at `RootView`'s `.id`, which
/// already carries a transition of its own, and a second one declared further
/// down the subtree never gets to run.
public struct SectionSlide<Content: View>: View {
    private let index: Int
    private let travel: CGFloat
    private let content: Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    public init(index: Int, @ViewBuilder content: () -> Content) {
        self.index = index
        // Read, never written: `init` re-runs on every parent body evaluation,
        // including ones that happen while the outgoing section is still being
        // torn down, so recording the new index here would leave the tracker
        // holding the wrong section for the next navigation.
        self.travel = SectionTravel.direction(to: index)
        self.content = content()
    }

    public var body: some View {
        content
            .offset(y: settled || reduceMotion ? 0 : travel * 10)
            .onAppear {
                SectionTravel.lastIndex = index
                withAnimation(.snappy(duration: 0.3)) { settled = true }
            }
    }
}

/// How a grid's cards enter once its contents have been replaced wholesale.
///
/// Opt-in per grid: the poster grid is shared with the Reading and History
/// pages, whose contents are loaded once and never swapped under the viewer,
/// so a default entrance there would only fire on the initial paint.
public struct SumiGridEntrance: Equatable, Sendable {
    /// Seconds of delay added per card.
    public let step: Double
    /// The card index past which the delay stops growing, so a 300-item list
    /// does not finish arriving five seconds after the tap.
    public let cap: Int
    /// Where a card starts, signed by the direction of the change.
    public let offset: CGSize

    public init(step: Double, cap: Int, offset: CGSize) {
        self.step = step
        self.cap = cap
        self.offset = offset
    }
}

private struct StaggeredEntranceModifier: ViewModifier {
    let index: Int
    let entrance: SumiGridEntrance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let delay = Double(min(index, entrance.cap)) * entrance.step
        content.transition(
            reduceMotion
                ? AnyTransition.opacity.animation(.smooth(duration: 0.2))
                // Asymmetric so the change reads as travel: symmetric, the
                // cards being replaced slid out the same way the new ones
                // slid in, and the two overlapping stagger runs looked like
                // one list jittering in place. The old cards also leave
                // undelayed — a delay there only holds them over the new
                // ones.
                : .asymmetric(
                    insertion: AnyTransition.offset(entrance.offset)
                        .combined(with: .opacity)
                        .animation(.smooth(duration: 0.3).delay(delay)),
                    removal: AnyTransition.offset(
                        CGSize(width: -entrance.offset.width, height: -entrance.offset.height)
                    )
                    .combined(with: .opacity)
                    .animation(.smooth(duration: 0.2))
                )
        )
    }
}

public extension View {
    /// Gives a card in a replaced grid a delayed fade-and-slide entrance.
    ///
    /// Applied by the grid rather than stored on `MediaCard`: the card's
    /// `Equatable` conformance compares only `item` and `namespace`, so an
    /// index it carried would not take part in the comparison and a card whose
    /// position changed while its item did not would keep a stale delay.
    func sumiStaggeredEntrance(index: Int, entrance: SumiGridEntrance?) -> some View {
        ifLet(entrance) { view, entrance in
            view.modifier(StaggeredEntranceModifier(index: index, entrance: entrance))
        }
    }
}
