import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

/// The `.upNext` section: the Continue tile with New for you beside it, the
/// Continue shelf, the week strip, and every configurable discover row.
/// Pulled out of `RootView.sectionContent` because it used to be a computed
/// property inlined into the 1198-line body — any one shelf's array changing
/// (a Watching progress tick from playback, a background refreshAll updating
/// Trending) re-evaluated every other shelf's layout along with it. Own `@State` for the two sheets it owns, since neither is
/// read outside this section.
struct HomeSectionView: View {
    @Bindable var model: AppModel
    let namespace: Namespace.ID
    /// The episode-still-to-video namespace, for the Continue tile's Play.
    let playerNamespace: Namespace.ID
    // 5th arg is the shelf-scoped source key for the poster morph (e.g.
    // "watching:12345"), nil where there's no card to morph from.
    let onOpenDetail: (Int64, String, URL?, Bool, String?) -> Void

    @State private var showHomeCustomize = false
    @State private var showPicker = false
    /// Where each anime title stands inside its next episode, read off the
    /// main actor. Nil until the first read lands; New for you waits for it,
    /// or every title with an episode out drew there for a frame and then
    /// jumped into the Continue shelf.
    @State private var resume: [Int64: UpNextResume]?

    /// Beside the tile and its text, New for you needs about 1000pt; under
    /// that (the 1080pt window minimum, less the rail and the page margins)
    /// it goes below them instead of crushing the title to one word a line.
    private static let wideLayoutWidth: CGFloat = 1000
    /// Three 63pt rows and the heading fit the 262pt tile; the rest of the
    /// news stays in the Continue shelf rather than being dropped.
    private static let newForYouLimit = 3

    /// Anime from the watching list first (it is in recency order and the
    /// tile reads `first`), then manga and novels already started. Reading
    /// titles carry no recency, so they cannot be interleaved honestly.
    private var inProgress: [UpNextQueueView.QueueEntry] {
        let reading = (model.mangaReading + model.novelReading).compactMap { item -> UpNextQueueView.QueueEntry? in
            // A "reading" entry at chapter 0 was never begun; offering to
            // continue it is the queue's job only once it has.
            guard let progress = item.progress, progress > 0 else { return nil }
            let total = item.totalEpisodesOrChapters ?? 0
            return UpNextQueueView.QueueEntry(
                id: item.id,
                title: item.title,
                thumbnailURL: item.coverImageURL,
                nextEpisodeOrChapter: progress + 1,
                totalCount: total,
                progressPercent: total > 0 ? Double(progress) / Double(total) * 100 : 0,
                unit: "CH"
            )
        }
        return model.upNextItems + reading
    }

    /// The phone's rule: a started episode is something to resume, an
    /// unstarted one that has aired is news. One place per title. Airing
    /// shows only: `hasNewEpisode` is "progress below released", which is
    /// true of every half-watched show that ended years ago.
    private func isNews(_ entry: UpNextQueueView.QueueEntry, airing: Set<Int64>) -> Bool {
        guard let resume, entry.unit == "EP", airing.contains(entry.id) else { return false }
        return entry.hasNewEpisode && !entry.isAwaitingEpisode && resume[entry.id]?.secondsLeft == nil
    }

