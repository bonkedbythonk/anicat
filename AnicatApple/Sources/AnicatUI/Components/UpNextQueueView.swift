import SwiftUI

public struct UpNextQueueView: View {
    public struct QueueEntry: Identifiable, Sendable, Codable {
        public let id: Int64
        public let title: String
        public let thumbnailURL: URL?
        public let nextEpisodeOrChapter: Int
        public let totalCount: Int
        public let progressPercent: Double // 0 to 100
        public let watchedTimeAgo: String?
        public let hasNewEpisode: Bool
        public let unit: String // "EP" or "CH"
        /// When the row's next episode airs, set only while it has not: the
        /// viewer is caught up and there is nothing to play. Optional so a
        /// `HomeCache` snapshot written before it existed still decodes.
        public let nextAiringAt: Int64?

        /// Against the clock, not just the stored time: an episode that aired
        /// while the app was open kept its row as "Airs aired" with a Details
        /// button until the rollover refresh rebuilt the queue.
        public var isAwaitingEpisode: Bool {
            guard let nextAiringAt else { return false }
            return Double(nextAiringAt) > Date().timeIntervalSince1970
        }
        /// On AniList's Rewatching list rather than Watching. Optional for
        /// the same `HomeCache` reason as `nextAiringAt`.
        public let isRewatch: Bool?
        /// The title's wide banner, behind the spotlight row. Nil when the
        /// title has never been opened (no detail snapshot to read it
        /// from); the cover stands in. Optional for the `HomeCache` reason.
        public let bannerURL: URL?
        /// The next episode's title and still, read from the detail snapshot
        /// of a title the viewer has opened, for the row's middle. Nil for a
        /// title never opened; the row keeps its old shape then. Optional for
        /// the `HomeCache` reason.
        public var nextEpisodeTitle: String? = nil
        public var nextEpisodeStillURL: URL? = nil

        /// Three nouns, not two: cinema's queue passes "FILM" as well as "EP".
        var countLabel: String {
            let noun = unit == "CH" ? "Chapter" : unit == "FILM" ? "Film" : "Episode"
            return "\(noun) \(nextEpisodeOrChapter)\(totalCount > 0 ? " of \(totalCount)" : "")"
        }

        public init(
            id: Int64,
            title: String,
            thumbnailURL: URL?,
            nextEpisodeOrChapter: Int,
            totalCount: Int = 0,
            progressPercent: Double = 0,
            watchedTimeAgo: String? = nil,
            hasNewEpisode: Bool = false,
            unit: String = "EP",
            nextAiringAt: Int64? = nil,
            isRewatch: Bool? = nil,
            bannerURL: URL? = nil
        ) {
            self.id = id
            self.title = title
            self.thumbnailURL = thumbnailURL
            self.nextEpisodeOrChapter = nextEpisodeOrChapter
            self.totalCount = totalCount
            self.progressPercent = progressPercent
            self.watchedTimeAgo = watchedTimeAgo
            self.hasNewEpisode = hasNewEpisode
            self.unit = unit
            self.nextAiringAt = nextAiringAt
            self.isRewatch = isRewatch
            self.bannerURL = bannerURL
        }
    }

    public let items: [QueueEntry]
    public let namespace: Namespace.ID?
    // No `openingSourceKey`/`shelfKey` here. They used to be stored and
    // never read: the row below hard-codes `namespace: nil`, so no row in
    // this view is ever half of a poster morph. Keeping them made the
    // callers set `AppModel.openingDetailSourceKey` for an open that has
    // nothing to morph, and everything gated on "is a morph running" —
    // the page's own scale, the feed push-back — switched itself off.
    /// The second namespace, for the thumbnail-to-video morph a Play press
    /// starts. Distinct from `namespace` above because the two morphs have
    /// different destinations and different lifetimes — see
    /// `AppModel.openingPlayerSourceKey`.
    public let playerNamespace: Namespace.ID?
    /// Which row that morph starts from, as "upnext:<id>:<episode>".
    public let playerSourceKey: String?
    public let onSelect: (QueueEntry) -> Void
    public let onPlay: (QueueEntry) -> Void
    /// Right-click "Remove", when the queue can forget a row. Cinema's
    /// queue is local watch history and can; the anime queue is the
    /// AniList list and cannot, so it passes nothing and gets no menu.
    public let onRemove: ((QueueEntry) -> Void)?

