import SwiftUI
import AnicatCoreKit

public struct MediaCard: View, Equatable {
    /// Which catalog a card's id belongs to.
    ///
    /// A card used to be an AniList id and nothing else, which was true while
    /// there was one catalog. TMDB numbers films and series in two separate
    /// spaces of its own, so id 550 alone names three different titles across
    /// the three catalogs -- and the detail page a card opens is chosen by
    /// this, not by which shelf it was tapped on.
    ///
    /// `nil` means AniList: every card written before cinema mode existed
    /// decodes out of the home cache without this key.
    public enum CardCatalog: String, Sendable, Codable {
        case anilist
        case tmdbMovie
        case tmdbTv

        /// The engine's spelling of the same thing. Written out here rather
        /// than at each call site: the conversion was open-coded in six
        /// places and every one of them had to remember that a card without
        /// a catalog is AniList's.
        public var ffi: FfiCatalog {
            switch self {
            case .anilist: return .anilist
            case .tmdbMovie: return .tmdbMovie
            case .tmdbTv: return .tmdbTv
            }
        }
    }

    public struct Item: Identifiable, Sendable, Equatable, Codable {
        public let id: Int64
        public let title: String
        public let coverImageURL: URL?
        public let isManga: Bool
        public let score: Int?
        public let progress: Int?
        public let totalEpisodesOrChapters: Int?
        public let hasNewEpisode: Bool
        public let playlistReason: String?
        public let catalog: CardCatalog?
        /// The AniList list entry behind this card, when it is on the
        /// viewer's list. What a shelf's "Remove from list" deletes by.
        public var listEntryId: Int64? = nil
        /// AniList's format string (`TV`, `MOVIE`, `MANGA`, ...), for the
        /// hover badge. Optional and defaulted so a `HomeCache` snapshot
        /// written before the field existed still decodes.
        public var format: String? = nil
        /// Still airing or publishing, for the hover badge.
        public var isAiring: Bool = false

        public init(
            id: Int64,
            title: String,
            coverImageURL: URL?,
            isManga: Bool = false,
            score: Int? = nil,
            progress: Int? = nil,
            totalEpisodesOrChapters: Int? = nil,
            hasNewEpisode: Bool = false,
            playlistReason: String? = nil,
            catalog: CardCatalog? = nil,
            listEntryId: Int64? = nil,
            format: String? = nil,
            isAiring: Bool = false
        ) {
            self.id = id
            self.title = title
            self.coverImageURL = coverImageURL
            self.isManga = isManga
            self.score = score
            self.progress = progress
            self.totalEpisodesOrChapters = totalEpisodesOrChapters
            self.hasNewEpisode = hasNewEpisode
            self.playlistReason = playlistReason
            self.catalog = catalog
            self.listEntryId = listEntryId
            self.format = format
            self.isAiring = isAiring
        }
    }

    public let item: Item
    public let onSelect: () -> Void
    /// Shared with `MediaDetailView`'s poster so opening/closing this card's
    /// detail page grows the poster from this exact frame instead of a
    /// generic cross-fade. `nil` where a caller hasn't been wired up to a
    /// shared namespace yet — the modifier is skipped rather than crashing.
    public var namespace: Namespace.ID?
    public var onPrefetch: (() -> Void)?

    @State private var isHovered = false
    /// Where the press that opened this card landed, and a counter that
    /// bumps on every such press — `rippleOnPress` reads both to centre and
    /// re-fire the Metal ripple. A `SpatialTapGesture` alongside the card's
    /// `Button` rather than reading the button's own press location: a
    /// `ButtonStyle` configuration carries `isPressed` but no coordinate.
    @State private var ripplePressLocation: CGPoint = .zero
    @State private var ripplePressCount = 0

    public init(
        item: Item,
        namespace: Namespace.ID? = nil,
        onPrefetch: (() -> Void)? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.item = item
        self.namespace = namespace
        self.onPrefetch = onPrefetch
        self.onSelect = onSelect
    }

    // Closures excluded: the caller recreates them every parent body
    // evaluation (they capture `item`), but always as thin wrappers over the
    // same instance methods — two cards with identical `item`/`namespace`
    // behave identically regardless of closure identity. Letting `.equatable()`
    // compare only that lets a fast-scrolling shelf skip re-diffing every
    // already-materialized card each time the shelf's own body re-evaluates.
    public nonisolated static func == (lhs: MediaCard, rhs: MediaCard) -> Bool {
        lhs.item == rhs.item && lhs.namespace == rhs.namespace
    }

    /// The title lifts out of its resting dim on hover. `stableHover` is
    /// macOS-only, so `isHovered` can never become true anywhere else and a
    /// resting 0.8 would leave every title on iOS permanently dim.
    private var titleOpacity: Double {
        #if os(macOS)
        isHovered ? 1.0 : 0.8
        #else
        1.0
        #endif
    }