    var body: some View {
        // Measured out here, not inside: a reader within the scroll view
        // reports the content's width, which is the thing being sized.
        GeometryReader { viewport in
        let contentWidth = SumiContentWidth.forAvailable(viewport.size.width) - 80
        let wide = contentWidth >= Self.wideLayoutWidth
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 40) {
                SumiPageHeader(title: "Up next") {
                    // Words, like the detail page's secondary actions: two
                    // boxed buttons were the last boxes left on the home
                    // screen once the queue lost its frame.
                    HStack(spacing: 14) {
                        headerAction("Pick for me") { showPicker = true }
                        Rectangle().fill(SumiTheme.border).frame(width: 1, height: 14)
                        // Reorders/hides the configurable rows below. Shown
                        // even signed-out: Trending, Newly releasing and
                        // Seasonal all work without a token, only Planning
                        // needs one.
                        headerAction("Customize") { showHomeCustomize = true }
                    }
                }

                let all = inProgress
                if let hero = all.first {
                    let rest = Array(all.dropFirst())
                    let airing = Set(model.watchingItems.lazy.filter(\.isAiring).map(\.id))
                    let news = Array(rest.filter { isNews($0, airing: airing) }.prefix(Self.newForYouLimit))
                    let newsIds = Set(news.map(\.id))
                    let shelf = rest.filter { !newsIds.contains($0.id) }

                    if wide {
                        HStack(alignment: .top, spacing: 24) {
                            tile(hero)
                            if !news.isEmpty {
                                newList(news).frame(width: 240)
                            }
                        }
                    } else {
                        tile(hero)
                        if !news.isEmpty {
                            newList(news)
                        }
                    }

                    if !shelf.isEmpty {
                        UpNextContinueShelf(entries: shelf, onSelect: select, onPlay: { play($0, picture: nil) })
                    }
                } else if model.isSignedIn && model.isLoading {
                    // Signed in only: signed out the list never arrives, and
                    // the placeholder would sit on the page for good.
                    UpNextSkeleton(wide: wide)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Nothing to continue yet")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                        Text(model.isSignedIn
                             ? "Start something below and it shows up here."
                             : "Start something below, or sign in to bring your AniList list over.")
                            .font(.system(size: 12.5))
                            .foregroundColor(SumiTheme.muted)
                    }
                }

                if model.isSignedIn, !model.pendingNextSeasons.isEmpty {
                    NextSeasonShelf(model: model, onOpenDetail: onOpenDetail)
                }

                if model.scheduleItems.contains(where: \.isWatching) {
                    WeekStrip(items: model.scheduleItems) { item in
                        onOpenDetail(item.id, item.title, item.coverImageURL, false, nil)
                    }
                }

