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

        public init(
            id: Int64,
            title: String,
            thumbnailURL: URL?,
            nextEpisodeOrChapter: Int,
            totalCount: Int = 0,
            progressPercent: Double = 0,
            watchedTimeAgo: String? = nil,
            hasNewEpisode: Bool = false,
            unit: String = "EP"
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
        }
    }

    public let items: [QueueEntry]
    public let namespace: Namespace.ID?
    /// Which row (if any) is the poster-morph source, as "upnext:<id>".
    /// Nil for a caller that does not morph -- the Reading and Cinema
    /// queues, whose detail pages are not wired to this namespace. Setting
    /// it for one of those would tell the rest of the app a morph is
    /// running when nothing has a second half to interpolate towards, and
    /// everything gated on that (the page's own scale, the feed push-back)
    /// would switch itself off for an open with no morph in it.
    public let openingSourceKey: String?
    /// The second namespace, for the thumbnail-to-video morph a Play press
    /// starts. Distinct from `namespace` above because the two morphs have
    /// different destinations and different lifetimes — see
    /// `AppModel.openingPlayerSourceKey`.
    public let playerNamespace: Namespace.ID?
    /// Which row that morph starts from, as "upnext:<id>:<episode>".
    public let playerSourceKey: String?
    public let onSelect: (QueueEntry) -> Void
    public let onPlay: (QueueEntry) -> Void

    /// The one place the Up Next form of the key is spelled — the play call
    /// site sets it and the row below compares against it.
    public nonisolated static func playerMorphKey(catalogId: Int64, episode: Int) -> String {
        "upnext:\(catalogId):\(episode)"
    }

    /// The poster morph's key. Deliberately not the bare id: the same show
    /// sits in this queue and in the Watching shelf at once, and two live
    /// `matchedGeometryEffect` sources for one id in one namespace is the
    /// undefined case documented on `AppModel.openingDetailSourceKey`.
    public nonisolated static func detailMorphKey(catalogId: Int64) -> String {
        "upnext:\(catalogId)"
    }

    public init(
        items: [QueueEntry],
        namespace: Namespace.ID? = nil,
        openingSourceKey: String? = nil,
        playerNamespace: Namespace.ID? = nil,
        playerSourceKey: String? = nil,
        onSelect: @escaping (QueueEntry) -> Void,
        onPlay: @escaping (QueueEntry) -> Void
    ) {
        self.items = items
        self.namespace = namespace
        self.openingSourceKey = openingSourceKey
        self.playerNamespace = playerNamespace
        self.playerSourceKey = playerSourceKey
        self.onSelect = onSelect
        self.onPlay = onPlay
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
                RowView(
                    entry: entry,
                    isFirst: index == 0,
                    // The thumbnail is a 104x60 landscape window and the
                    // detail poster is a 192x288 portrait, but they are the
                    // same image: `thumbnailURL` is the show's `coverImage`,
                    // center-cropped by `aspectRatio(.fill)`. So growing the
                    // frame does not squash the art, it uncrops it -- the
                    // poster the row was only showing a slice of opens out
                    // into the whole thing. That only holds while the frame
                    // below is the single size declaration in the stack; a
                    // fixed frame on the image itself pins it at 104x60
                    // while its container grows, which is the squash this
                    // used to be avoiding.
                    namespace: openingSourceKey == Self.detailMorphKey(catalogId: entry.id)
                        ? namespace
                        : nil,
                    // The player morph has no such mismatch: this 104x60
                    // still is landscape and so is the video frame it grows
                    // into, so the linear frame interpolation that made the
                    // poster morph squash is exactly right here.
                    morphSource: morphSource(for: entry),
                    onSelect: { onSelect(entry) },
                    onPlay: { onPlay(entry) }
                )

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
        // No fill on the container: only the first row carries `bg-surface`.
        // Filling the whole card flattened the queue's one piece of hierarchy
        // — the primary row stopped standing out from the rest.
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private struct RowView: View {
        let entry: QueueEntry
        let isFirst: Bool
        let namespace: Namespace.ID?
        /// Non-nil on exactly the row whose Play was just pressed.
        let morphSource: EpisodeMorphSource?
        let onSelect: () -> Void
        let onPlay: () -> Void

        @State private var isHovered = false
        @State private var isPlayHovered = false

        var body: some View {
            HStack(spacing: 16) {
                // Clickable Body: Thumbnail + Text
                Button(action: onSelect) {
                    HStack(spacing: 16) {
                        // 104x60 window onto the show's cover. Shaped like
                        // `MediaDetailView.poster` on purpose -- one frame,
                        // on the outside, and nothing inside it that names a
                        // size -- because the poster morph animates that
                        // frame and the art has to follow it out.
                        Color.clear
                            .frame(width: 104, height: 60)
                            .overlay {
                                CachedAsyncImage(
                                    url: entry.thumbnailURL,
                                    // The detail poster's size, not this
                                    // row's: the morph hands this already
                                    // decoded bitmap over to a 192x288 view,
                                    // and at 208 it arrived soft and snapped
                                    // sharp when the detail's own decode
                                    // landed. Both views ask for the same URL
                                    // at the same size, so the open now takes
                                    // a cache hit it did not have before.
                                    maxPixelSize: 600
                                ) { image in
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle()
                                        .fill(SumiTheme.background)
                                        .overlay(
                                            Image(systemName: "photo")
                                                .font(.system(size: 16))
                                                .foregroundColor(SumiTheme.muted)
                                        )
                                }
                            }
                            .clipped()
                            // The destination's radius while this row is the
                            // one morphing. `matchedGeometryEffect` carries
                            // frame and nothing else, so a corner that
                            // disagrees with the poster's pops at the far
                            // end -- unnoticeable across a shelf card's
                            // travel, a third of the movement across this
                            // one's 65pt.
                            .clipShape(RoundedRectangle(
                                cornerRadius: namespace == nil ? 4 : SumiTheme.radiusXl
                            ))
                            .ifLet(namespace) { view, namespace in
                                view.matchedGeometryEffect(id: entry.id, in: namespace)
                            }
                            // The row goes empty for as long as it is the
                            // morph source. Both halves of the pair draw, so
                            // leaving this one up put a still copy of the
                            // thumbnail in the row while a second copy grew
                            // out of the same spot -- read as a poster
                            // arriving from above rather than this one
                            // leaving, which is the whole point of the morph.
                            // A shelf card gets away with it because the page
                            // has covered it by the time it has travelled far
                            // enough to notice; this row is 65pt away.
                            .opacity(namespace == nil ? 1 : 0)
                            .ifLet(morphSource) { view, source in
                                view.matchedGeometryEffect(id: source.key, in: source.namespace)
                            }

                        // Info Column
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.title)
                                .font(.system(size: isFirst ? 15 : 13.5, weight: isFirst ? .semibold : .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)

                            // The count is a figure and keeps the mono face;
                            // the rest is a sentence and does not. One
                            // modifier on the enclosing stack gave both the
                            // same treatment, so "New episode out" arrived as
                            // wide-tracked monospace capitals.
                            HStack(spacing: 16) {
                                Text("\(entry.unit) \(entry.nextEpisodeOrChapter)\(entry.totalCount > 0 ? " / \(entry.totalCount)" : "")")
                                    .sumiTabularMono(size: 11.5)
                                    .foregroundColor(SumiTheme.muted)

                                if entry.hasNewEpisode {
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

                            // 2px Progress Bar
                            if entry.totalCount > 0 {
                                let pct = min(max(CGFloat(entry.progressPercent / 100.0), 0), 1)
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(SumiTheme.foreground.opacity(0.1))
                                    Capsule()
                                        .fill(SumiTheme.indigo)
                                        .scaleEffect(x: pct, y: 1, anchor: .leading)
                                }
                                .frame(maxWidth: 420)
                                .frame(height: 2)
                                .padding(.top, 8)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .contentShape(Rectangle())

                // Dedicated Play / Resume Button
                Button(action: onPlay) {
                    Text(isFirst ? (entry.unit == "CH" ? "Continue" : "Resume") : (entry.unit == "CH" ? "Read" : "Play"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isFirst ? SumiTheme.background : (isPlayHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.7)))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isFirst ? (isPlayHovered ? SumiTheme.indigo.opacity(0.85) : SumiTheme.indigo) : (isPlayHovered ? SumiTheme.card : Color.clear))
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(isFirst ? Color.clear : (isPlayHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .contentShape(Rectangle())
                .animation(.snappy, value: isPlayHovered)
                .stableHover { isPlayHovered = $0 }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isFirst ? SumiTheme.card : (isHovered ? SumiTheme.card.opacity(0.6) : Color.clear))
            .animation(.snappy, value: isHovered)
            .stableHover { hovering in
                isHovered = hovering
            }
        }
    }
}
