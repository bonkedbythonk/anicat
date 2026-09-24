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
        /// hover line. Optional and defaulted so a `HomeCache` snapshot
        /// written before the field existed still decodes.
        public var format: String? = nil
        /// Still airing or publishing, for the hover line.
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
    /// The last entry of the card's right-click menu, for the shelves that
    /// can take a title off themselves. Handed in rather than attached by the
    /// caller: a `.contextMenu` wrapped around the card would be a second
    /// menu on the same view, and only one of the two ever opens.
    public var removal: (label: String, action: () -> Void)?

    @State private var isHovered = false

    /// AniList formats arrive as `TV_SHORT`, `MOVIE`, `OVA`. Sentence-casing
    /// the whole string gave "Tv short" and "Ova". The initialisms are named
    /// rather than guessed by length: "any word of three letters" also kept
    /// `ONE_SHOT` as "ONE Shot".
    /// AniList's relation types (`SIDE_STORY`, `SPIN_OFF`) as words. Printed
    /// raw, the Related tab showed "SIDE STORY" in capitals after the rest of
    /// the app had moved to sentence case.
    static func displayRelation(_ raw: String) -> String {
        if raw == "SPIN_OFF" { return "Spin-off" }
        let words = raw.replacingOccurrences(of: "_", with: " ").lowercased()
        return words.prefix(1).uppercased() + words.dropFirst()
    }

    static func displayFormat(_ raw: String) -> String {
        raw.split(separator: "_")
            .map { ["TV", "ONA", "OVA", "OAD"].contains($0) ? String($0) : $0.capitalized }
            .joined(separator: " ")
    }

    public init(
        item: Item,
        namespace: Namespace.ID? = nil,
        onPrefetch: (() -> Void)? = nil,
        removal: (label: String, action: () -> Void)? = nil,
        onSelect: @escaping () -> Void
    ) {
        self.item = item
        self.namespace = namespace
        self.onPrefetch = onPrefetch
        self.removal = removal
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
                        // Fixed white on a black scrim, not palette colours:
                        // this sits on artwork, and Paper's dark foreground
                        // would vanish into a dark poster.
                        HStack(spacing: 8) {
                            if let format = item.format {
                                Text(Self.displayFormat(format))
                                    .sumiTabularMono(size: 10, weight: .semibold)
                            }
                            if let total = item.totalEpisodesOrChapters, total > 0 {
                                Text("\(total) \(item.isManga ? "ch" : "ep")")
                                    .sumiTabularMono(size: 10)
                            }
                            if item.isAiring {
                                Text(item.isManga ? "Publishing" : "Airing")
                                    .sumiTabularMono(size: 10)
                                    .foregroundColor(Color(hex: "#A8C9E6"))
                            }
                        }
                        .foregroundColor(.white.opacity(0.92))
                        .padding(.horizontal, 8)
                        .padding(.top, 7)
                        .padding(.bottom, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            LinearGradient(
                                colors: [.black.opacity(0.72), .clear],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }

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
                            Rectangle()
                                .fill(SumiTheme.indigo)
                                .scaleEffect(x: pct, y: 1, anchor: .leading)
                                .animation(.smooth, value: pct)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(isHovered ? SumiTheme.foreground.opacity(0.25) : SumiTheme.border, lineWidth: 1)
                )
                .ifLet(namespace) { view, namespace in
                    view.matchedGeometryEffect(id: item.id, in: namespace)
                }
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
                        .animation(.snappy, value: isHovered)

                    HStack(spacing: 6) {
                        if let score = item.score, score > 0 {
                            Text("\(score)%")
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
        .stableHover { hovering in
            isHovered = hovering
            if hovering {
                onPrefetch?()
            }
        }
        #if !os(tvOS)
        .contextMenu {
            Button("Open", action: onSelect)
            if let removal {
                Button(removal.label, role: .destructive, action: removal.action)
            }
        }
        #endif
    }
}