                // Configurable rows, in the user's saved order; hidden ones
                // are skipped entirely rather than shown collapsed.
                ForEach(model.homeRowConfig.filter(\.visible)) { row in
                    homeDiscoverRow(id: row.id, title: row.title)
                }
            }
            // Capped so the shelves do not stretch across a whole 1512 pt
            // fullscreen, and centred: left-aligned under a 1100 cap the
            // right third of a fullscreen window was empty ("blank space on
            // the right side").
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollLagProbe("home")
        .sumiGround()
        .sheet(isPresented: $showHomeCustomize) {
            HomeCustomizeSheet(model: model, isPresented: $showHomeCustomize)
        }
        .sheet(isPresented: $showPicker) {
            PickerSheet(
                model: model,
                isPresented: $showPicker,
                onCommit: { item in
                    // No source card behind a modal sheet once it's
                    // dismissed, so no sourceKey — plain fade like any
                    // other non-card open.
                    onOpenDetail(item.id, item.title, item.coverImageURL, item.isManga, nil)
                }
            )
        }
        }
        // Keyed on the episode, and on what is playing: finishing one moves
        // the title to the next episode, and closing the player has to drop
        // the "Resume at" the tile showed before it opened.
        .task(id: "\(model.upNextItems.map { "\($0.id):\($0.nextEpisodeOrChapter)" })|\(model.currentPlaybackCatalogId ?? 0):\(model.currentPlaybackEpisode ?? 0)") {
            let entries = model.upNextItems.filter { $0.unit == "EP" }
            let engine = model.engine
            resume = await Task.detached(priority: .utility) {
                Self.lookUp(entries, engine: engine)
            }.value
        }
    }

    private func tile(_ entry: UpNextQueueView.QueueEntry) -> some View {
        UpNextContinueTile(
            entry: entry,
            resume: resume?[entry.id],
            playerNamespace: playerNamespace,
            playerSourceKey: model.openingPlayerSourceKey,
            onSelect: select,
            onPlay: { play($0, picture: $1) }
        )
    }

    private func newList(_ entries: [UpNextQueueView.QueueEntry]) -> some View {
        UpNextNewList(entries: entries, resume: resume ?? [:], onSelect: select)
    }

    private func select(_ entry: UpNextQueueView.QueueEntry) {
        onOpenDetail(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH", nil)
    }

    /// Chapters open the page: there is no one-press read from home. `picture`
    /// is the tile's still, nil from the shelf, whose portrait poster would
    /// squash flying into the landscape video frame.
    private func play(_ entry: UpNextQueueView.QueueEntry, picture: URL?) {
        if entry.unit == "CH" {
            onOpenDetail(entry.id, entry.title, entry.thumbnailURL, true, nil)
        } else {
            playFromShelf(
                model: model,
                catalogId: entry.id,
                episode: entry.nextEpisodeOrChapter,
                title: entry.title,
                coverURL: entry.thumbnailURL,
                morphThumbnailURL: picture
            )
        }
    }

    /// The still, the episode title and the position for each title's next
    /// episode: the first two from the detail snapshot, the last from the
    /// watch registry. Disk reads and a synchronous FFI call per title, which
    /// is why this runs detached and never from `body`. Same reads as the
    /// phone's Up Next tab.
    nonisolated private static func lookUp(_ entries: [UpNextQueueView.QueueEntry], engine: AnicatEngine?) -> [Int64: UpNextResume] {
        var found: [Int64: UpNextResume] = [:]
        for entry in entries {
            let episode = DetailCache.peekEpisode(id: entry.id, number: entry.nextEpisodeOrChapter)
            var stop: Int?
            var duration: Int?
            if let progress = try? engine?.getProgress(catalog: .anilist, catalogId: entry.id, episodeNumber: Int64(entry.nextEpisodeOrChapter)),
               progress.stopTime > 0, progress.duration > 0,
               // Past 85% the episode is recorded watched and replays from
               // the start (`resolveAndPlay`), so there is nothing to resume.
               Double(progress.stopTime) / Double(progress.duration) < 0.85 {
                stop = Int(progress.stopTime)
                duration = Int(progress.duration)
            }
            found[entry.id] = UpNextResume(
                still: episode?.thumbnailURL,
                episodeTitle: episode?.title,
                stopSeconds: stop,
                durationSeconds: duration
            )
        }
        return found
    }

    private func headerAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    /// One configurable row, by id. Skeletons preserve the shelf layout
    /// while queries are in flight, preventing sudden reflows. `id` doubles
    /// as the row's shelf key: distinct rows can show the same title at
    /// once (Watching and Trending, say), so the poster-morph source has to
    /// be scoped per-row, not just per-id — see `AppModel.openingDetailSourceKey`.
    @ViewBuilder
    private func homeDiscoverRow(id: String, title: String) -> some View {
        switch id {
        case "becauseYouWatched":
            // No skeleton: signed out the engine answers with an empty list
            // rather than an error, so a placeholder here would sit on the
            // page forever for anyone without a token.
            HomeShelf(model: model, title: title, shelfKey: "because", items: \.becauseYouWatched,
                      skeleton: .never, namespace: namespace, onOpenDetail: onOpenDetail)
        case "planning":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.planningItems,
                      requiresSignIn: true, namespace: namespace, onOpenDetail: onOpenDetail)
        case "smartPlaylist":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.smartPicks,
                      requiresSignIn: true, namespace: namespace, onOpenDetail: onOpenDetail)
        case "trending":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.trendingItems,
                      namespace: namespace, onOpenDetail: onOpenDetail)
        case "newlyReleasing":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.newlyReleasingItems,
                      namespace: namespace, onOpenDetail: onOpenDetail)
        case "seasonal":
            HomeShelf(model: model, title: title, shelfKey: id, items: \.seasonalItems,
                      namespace: namespace, onOpenDetail: onOpenDetail)
        default:
            EmptyView()
        }
    }
}