    public var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                // Poster Image Container (2:3 Aspect Ratio)
                // `Color.clear` is the thing that carries the 2:3 ratio, and
                // everything else rides in an overlay on top of it. Putting
                // the ratio on a shape that also had to host a `.fill`-mode
                // image let the image negotiate its own size back up the
                // stack, so posters in one shelf came out a few points apart
                // and no two cards below them lined up.
                ZStack(alignment: .bottom) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay {
                            // 200pt is this grid's widest card column; ×2 covers
                            // Retina without decoding at a size no cell here
                            // ever draws.
                            CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 400) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .scaleEffect(isHovered ? 1.03 : 1.0)
                                    .animation(.snappy, value: isHovered)
                            } placeholder: {
                                Rectangle()
                                    .fill(SumiTheme.card)
                            }
                        }
                        .background(SumiTheme.card)
                        .clipped()

                    // What the card is, on hover only: format, length and
                    // whether it is still going. The text rows below stay
                    // the two lines they are; a third row of badges on every
                    // card made a shelf read as a table.
                    if isHovered {
                        HStack(spacing: 4) {
                            if let format = item.format {
                                StatusBadge(.format(format.replacingOccurrences(of: "_", with: " ")))
                            }
                            if let total = item.totalEpisodesOrChapters, total > 0 {
                                StatusBadge(.neutral("\(total) \(item.isManga ? "ch" : "ep")"))
                            }
                            if item.isAiring {
                                StatusBadge(.status(item.isManga ? "publishing" : "airing"))
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .transition(.opacity.combined(with: .offset(y: -4)))
                    }

                    // Hover Dim Overlay with Centered Action Button
                    ZStack {
                        Color.black.opacity(isHovered ? 0.5 : 0.0)
                        
                        if isHovered {
                            // `.glass-button`: the surface ink with a hairline
                            // inset, not a white wash. Nothing in this skin
                            // emits light.
                            Image(systemName: item.isManga ? "book.fill" : "chevron.right")
                                .font(.system(size: 20, weight: .regular))
                                .foregroundColor(SumiTheme.foreground)
                                .frame(width: 48, height: 48)
                                .background(SumiTheme.card)
                                .clipShape(Circle())
                                .overlay(Circle().stroke(SumiTheme.border, lineWidth: 1))
                                .transition(.scale(scale: 0.85).combined(with: .opacity))
                        }
                    }
                    .animation(.snappy, value: isHovered)

                    // `.poster-tick` (index.css:549): 3px, an accent fill over a
                    // black 45% track. The track is what makes it legible on a
                    // bright poster — the fill alone vanishes into pale art.
                    // Only once there is progress to show: at zero the track
                    // alone was a dark strip along the bottom of every
                    // Planning poster, read as a ledge the card never had.
                    if let progress = item.progress, progress > 0, let total = item.totalEpisodesOrChapters, total > 0 {
                        let pct = min(max(CGFloat(progress) / CGFloat(total), 0), 1)
                        // scaleEffect instead of GeometryReader: this bar lives inside
                        // MediaCard, the most-instantiated view in the app, and a
                        // GeometryReader here forced a second layout pass per card in
                        // every scrolling grid just to compute a fill width.
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.black.opacity(0.45))
                            AnimatedProgressFill(pct: pct)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
                // On top of the poster morph, not instead of it: the ripple
                // is a layer effect over whatever frame the poster is
                // currently in, morphing or not.
                .rippleOnPress(at: ripplePressLocation, trigger: ripplePressCount)
                .ifLet(namespace) { view, namespace in
                    view.matchedGeometryEffect(id: item.id, in: namespace)
                }
                // `.card-glow:hover` (index.css:377-382): lift 2px and deepen
                // the shadow on hover/focus — the poster's own scale/dim
                // covered the "something responded" read but not the "this
                // row raised toward you" one every other hoverable surface has.
                .offset(y: isHovered ? -2 : 0)
                .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: isHovered ? 14 : 0, y: isHovered ? 10 : 0)
                .animation(.snappy, value: isHovered)

                // Card Info: Clean Typography, Art carries the card
                VStack(alignment: .leading, spacing: 4) {
                    // Two lines of `leading-tight` 14px, always. `line-clamp-2`
                    // reserves the space on the web whether or not the title
                    // uses it; SwiftUI collapses to the text it has, so a
                    // one-line title made its card shorter than its neighbours
                    // and the metadata rows across a shelf never lined up.
                    Text(item.title)
                        .font(.sumiHeading(size: 14, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(2)
                        .lineSpacing(1.5)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
                        .opacity(titleOpacity)
                        .offset(y: isHovered ? -1 : 0)
                        .animation(.snappy, value: isHovered)

                    HStack(spacing: 6) {
                        if let score = item.score, score > 0 {
                            HStack(spacing: 2) {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 10))
                                    .foregroundColor(SumiTheme.muted)
                                Text("\(score)%")
                            }
                        }

                        if let progress = item.progress {
                            if item.hasNewEpisode {
                                Text("Ep \(progress + 1) out")
                                    .foregroundColor(SumiTheme.indigo)
                                    .fontWeight(.semibold)
                            } else {
                                let totalStr = item.totalEpisodesOrChapters.map { String($0) } ?? "?"
                                Text("\(progress)/\(totalStr)")
                            }
                        } else if let reason = item.playlistReason {
                            Text(reason)
                                .lineLimit(1)
                        }

                        // A card with no score, no list entry and no playlist
                        // reason has nothing in this row at all, and an empty
                        // `HStack` is zero-height however large a `minHeight`
                        // is asked of it. In a shelf that only cost a few
                        // points; in the search grid the difference compounds
                        // down every row. A hair space keeps the line box.
                        Text("\u{200A}")
                    }
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    // The web's metadata `<p>` occupies its line height even
                    // with nothing in it. A title with no score and no list
                    // entry otherwise collapsed this row away and made its
                    // card shorter than the ones beside it.
                    .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .contentShape(Rectangle())
        // `simultaneousGesture` rather than replacing the tap: the ripple
        // needs the press location, but this must never be the gesture
        // that decides whether `onSelect` fires — that stays the Button's.
        .simultaneousGesture(
            SpatialTapGesture()
                .onEnded { value in
                    ripplePressLocation = value.location
                    ripplePressCount += 1
                }
        )
        .stableHover { hovering in
            isHovered = hovering
            if hovering {
                onPrefetch?()
            }
        }
    }
}

