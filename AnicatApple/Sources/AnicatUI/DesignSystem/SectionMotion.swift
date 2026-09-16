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

// MARK: - Shelf edges

/// How a card reacts to the edge of a horizontal shelf.
///
/// A shelf is clipped by its own scroll view, so without this a card is cut
/// in half by an invisible line at the page margin. Fading and shrinking it
/// there gives the clip somewhere to happen and makes the shelf read as
/// continuing past the window rather than ending at it.
private struct ShelfEdgeModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            // Not for a shelf whose cards are sized with
            // `containerRelativeFrame`: measured on the phone's Continue
            // Watching row, the clipped third card stayed at identity and
            // nothing happened, so the modifier is left off there rather
            // than sitting in the tree doing nothing.
            //
            // `.interactive` and an explicit threshold, not the defaults.
            // The default configuration calls a card identity as soon as any
            // part of it is visible, so the half-clipped card at the edge —
            // the only one this is for — never left identity and nothing
            // happened on screen. `.visible(0.9)` puts the fade where the
            // clip is, and the interactive configuration tracks the scroll
            // instead of stepping between phases.
            content.scrollTransition(
                ScrollTransitionConfiguration.interactive.threshold(.visible(0.9)),
                axis: .horizontal
            ) { view, phase in
                // 1 at rest, 0 fully outside. `phase.value` rather than
                // `isIdentity`: the flag is a step and reads as the card
                // blinking as it crosses.
                let settled = 1 - min(abs(phase.value), 1)
                // Scale stays shallow and there is no offset: on every shelf
                // but the stills strip the card is also the poster morph's
                // `matchedGeometryEffect` source, which already stacks an
                // offset and a shadow of its own, and the morph flies from
                // whatever frame this leaves behind. A card tapped while
                // half off the edge should look like it came from where it
                // was, not from somewhere the transition moved it.
                return view
                    .opacity(0.45 + 0.55 * settled)
                    .scaleEffect(0.94 + 0.06 * settled)
            }
        }
    }
}

public extension View {
    /// Fades and shrinks a shelf card as it passes the edge of its scroll
    /// view. Nothing under reduced motion: `scrollTransition` takes a closure,
    /// so `Animation.sumi(_:)` has no single value to collapse and the branch
    /// has to be here.
    func sumiShelfEdge() -> some View {
        modifier(ShelfEdgeModifier())
    }
}