/// One shelf, reading its own array off the model so a shelf landing
/// invalidates this row alone. Inlined in `HomeSectionView.body`, every
/// shelf array (and `openingDetailSourceKey`) was a dependency of that one
/// body, so each of `loadHome`'s staggered fetches re-ran it and every
/// `ForEach` rebuilt every `MediaCard` (about 120 `CachedAsyncImage.init`s,
/// each a lock and an NSCache lookup) before `.equatable()` could skip one.
struct HomeShelf: View {
    enum Skeleton { case never, whenLoading, whenSignedInAndLoading }

    let model: AppModel
    let title: String
    let shelfKey: String
    let items: KeyPath<AppModel, [MediaCard.Item]>
    var skeleton: Skeleton = .whenLoading
    var requiresSignIn = false
    let namespace: Namespace.ID
    let onOpenDetail: (Int64, String, URL?, Bool, String?) -> Void

    private var showsSkeleton: Bool {
        switch skeleton {
        case .never: false
        case .whenLoading: model.isLoading
        case .whenSignedInAndLoading: model.isSignedIn && model.isLoading
        }
    }

    var body: some View {
        if requiresSignIn && !model.isSignedIn {
            EmptyView()
        } else {
            let items = model[keyPath: items]
            if !items.isEmpty {
                shelf(items: items)
            } else if showsSkeleton {
                MediaRowSkeleton(title: title)
            }
        }
    }

    private func card(_ item: MediaCard.Item, key: String) -> some View {
        MediaCard(
            item: item,
            namespace: model.openingDetailSourceKey == "\(key):\(item.id)" ? namespace : nil,
            onPrefetch: {
                model.prefetchDetail(id: item.id, isManga: item.isManga)
            }
        ) {
            onOpenDetail(item.id, item.title, item.coverImageURL, item.isManga, "\(key):\(item.id)")
        }
        .equatable()
        .frame(width: 180)
    }

    private func shelf(items: [MediaCard.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SumiSectionHeader(title, trailing: "\(items.count) show\(items.count == 1 ? "" : "s")")

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        card(item, key: shelfKey)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// Sequels of seasons the viewer finished and has not started, filed by
/// `AppModel.prepareNextSeasonOffer` when the last episode crossed 85%. The
/// player's end card is the first chance to take one; this is for the viewer
/// who closed the player first.
struct NextSeasonShelf: View {
    let model: AppModel
    let onOpenDetail: (Int64, String, URL?, Bool, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SumiSectionHeader("Next season")
            VStack(alignment: .leading, spacing: 14) {
                ForEach(model.pendingNextSeasons) { offer in
                    row(offer)
                }
            }
        }
    }

    private func row(_ offer: NextSeasonOffer) -> some View {
        let cover = URL(string: offer.coverImage)
        return HStack(alignment: .center, spacing: 14) {
            Button {
                onOpenDetail(offer.sequelId, offer.title, cover, false, nil)
            } label: {
                CachedAsyncImage(url: cover, maxPixelSize: 240) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.card)
                }
                .frame(width: 54, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.sumiPressable)

            VStack(alignment: .leading, spacing: 4) {
                Text(offer.title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(2)
                Text("After \(offer.sourceTitle)")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                    .lineLimit(1)
                HStack(spacing: 14) {
                    Button(offer.isReleased ? "Add to watching" : "Add to planning") {
                        Task { await model.addNextSeasonToList(offer) }
                    }
                    .foregroundColor(SumiTheme.indigo)
                    Button("Dismiss") { model.dismissNextSeason(offer) }
                        .foregroundColor(SumiTheme.muted)
                }
                .font(.system(size: 13, weight: .medium))
                .buttonStyle(.sumiPressable)
                .padding(.top, 2)
            }
        }
    }
}
