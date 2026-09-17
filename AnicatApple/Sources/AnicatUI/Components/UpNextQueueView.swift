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
                    isFirst: false,
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
        // No fill on the container: only the first row carries `bg-surface`.
        // Filling the whole card flattened the queue's one piece of hierarchy
        // — the primary row stopped standing out from the rest.
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    /// The queue's first row as a wide card: the banner behind, the still,
    /// the title at heading size, the meta line, the progress capsule and
    /// the Resume pill. Same callbacks and the same still-to-video morph as
    /// a plain row, so playing from it looks like playing from any row.
    private struct SpotlightRow: View {
        let entry: QueueEntry
        let morphSource: EpisodeMorphSource?
        let onSelect: () -> Void
        let onPlay: () -> Void

        @State private var isHovered = false
        @State private var isPlayHovered = false
        @State private var ripplePressLocation: CGPoint = .zero
        @State private var ripplePressCount = 0

        private static let height: CGFloat = 176

        var body: some View {
            HStack(spacing: 20) {
                Button(action: onSelect) {
                    HStack(spacing: 20) {
                        still
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.title)
                                .font(.sumiHeading(size: 20, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            metaLine
                                .padding(.top, 8)
                            if entry.totalCount > 0 {
                                let pct = min(max(CGFloat(entry.progressPercent / 100.0), 0), 1)
                                ZStack(alignment: .leading) {
                                    Capsule().fill(SumiTheme.foreground.opacity(0.12))
                                    AnimatedProgressCapsule(pct: pct)
                                }
                                .frame(maxWidth: 360)
                                .frame(height: 3)
                                .padding(.top, 12)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)

                playButton
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .frame(minHeight: Self.height)
            .background(backdrop)
            .background(SumiTheme.card)
            .stableHover { isHovered = $0 }
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
                            .scaleEffect(isHovered ? 1.03 : 1)
                            .animation(.smooth(duration: 0.6), value: isHovered)
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
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundColor(SumiTheme.muted)
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
                Text("\(entry.unit) \(entry.nextEpisodeOrChapter)\(entry.totalCount > 0 ? " / \(entry.totalCount)" : "")")
                    .sumiTabularMono(size: 12)
                    .foregroundColor(SumiTheme.muted)
                if entry.isRewatch == true {
                    Text("Rewatch")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(SumiTheme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
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

        private var playButton: some View {
            Button(action: onPlay) {
                HStack(spacing: 7) {
                    Image(systemName: entry.isAwaitingEpisode ? "info.circle" : (entry.unit == "CH" ? "book.fill" : "play.fill"))
                        .font(.system(size: 11, weight: .semibold))
                    Text(entry.isAwaitingEpisode ? "Details" : (entry.unit == "CH" ? "Continue" : "Resume"))
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(SumiTheme.background)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(isPlayHovered ? SumiTheme.indigo.opacity(0.85) : SumiTheme.indigo)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .contentShape(Rectangle())
                .rippleOnPress(at: ripplePressLocation, trigger: ripplePressCount)
            }
            .buttonStyle(.sumiPressable)
            .sumiSpatialTap { location in
            ripplePressLocation = location
            ripplePressCount += 1
        }
            .animation(.snappy, value: isPlayHovered)
            .stableHover { isPlayHovered = $0 }
        }
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
        /// Where the Play/Resume press landed and a counter that bumps on
        /// each one — read by `rippleOnPress` below. Local to the button's
        /// own bounds, not the row's: the button is small and off to the
        /// side, and a location captured from the row would put the ripple
        /// wherever the row itself was tapped, not where Play was.
        @State private var ripplePressLocation: CGPoint = .zero
        @State private var ripplePressCount = 0

        var body: some View {
            HStack(spacing: 16) {
                // Clickable Body: Thumbnail + Text
                Button(action: onSelect) {
                    HStack(spacing: 16) {
                        // 104x60 Thumbnail
                        ZStack {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(SumiTheme.card)
                                .frame(width: 104, height: 60)

                            CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 208) { image in
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .frame(width: 104, height: 60)
                                    .clipped()
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
                        .frame(width: 104, height: 60)
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

                                if entry.isRewatch == true {
                                    Text("Rewatch")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundColor(SumiTheme.muted)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
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

                            // 2px Progress Bar
                            if entry.totalCount > 0 {
                                let pct = min(max(CGFloat(entry.progressPercent / 100.0), 0), 1)
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(SumiTheme.foreground.opacity(0.1))
                                    AnimatedProgressCapsule(pct: pct)
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
                    Text(entry.isAwaitingEpisode ? "Details" : isFirst ? (entry.unit == "CH" ? "Continue" : "Resume") : (entry.unit == "CH" ? "Read" : "Play"))
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
                        .rippleOnPress(at: ripplePressLocation, trigger: ripplePressCount)
                }
                .buttonStyle(.sumiPressable)
                .contentShape(Rectangle())
                .sumiSpatialTap { location in
            ripplePressLocation = location
            ripplePressCount += 1
        }
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

/// Same overshoot-then-settle treatment as `MediaCard`'s poster tick, on the
/// row's own capsule shape. Two separate structs rather than one shared
/// shape-agnostic helper: `Rectangle` and `Capsule` both conform to `Shape`
/// but the fill views around them differ enough (this one has no dark
/// track drawn by the same call) that a generic wrapper bought no real
/// sharing, just an extra type parameter at both call sites.
///
/// `keyframeAnimator(initialValue:trigger:)` restarts from the literal
/// `initialValue` argument on every retrigger rather than from wherever the
/// interpolation currently sits, so `initialValue: pct` — already the *new*
/// value by the time a retrigger fires — snapped the capsule straight to
/// its target and only overshot from there. `settledPct` is held back until
/// the animation chasing the old target has actually finished so the next
/// restart still has a true old value to animate from; see the longer
/// version of this note on `MediaCard.AnimatedProgressFill`.
private struct AnimatedProgressCapsule: View {
    let pct: CGFloat

    @State private var settledPct: CGFloat = 0
    @State private var trigger = 0
    /// Only an increase gets the overshoot; a decrease still bumps
    /// `trigger` so the capsule visually reaches the lower `pct`, just
    /// along a plain settle with nothing to overshoot past.
    @State private var isIncrease = true

    var body: some View {
        Group {
            if MotionPolicy.reduce {
                Capsule()
                    .fill(SumiTheme.indigo)
                    .scaleEffect(x: pct, y: 1, anchor: .leading)
                    .animation(.sumi(.pop), value: pct)
            } else {
                Capsule()
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
            // Matches the keyframe track's own total duration above.
            let settleDelay = isIncrease ? 0.6 : 0.25
            DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) {
                settledPct = newValue
            }
        }
    }
}