    /// The one place the Up Next form of the key is spelled — the play call
    /// site sets it and the row below compares against it.
    public nonisolated static func playerMorphKey(catalogId: Int64, episode: Int) -> String {
        "upnext:\(catalogId):\(episode)"
    }

    public init(
        items: [QueueEntry],
        namespace: Namespace.ID? = nil,
        playerNamespace: Namespace.ID? = nil,
        playerSourceKey: String? = nil,
        onSelect: @escaping (QueueEntry) -> Void,
        onPlay: @escaping (QueueEntry) -> Void,
        onRemove: ((QueueEntry) -> Void)? = nil
    ) {
        self.items = items
        self.namespace = namespace
        self.playerNamespace = playerNamespace
        self.playerSourceKey = playerSourceKey
        self.onSelect = onSelect
        self.onPlay = onPlay
        self.onRemove = onRemove
    }

    private func morphSource(for entry: QueueEntry) -> EpisodeMorphSource? {
        guard let playerNamespace,
              let playerSourceKey,
              playerSourceKey == Self.playerMorphKey(catalogId: entry.id, episode: entry.nextEpisodeOrChapter)
        else { return nil }
        return EpisodeMorphSource(key: playerSourceKey, namespace: playerNamespace)
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                if index == 0 {
                    // The first row is the one that gets played, and the one
                    // picture Home has: its banner runs behind it, faded
                    // into the card ground under the text. Home had no hero
                    // since the port; a full one would put 300pt of poster
                    // above anything that can be clicked, and this is the
                    // same picture attached to the thing being clicked.
                    SpotlightRow(
                        entry: entry,
                        morphSource: morphSource(for: entry),
                        onSelect: { onSelect(entry) },
                        onPlay: { entry.isAwaitingEpisode ? onSelect(entry) : onPlay(entry) }
                    )
                    .contextMenu {
                        if let onRemove {
                            Button("Remove from Continue Watching") { onRemove(entry) }
                        }
                    }
                } else {
                RowView(
                    entry: entry,
                    // Never a real namespace here, deliberately: the
                    // thumbnail is a 104x60 landscape rect and the detail
                    // page's poster is portrait — matchedGeometryEffect
                    // interpolates the frame linearly, so that morph reads
                    // as a visible squash/stretch rather than a clean grow.
                    // Same call as `WeekStrip`, which never had a thumbnail
                    // wired up to it in the first place.
                    namespace: nil,
                    // The player morph has no such mismatch: this 104x60
                    // still is landscape and so is the video frame it grows
                    // into, so the linear frame interpolation that made the
                    // poster morph squash is exactly right here.
                    morphSource: morphSource(for: entry),
                    onSelect: { onSelect(entry) },
                    // Caught up: nothing to resolve, and a Play here ended in
                    // "No HD torrent found" for an episode that had not
                    // aired. The button opens the page instead.
                    onPlay: { entry.isAwaitingEpisode ? onSelect(entry) : onPlay(entry) }
                )
                .contextMenu {
                    if let onRemove {
                        Button("Remove from Continue Watching") { onRemove(entry) }
                    }
                }
                }

                if index < items.count - 1 {
                    // A `Divider` draws its own system separator colour and
                    // ignores `.background`, so the hairline read as a bright
                    // macOS rule instead of the 10% cream border.
                    Rectangle()
                        .fill(SumiTheme.border)
                        .frame(height: 1)
                }
            }
        }
    }

    /// The queue's first row as a wide card: the banner behind, the still,
    /// the title at heading size, the meta line, the progress capsule and
    /// "Resume Ep 4" as words. The whole banner is the play button, a poster
    /// you click; a pale filled button sat on the busy artwork and looked
    /// pasted on. Open the title from its right-click menu, or from any row.
    private struct SpotlightRow: View {
        let entry: QueueEntry
        let morphSource: EpisodeMorphSource?
        let onSelect: () -> Void
        let onPlay: () -> Void

        @State private var isInfoHovered = false
        @State private var isActionHovered = false

        private static let height: CGFloat = 176

        /// "Details" while the next episode has not aired: nothing to play,
        /// so the words open the title instead.
        private var action: () -> Void { entry.isAwaitingEpisode ? onSelect : onPlay }

        private var actionLabel: String {
            if entry.isAwaitingEpisode { return "Details" }
            switch entry.unit {
            case "CH": return "Continue Ch \(entry.nextEpisodeOrChapter)"
            case "FILM": return "Resume"
            default: return "Resume Ep \(entry.nextEpisodeOrChapter)"
            }
        }

        // Two targets, split where the words start: the still and title open
        // the page, the right side resumes. One banner-wide resume left no
        // way into the title from its biggest picture on the home screen.
        var body: some View {
            HStack(spacing: 0) {
                Button(action: onSelect) {
                    HStack(spacing: 20) {
                        still
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.title)
                                .font(.sumiHeading(size: 20, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundColor(isInfoHovered ? SumiTheme.indigo : SumiTheme.foreground)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            metaLine
                                .padding(.top, 8)
                            if entry.totalCount > 0 {
                                let pct = min(max(CGFloat(entry.progressPercent / 100.0), 0), 1)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(SumiTheme.foreground.opacity(0.12))
                                    Capsule()
                                        .fill(SumiTheme.indigo)
                                        .scaleEffect(x: pct, y: 1, anchor: .leading)
                                        .animation(.smooth, value: pct)
                                }
                                .frame(maxWidth: 360)
                                .frame(height: 3)
                                .padding(.top, 12)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, 20)
                    .padding(.vertical, 20)
                    .frame(minHeight: Self.height)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .stableHover { isInfoHovered = $0 }
                .accessibilityLabel("Open \(entry.title)")

                Button(action: action) {
                    Text("\(actionLabel) →")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(isActionHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .underline(isActionHovered, color: SumiTheme.indigo.opacity(0.6))
                        .padding(.leading, 28)
                        .padding(.trailing, 20)
                        .frame(minHeight: Self.height)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .stableHover { isActionHovered = $0 }
            }
            .background(backdrop)
            .background(SumiTheme.card)
            // Its own corners since the queue lost its bordered box: the
            // banner otherwise ends in square corners on the page ground.
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
            .animation(.snappy, value: isInfoHovered)
            .animation(.snappy, value: isActionHovered)
            #if os(macOS)
            .contextMenu {
                if !entry.isAwaitingEpisode {
                    Button(actionLabel, action: onPlay)
                }
                Button("Open", action: onSelect)
            }
            #endif
        }

        /// The banner, or the cover when the title has no snapshot yet,
        /// drawn `.fill` behind the row and faded to the card ground from
        /// the left so the text never sits on picture. Nothing is blurred:
        /// a blurred banner read as a low-quality one on the detail page.
        private var backdrop: some View {
            let mask = LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.10), location: 0.38),
                    .init(color: .black.opacity(0.42), location: 0.70),
                    .init(color: .black.opacity(0.55), location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            return Color.clear
                .overlay {
                    CachedAsyncImage(url: entry.bannerURL ?? entry.thumbnailURL, maxPixelSize: 1600) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.clear
                    }
                }
                .clipped()
                .mask(mask)
                .allowsHitTesting(false)
        }

        private var still: some View {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(SumiTheme.background)
                CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 320) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                        .frame(width: 160, height: 92)
                        .clipped()
                } placeholder: {
                    SumiTheme.card
                }
            }
            .frame(width: 160, height: 92)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
            .ifLet(morphSource) { view, source in
                view.matchedGeometryEffect(id: source.key, in: source.namespace)
            }
        }

        private var metaLine: some View {
            HStack(spacing: 14) {
                Text(entry.countLabel)
                    .sumiTabularMono(size: 12)
                    .foregroundColor(SumiTheme.muted)
                if entry.isRewatch == true {
                    Text("Rewatch")
                        .sumiTabularMono(size: 12, weight: .semibold)
                        .foregroundColor(SumiTheme.indigo)
                }
                if let airingAt = entry.nextAiringAt, entry.isAwaitingEpisode {
                    Text("Airs \(AppModel.countdown(to: Date(timeIntervalSince1970: TimeInterval(airingAt))))")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                } else if entry.hasNewEpisode || entry.nextAiringAt != nil {
                    Text(entry.unit == "CH" ? "New chapter out" : "New episode out")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SumiTheme.indigo)
                } else if let watched = entry.watchedTimeAgo {
                    Text("Watched \(watched)")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }
            }
        }
    }

    private struct RowView: View {
        let entry: QueueEntry
        let namespace: Namespace.ID?
        /// Non-nil on exactly the row whose Play was just pressed.
        let morphSource: EpisodeMorphSource?
        let onSelect: () -> Void
        let onPlay: () -> Void

        @State private var isHovered = false

        /// The episode the Play button plays, in the middle of the row that
        /// otherwise stood empty between the progress bar and the button.
        /// Drawn only when the title's detail snapshot has it.
        @ViewBuilder
        private var nextEpisode: some View {
            if entry.nextEpisodeStillURL != nil || entry.nextEpisodeTitle != nil {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: entry.nextEpisodeStillURL, maxPixelSize: 192) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(SumiTheme.card)
                    }
                    .frame(width: 96, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusSm).stroke(SumiTheme.border, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 3) {
                        Text("Next · Ep \(entry.nextEpisodeOrChapter)")
                            .sumiTabularMono(size: 11, weight: .semibold)
                            .foregroundColor(SumiTheme.muted)
                        // One line, truncated: at 180pt and two lines,
                        // "Triangle... of Missed Encounters" broke after its
                        // second word.
                        Text(entry.nextEpisodeTitle ?? entry.countLabel)
                            .font(.system(size: 12.5))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(width: 240, alignment: .leading)
                }
            }
        }

        var body: some View {
            HStack(spacing: 16) {
                // Clickable Body: Thumbnail + Text
                Button(action: onSelect) {
                    HStack(spacing: 16) {
                        CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 208) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 104, height: 60)
                                .clipped()
                        } placeholder: {
                            SumiTheme.card
                        }
                        .frame(width: 104, height: 60)
                        // Progress on the still's bottom edge, as on the
                        // detail page's episode stills. A full-width bar under
                        // the text sat right above the row's divider, and the
                        // row read as double-ruled.
                        .overlay(alignment: .bottom) {
                            if entry.totalCount > 0 {
                                let pct = min(max(CGFloat(entry.progressPercent / 100.0), 0), 1)
                                ZStack(alignment: .leading) {
                                    Rectangle().fill(Color.black.opacity(0.45))
                                    Rectangle()
                                        .fill(SumiTheme.indigo)
                                        .scaleEffect(x: pct, y: 1, anchor: .leading)
                                }
                                .frame(height: 3)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .ifLet(namespace) { view, namespace in
                            view.matchedGeometryEffect(id: entry.id, in: namespace)
                        }
                        .ifLet(morphSource) { view, source in
                            view.matchedGeometryEffect(id: source.key, in: source.namespace)
                        }

                        // Info Column
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.title)
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)

                            // The count is a figure and keeps the mono face;
                            // the rest is a sentence and does not. One
                            // modifier on the enclosing stack gave both the
                            // same treatment, so "New episode out" arrived as
                            // wide-tracked monospace capitals.
                            HStack(spacing: 16) {
                                Text(entry.countLabel)
                                    .sumiTabularMono(size: 11.5)
                                    .foregroundColor(SumiTheme.muted)

                                if entry.isRewatch == true {
                                    Text("Rewatch")
                                        .sumiTabularMono(size: 11.5, weight: .semibold)
                                        .foregroundColor(SumiTheme.indigo)
                                }

                                if let airingAt = entry.nextAiringAt, entry.isAwaitingEpisode {
                                    Text("Airs \(AppModel.countdown(to: Date(timeIntervalSince1970: TimeInterval(airingAt))))")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(SumiTheme.muted)
                                } else if entry.hasNewEpisode || entry.nextAiringAt != nil {
                                    Text(entry.unit == "CH" ? "New chapter out" : "New episode out")
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundColor(SumiTheme.indigo)
                                } else if let watched = entry.watchedTimeAgo {
                                    Text("Watched \(watched)")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(SumiTheme.muted)
                                }
                            }
                            .padding(.top, 6)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)

                        nextEpisode
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .contentShape(Rectangle())

                // "Details" stays: it says the episode has not aired, which is
                // news. Play and Read only on hover, and hidden rather than
                // removed so the middle block does not shift when it appears.
                let showsAction = isHovered || entry.isAwaitingEpisode
                Button(action: onPlay) {
                    Text(entry.isAwaitingEpisode ? "Details" : entry.unit == "CH" ? "Read" : "Play")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(SumiTheme.indigo)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .opacity(showsAction ? 1 : 0)
                .allowsHitTesting(showsAction)
            }
            .padding(.vertical, 12)
            // The Spotlight's own inset, so the thumbnails line up under its
            // poster and the banner reads as the first row, drawn larger.
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
            .stableHover { hovering in
                isHovered = hovering
            }
        }
    }
}