/// The `.poster-tick` fill, animated with a small overshoot past its target
/// on every increase instead of jumping straight there — a watched episode
/// landing should read as a tick forward, not a redraw.
///
/// `keyframeAnimator(initialValue:trigger:)` restarts from the literal
/// `initialValue` argument every time `trigger` changes, not from wherever
/// the interpolation currently sits — so `initialValue: pct` (the *new*
/// value) made the bar snap straight to its target on the same frame the
/// retrigger fired and then overshoot from there, which is the linear jump
/// this was meant to remove, with a twitch stapled on. `settledPct` is kept
/// one step behind on purpose: it only catches up to `pct` after the
/// animation that was chasing the old target has actually finished, so the
/// next `keyframeAnimator` restart still has the true old value to animate
/// from.
private struct AnimatedProgressFill: View {
    let pct: CGFloat

    @State private var settledPct: CGFloat = 0
    @State private var trigger = 0
    /// Whether the in-flight (or next) keyframe track should overshoot.
    /// Only an increase gets the tick-forward flourish; a decrease (a
    /// progress reset) still has to reach `pct` visually, so it still bumps
    /// `trigger`, just along a plain settle with nothing to overshoot past.
    @State private var isIncrease = true

    var body: some View {
        Group {
            if MotionPolicy.reduce {
                // The web's `.poster-tick` never overshot; this branch exists
                // only because Reduce Motion asks for *less* movement, not a
                // jump-cut, so a plain house curve stands in for the
                // keyframe track rather than disabling animation outright.
                Rectangle()
                    .fill(SumiTheme.indigo)
                    .scaleEffect(x: pct, y: 1, anchor: .leading)
                    .animation(.sumi(.pop), value: pct)
            } else {
                Rectangle()
                    .fill(SumiTheme.indigo)
                    .keyframeAnimator(initialValue: settledPct, trigger: trigger) { content, value in
                        content.scaleEffect(x: value, y: 1, anchor: .leading)
                    } keyframes: { _ in
                        if isIncrease {
                            CubicKeyframe(min(pct + 0.04, 1.0), duration: 0.4)
                            SpringKeyframe(pct, duration: 0.2)
                        } else {
                            CubicKeyframe(pct, duration: 0.25)
                        }
                    }
            }
        }
        .onAppear { settledPct = pct }
        .onChange(of: pct) { oldValue, newValue in
            guard newValue != oldValue else { return }
            isIncrease = newValue > oldValue
            trigger += 1
            // Matches the keyframe track's own total duration above (0.6s
            // overshoot, 0.25s plain settle) — updating `settledPct` any
            // sooner hands the *next* restart a starting value the current
            // animation hasn't visually reached yet, which is the same bug
            // this whole struct exists to avoid, just moved one step later.
            let settleDelay = isIncrease ? 0.6 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                settledPct = newValue
            }
        }
    }
}
