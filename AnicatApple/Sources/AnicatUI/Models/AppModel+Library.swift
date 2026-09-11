// AppModel, catalog domain: home rows and their layout, the library,
// reading shelves, history, trending, search and discover, the launch
// refresh, and the small formatters the shelves share.

import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

extension AppModel {
    /// Reconciled with `defaultHomeRows`: keeps the saved order and
    /// visibility, drops a row id that no longer exists, and appends any
    /// newly-added default row at the end so a stale saved config never hides
    /// a row that didn't exist when it was written.
    static func loadHomeRowConfig() -> [HomeRowConfig] {
        guard let data = UserDefaults.standard.data(forKey: homeRowsDefaultsKey),
              let saved = try? JSONDecoder().decode([HomeRowConfig].self, from: data) else {
            return defaultHomeRows
        }
        let byId = Dictionary(uniqueKeysWithValues: defaultHomeRows.map { ($0.id, $0) })
        var merged = saved.compactMap { row -> HomeRowConfig? in
            guard let def = byId[row.id] else { return nil }
            return HomeRowConfig(id: def.id, title: def.title, visible: row.visible)
        }
        let seen = Set(merged.map(\.id))
        for def in defaultHomeRows where !seen.contains(def.id) {
            merged.append(def)
        }
        return merged
    }

    func persistHomeRowConfig() {
        guard let data = try? JSONEncoder().encode(homeRowConfig) else { return }
        UserDefaults.standard.set(data, forKey: Self.homeRowsDefaultsKey)
    }

    public func toggleHomeRow(id: String) {
        guard let index = homeRowConfig.firstIndex(where: { $0.id == id }) else { return }
        homeRowConfig[index].visible.toggle()
        persistHomeRowConfig()
    }

    public func moveHomeRow(at index: Int, by delta: Int) {
        let target = index + delta
        guard homeRowConfig.indices.contains(index), homeRowConfig.indices.contains(target) else { return }
        homeRowConfig.swapAt(index, target)
        persistHomeRowConfig()
    }

    func syncKnownTitles() {
        // Always on the main thread. Every shelf setter's `didSet` calls
        // this, and a setter reached after an `await` in a nonisolated
        // async method runs on the cooperative pool; the dictionaries were
        // then replaced on one thread while the Stats view read them on
        // another, and the test copy crashed in `knownTitles.setter`
        // releasing the old storage (crash report 2026-09-07 19:27).
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.syncKnownTitles() }
            return
        }
        var titles = resolvedTitles
        var covers = resolvedCovers
        for item in watchingItems + trendingItems + libraryItems + mangaReading + novelReading + mangaPlanning + novelPlanning + searchResults {
            titles[item.id] = item.title
            if let cover = item.coverImageURL { covers[item.id] = cover }
        }
        knownTitles = titles
        knownCovers = covers
    }

    func applyHomeCache(_ snapshot: HomeCache.Snapshot) {
        trendingItems = snapshot.trending
        watchingItems = snapshot.watching
        upNextItems = snapshot.upNext
        // Cinema paints from the same snapshot the anime home does; without
        // it, switching to cinema after a relaunch was eight empty shelves
        // until TMDB answered.
        cinemaShelves = snapshot.cinemaShelves ?? []
        cinemaUpNext = snapshot.cinemaUpNext ?? []
        // `airingTimeText`/`countdownText`/`dayGroup` are rendered strings
        // computed relative to "now" at fetch time — stale the moment the
        // cache is more than a few minutes old — so they're rebuilt from the
        // stored `airingAt` rather than replayed verbatim.
        let formatter = SumiTheme.timeFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMMM d"
        scheduleItems = snapshot.schedule.map { item in
            let date = Date(timeIntervalSince1970: TimeInterval(item.airingAt))
            return ScheduleView.ScheduleItem(
                id: item.id,
                title: item.title,
                coverImageURL: item.coverImageURL,
                episodeNumber: item.episodeNumber,
                airingTimeText: formatter.string(from: date),
                countdownText: Self.countdown(to: date),
                dayGroup: dayFormatter.string(from: date),
                airingAt: item.airingAt,
                isWatching: item.isWatching
            )
        }
        libraryItems = snapshot.library
        mangaTrending = snapshot.mangaTrending
        novelTrending = snapshot.novelTrending
        mangaReading = snapshot.mangaReading
        novelReading = snapshot.novelReading
        planningItems = snapshot.planning
        smartPicks = snapshot.smartPicks
        newlyReleasingItems = snapshot.newlyReleasing
        seasonalItems = snapshot.seasonal
        becauseYouWatched = snapshot.becauseYouWatched ?? []
    }

    /// Empties the local watch log, and only that.
    ///
    /// Not `clearLocalRegistry`: that also drops resume positions, remembered
    /// releases and track picks. The History page has drawn a "Clear history"
    /// button behind an optional callback since it was written, and nothing
    /// ever passed one, so the button never appeared.
    public func clearWatchHistory() async {
        guard let engine else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engineIOQueue.async {
                try? engine.clearWatchHistory()
                continuation.resume()
            }
        }
        activity = []
        cinemaActivity = []
        loadWatchStats()
    }

    /// Forgets one watch, for the History row's context menu.
    public func removeWatch(_ row: ActivityRow) async {
        guard let engine else { return }
        let catalog = row.catalog
        let id = row.catalogId
        let episode = row.episodeNumber
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            engineIOQueue.async {
                try? engine.removeWatch(catalog: catalog, catalogId: id, episodeNumber: episode)
                continuation.resume()
            }
        }
        let gone: (ActivityRow) -> Bool = {
            $0.catalog == catalog && $0.catalogId == id && $0.episodeNumber == episode
        }
        activity.removeAll(where: gone)
        cinemaActivity.removeAll(where: gone)
        loadWatchStats()
    }

    func persistHomeCache() {
        // Fixture shelves must not become the snapshot the real app paints
        // from at its next launch; the caches directory is shared.
        guard !ScreenshotFixtures.isEnabled else { return }
        HomeCache.save(HomeCache.Snapshot(
            trending: trendingItems,
            watching: watchingItems,
            upNext: upNextItems,
            schedule: scheduleItems,
            library: libraryItems,
            mangaTrending: mangaTrending,
            novelTrending: novelTrending,
            mangaReading: mangaReading,
            novelReading: novelReading,
            planning: planningItems,
            smartPicks: smartPicks,
            newlyReleasing: newlyReleasingItems,
            seasonal: seasonalItems,
            becauseYouWatched: becauseYouWatched,
            cinemaShelves: cinemaShelves,
            cinemaUpNext: cinemaUpNext
        ))
    }

    /// Everything the signed-in views draw from, in one pass.
    /// `showLoading` is false for the launch call when `HomeCache` already
    /// painted the screen — this refresh is then a silent replace, same
    /// spirit as `DetailCache`'s render-then-refresh, and forcing the scrim
    /// on regardless would defeat the point of having shown cached data at
    /// all.
    public func refreshAll(showLoading: Bool = true) async {
        if showLoading { isLoading = true }
        defer { if showLoading { isLoading = false } }
        // These four write disjoint properties (catalog: trending/viewer/
        // watching/schedule; library: libraryItems; shelves: manga*/novel*;
        // activity: watch log only) so firing them concurrently has no
        // write race — unlike calling `loadInitialCatalog` and `loadHistory`
        // themselves concurrently, which would both race to set
        // `viewer`/`isSignedIn`. `loadHomeDiscoverRows` runs after because it
        // reads `trendingItems`, which only `loadInitialCatalog` fills.
        async let catalog: Void = loadInitialCatalog()
        async let library: Void = fetchLibrary()
        async let shelves: Void = loadReadingShelves()
        async let history: Void = fetchWatchActivity()
        await catalog
        await library
        await shelves
        await history
        await loadHomeDiscoverRows()
        persistHomeCache()
        // After the shelves, and detached: it is a handful of requests to the
        // manga sources and nothing on screen waits for it.
        Task { await checkForNewChapters() }
    }

    /// Re-reads the viewer's lists after a list mutation (status, score,
    /// progress, removal), in the background and without the loading flag.
    /// The engine invalidates its `get_user_list` cache on every save, but
    /// `upNextItems`, `watchingItems` and `libraryItems` are only ever
    /// built by `loadInitialCatalog` and `fetchLibrary`, which nothing ran
    /// again until the next launch: a title moved from Watching to
    /// Completed stayed in Up Next until then.
    func refreshListsAfterEdit() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadInitialCatalog()
            await self.fetchLibrary()
            await self.loadReadingShelves()
            self.persistHomeCache()
        }
    }

    /// AniList's own season/year pair for "now" — the convention the
    /// seasonal query expects. December belongs to *next* year's Winter, not
    /// this year's: AniList's "Winter 2025" is Dec 2024 through Feb 2025.
    static func currentAniListSeason(_ date: Date = Date()) -> (season: String, year: Int) {
        let month = Calendar.current.component(.month, from: date)
        let year = Calendar.current.component(.year, from: date)
        switch month {
        case 12: return ("WINTER", year + 1)
        case 1, 2: return ("WINTER", year)
        case 3, 4, 5: return ("SPRING", year)
        case 6, 7, 8: return ("SUMMER", year)
        default: return ("FALL", year)
        }
    }

    /// The home page's configurable rows: Planning (signed-in only), a Smart
    /// Picks blend, Newly Releasing (status RELEASING), and the current
    /// season. Requires `trendingItems` to already be loaded — Smart Picks
    /// fills out from it exactly like HomeView.tsx's `smartPicks` does.
    public func loadHomeDiscoverRows() async {
        guard let engine else { return }
        let (season, year) = Self.currentAniListSeason()
        async let planningTask: [MediaSummary] = isSignedIn
            ? ((try? await engine.userList(status: "PLANNING", mediaType: "ANIME")) ?? [])
            : []
        async let newlyReleasingTask = engine.discover(
            mediaType: "ANIME", status: "RELEASING", season: nil, seasonYear: nil, limit: 24
        )
        async let seasonalTask = engine.discover(
            mediaType: "ANIME", status: nil, season: season, seasonYear: Int32(year), limit: 24
        )
        // Skipped signed out rather than left to answer empty: the shelf is
        // derived from the viewer's own list, so signed out the round trip
        // can only ever come back with nothing.
        async let recommendedTask: [FfiRecommendationRow] = isSignedIn
            ? ((try? await engine.recommendationsForViewer(limit: 24)) ?? [])
            : []

        let planning = await planningTask
        let newlyReleasing = (try? await newlyReleasingTask) ?? []
        let seasonal = (try? await seasonalTask) ?? []
        let recommended = await recommendedTask

        planningItems = planning.map(Self.card)
        newlyReleasingItems = newlyReleasing.map(Self.card)
        seasonalItems = seasonal.map(Self.card)
        becauseYouWatched = recommended.map(Self.recommendationCard)

        let planningIds = Set(planningItems.map(\.id))
        // Dealt again only when the planning list itself changes. Every
        // refresh (each watched episode triggers one) used to reshuffle, and
        // twenty posters jumping under the cursor read as a bug, not variety.
        if planningIds != smartPicksSeed || smartPicks.isEmpty {
            let fill = trendingItems.filter { !planningIds.contains($0.id) }
            smartPicks = Array((planningItems.shuffled() + fill).prefix(20))
            smartPicksSeed = planningIds
        }
    }

    /// Wipes resume positions, provider overrides, and the offline list
    /// mirror. Settings' "Clear Local Registry" action.
    public func clearLocalRegistry() async -> Bool {
        guard let engine else { return false }
        do {
            try engine.clearLocalRegistry()
            return true
        } catch {
            errorMessage = "Could not clear local registry: \(error.localizedDescription)"
            return false
        }
    }

    /// Maps the engine's flat summary onto a card. One place, so a card in
    /// the Library draws its progress tick from the same fields as one in a
    /// home shelf.
    nonisolated static func card(_ s: MediaSummary) -> MediaCard.Item {
        let total = s.episodes ?? s.chapters
        let progress = s.progress.map { Int($0) }
        // s.nextEpisode is nil once a show stops airing, whether finished or
        // between seasons on hiatus. MediaSummary carries no separate airing
        // status, so falling back to `total` there can't distinguish "an
        // episode just aired" from "this finished ages ago" — it made a
        // backlogged CURRENT entry on a finished show show "Ep N out"
        // forever. Only trust nextEpisode itself for the "new" signal.
        let released = s.nextEpisode.map { Int($0) - 1 }
        let isManga = isMangaFormat(s.format) || (s.episodes == nil && s.chapters != nil)
        return MediaCard.Item(
            id: s.catalogId,
            title: s.title,
            coverImageURL: URL(string: s.coverImage),
            isManga: isManga,
            score: s.averageScore.map { Int($0) },
            progress: progress,
            totalEpisodesOrChapters: total.map { Int($0) },
            hasNewEpisode: {
                guard let p = progress, let r = released else { return false }
                return s.listStatus == "CURRENT" && p < r
            }(),
            listEntryId: s.listEntryId
        )
    }

    /// A recommendation card: the recommended title, captioned with the entry
    /// it was recommended from.
    ///
    /// The caption rides in `playlistReason`, and `progress` is cleared even
    /// where AniList reported one: `MediaCard` draws the reason only for a
    /// card with no progress, so an already-started recommendation would show
    /// "3/12" and no attribution at all — the one thing this shelf's cards
    /// exist to say.
    static func recommendationCard(_ row: FfiRecommendationRow) -> MediaCard.Item {
        let base = card(row.media)
        return MediaCard.Item(
            id: base.id,
            title: base.title,
            coverImageURL: base.coverImageURL,
            isManga: base.isManga,
            score: base.score,
            progress: nil,
            totalEpisodesOrChapters: base.totalEpisodesOrChapters,
            hasNewEpisode: false,
            playlistReason: "Because you watched \(row.becauseTitle)"
        )
    }

    /// Loads the user's list for one status bucket.
    public func loadLibrary(status: String? = nil, type: String? = nil) async {
        if let status { libraryStatus = status }
        if let type { libraryType = type }
        activeLibraryTask?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            self.isLoading = true
            defer { self.isLoading = false }
            await self.fetchLibrary()
        }
        activeLibraryTask = task
        await task.value
    }

    /// The network part of `loadLibrary`, split out so `refreshAll` can run
    /// it concurrently with the other home fetches without also racing
    /// `isLoading`'s own true/defer-false against theirs.
    func fetchLibrary() async {
        guard let engine, !Task.isCancelled else { return }
        do {
            var rows = try await engine.userList(status: libraryStatus, mediaType: libraryType)
            if ScreenshotFixtures.isEnabled {
                let pool = try await engine.trending(mediaType: libraryType, format: nil, limit: 24)
                rows = ScreenshotFixtures.list(status: libraryStatus, from: pool)
            }
            guard !Task.isCancelled else { return }
            await recordAniListSuccess()
            libraryItems = rows.map(Self.card)
        } catch {
            guard !Task.isCancelled else { return }
            await recordAniListFailure(error)
            libraryItems = []
            print("Library load failed: \(error)")
        }
    }

    /// Manga and light novels share a shape: a trending shelf plus whatever
    /// the user is already reading. Novels are AniList's `NOVEL` format under
    /// the `MANGA` type, not a type of their own.
    public func loadReadingShelves() async {
        guard let engine else { return }
        async let trendingMangaTask = engine.trending(mediaType: "MANGA", format: nil, limit: 24)
        async let novelsTask = engine.trending(mediaType: "MANGA", format: "NOVEL", limit: 24)
        async let readingRowsTask = engine.userList(status: "CURRENT", mediaType: "MANGA")

        let trendingManga = (try? await trendingMangaTask) ?? []
        let novels = (try? await novelsTask) ?? []
        var readingRows = (try? await readingRowsTask) ?? []
        if ScreenshotFixtures.isEnabled {
            readingRows = ScreenshotFixtures.watching(from: Array(trendingManga.prefix(5)) + Array(novels.prefix(3)))
        }

        mangaTrending = trendingManga.map(Self.card)
        novelTrending = novels.map(Self.card)
        let reading = Self.splitByFormat(readingRows)
        mangaReading = reading.manga
        novelReading = reading.novel
        let planning = await loadPlanningShelves()
        mangaPlanning = planning.manga
        novelPlanning = planning.novel
    }

    /// The `PLANNING` half of the reading shelves — one list request, split
    /// the same way `loadReadingShelves` splits `CURRENT`. Skipped signed
    /// out: `PLANNING` is a per-user list and the request would only 401.
    public func loadPlanningShelves() async -> (manga: [MediaCard.Item], novel: [MediaCard.Item]) {
        guard let engine, isSignedIn else { return ([], []) }
        var rows = (try? await engine.userList(status: "PLANNING", mediaType: "MANGA")) ?? []
        if ScreenshotFixtures.isEnabled {
            rows = ScreenshotFixtures.list(status: "PLANNING", from: mangaTrending.isEmpty ? [] : ((try? await engine.trending(mediaType: "MANGA", format: nil, limit: 24)) ?? []))
        }
        return Self.splitByFormat(rows)
    }

    /// Splits one `MANGA`-type AniList list into the manga tab's shelf and the
    /// light novel tab's, preserving the order AniList returned — the lists
    /// are sorted by the user's own list order, and re-sorting here would
    /// throw that away.
    ///
    /// `format` is the only thing telling the two apart: AniList has no
    /// separate novel type, so both tabs are fed from a single request rather
    /// than paying for two round trips that would return overlapping rows.
    nonisolated static func splitByFormat(_ rows: [MediaSummary]) -> (manga: [MediaCard.Item], novel: [MediaCard.Item]) {
        (
            manga: rows.filter { $0.format != "NOVEL" }.map(card),
            novel: rows.filter { $0.format == "NOVEL" }.map(card)
        )
    }

    /// The History view: the AniList profile when signed in, and the local
    /// watch log either way — the registry recorded that without a token.
    public func loadHistory() async {
        guard let engine else { return }
        // Chapters alongside the watch log: both are this device's registry,
        // and the History page asks one question of them.
        loadReadingActivity()
        if ScreenshotFixtures.isEnabled {
            await fetchWatchActivity()
            if viewer == nil {
                viewer = ScreenshotFixtures.profile(favourites: trendingItemsAsSummaries, favouriteManga: [])
            }
            isSignedIn = true
            return
        }
        activity = Self.anilistActivity((try? engine.watchActivity(limit: 500)) ?? [])
        resolveMissingTitles(activity.map(\.catalogId))
        viewer = try? await engine.viewerProfile()
        isSignedIn = viewer != nil
    }

    /// Just the watch log, for `refreshAll`'s concurrent batch — the
    /// viewer/isSignedIn part is dropped here because `loadInitialCatalog`,
    /// running at the same time, already fetches and sets both; doing it
    /// again here would be a second `viewerProfile` round trip racing to
    /// write the same two properties.
    func fetchWatchActivity() async {
        guard let engine else { return }
        if ScreenshotFixtures.isEnabled {
            let trending = (try? await engine.trending(mediaType: "ANIME", format: nil, limit: 24)) ?? []
            activity = ScreenshotFixtures.activity(for: ScreenshotFixtures.watching(from: trending))
            return
        }
        activity = Self.anilistActivity((try? engine.watchActivity(limit: 500)) ?? [])
        resolveMissingTitles(activity.map(\.catalogId))
    }

    /// How many AniList detail fetches one pass may issue. The History log
    /// is 500 rows deep and a long-lived registry has dozens of ids on no
    /// current shelf; firing one `mediaDetail` per id on every `refreshAll`
    /// is the burst that puts the client into its own rate-limit backoff and
    /// makes the next real page open queue behind it. Ids past the cap are
    /// not marked pending, so the next pass picks them up.
    nonisolated static let titleLookupsPerPass = 20

    /// Names the ids among `ids` that no loaded list has named, writing the
    /// answers into `knownTitles`/`knownCovers` through `resolvedTitles`.
    /// The registry stores a `catalog_id` and nothing else, so a row for a
    /// title on no current shelf drew "Media 17729" in History and on the
    /// Downloads page for as long as it sat there.
    ///
    /// Idempotent: an id already known or already in flight is skipped, so
    /// `refreshAll` calling this on every history reload costs nothing for
    /// the ids the last pass answered. The on-disk detail snapshot is asked
    /// first -- a title watched on this device was almost always opened on
    /// it -- and AniList only for the rest. All of it off the main actor:
    /// the snapshot peek is a file read per id, and twenty of them on the
    /// actor before History could draw was a visible stall.
    ///
    /// `preferManga` picks which AniList type is asked first. `mediaDetail`
    /// queries one type and a manga id asked for as ANIME is "no such
    /// media", so the reading log's titles were never named that way; the
    /// other type is always tried after a NotFound.
    func resolveMissingTitles(_ ids: some Collection<Int64>, preferManga: Bool = false) {
        guard let engine else { return }
        var wanted: [Int64] = []
        var seen = Set<Int64>()
        for id in ids where knownTitles[id] == nil && !pendingTitleLookups.contains(id)
            && !unresolvableTitleIds.contains(id) && !seen.contains(id) {
            seen.insert(id)
            wanted.append(id)
        }
        guard !wanted.isEmpty else { return }
        pendingTitleLookups.formUnion(wanted)

        Task.detached(priority: .utility) { [weak self] in
            var titles: [Int64: String] = [:]
            var covers: [Int64: URL] = [:]
            var unresolved: [Int64] = []
            var gone: [Int64] = []
            for id in wanted {
                if let peeked = DetailCache.peekTitle(id: id, isManga: preferManga)
                    ?? DetailCache.peekTitle(id: id, isManga: !preferManga) {
                    titles[id] = peeked.title
                    if let cover = peeked.coverURL { covers[id] = cover }
                } else {
                    unresolved.append(id)
                }
            }

            // Four at a time rather than the whole pass at once: twenty
            // concurrent requests is the same burst `titleLookupsPerPass`
            // exists to keep off the client, just compressed into one moment.
            let fetched = Array(unresolved.prefix(Self.titleLookupsPerPass))
            for start in stride(from: 0, to: fetched.count, by: 4) {
                let batch = fetched[start..<min(start + 4, fetched.count)]
                await withTaskGroup(of: (Int64, TitleLookup).self) { group in
                    for id in batch {
                        group.addTask {
                            (id, await Self.lookUpTitle(id, preferManga: preferManga, engine: engine))
                        }
                    }
                    for await (id, lookup) in group {
                        switch lookup {
                        case .found(let detail):
                            titles[id] = detail.title
                            if let cover = URL(string: detail.coverImage) { covers[id] = cover }
                        case .gone:
                            gone.append(id)
                        case .failed:
                            break
                        }
                    }
                }
            }

            await MainActor.run { [titles, covers, gone] in
                guard let self else { return }
                self.resolvedTitles.merge(titles) { _, new in new }
                self.resolvedCovers.merge(covers) { _, new in new }
                // Every id this pass took leaves `pending`, answered or not.
                // A network failure (AniList down) is retried by the next
                // pass, and the tail past the cap was never this pass's to
                // hold. "No such media" under both types is not retried: an
                // entry deleted from AniList 404'd on every `refreshAll` for
                // as long as its History row lived.
                self.pendingTitleLookups.subtract(wanted)
                self.unresolvableTitleIds.formUnion(gone)
                self.syncKnownTitles()
                self.applyResolvedDownloadTitles()
            }
        }
    }

    enum TitleLookup: Sendable {
        case found(MediaDetail)
        /// AniList has no media with this id under either type.
        case gone
        /// Anything else, network included; worth asking again later.
        case failed
    }

    nonisolated static func lookUpTitle(_ id: Int64, preferManga: Bool, engine: AnicatEngine) async -> TitleLookup {
        for isManga in [preferManga, !preferManga] {
            do {
                return .found(try await engine.mediaDetail(catalogId: id, isManga: isManga))
            } catch AnicatError.NotFound {
                continue
            } catch {
                return .failed
            }
        }
        return .gone
    }

    /// Whether the launch-time preresolve is on. Read here and nowhere
    /// else; Settings carries no control for it yet.
    static let preresolveUpNextKey = "anicat_preresolve_up_next"

    /// One speculative resolve of the first Up Next entry, once per launch.
    ///
    /// The 75% N+1 preload (`handlePlaybackPositionChange`) already proves
    /// the mechanism: a `preload: true` resolve fills the second
    /// selected-file slot and the real play hits the reuse path in
    /// `TorrentManager::resolve`. That only helps from the second episode of
    /// an evening on; the first play of a session was still a cold resolve,
    /// measured at 2750ms against ~800ms from an already-resolved file. The
    /// queue's first entry is the title touched most recently, and its next
    /// episode is the one play a launch can predict.
    ///
    /// Refused when a stream is already up (a Handoff or a deep link can
    /// start playback before this runs, and the preload must not compete
    /// with it for the swarm) and when the episode has not aired: an airing
    /// show with the viewer caught up has a next episode the indexers do
    /// not have yet, and a search for it either finds nothing or a wrong
    /// match with the same number from a different season.
    func preresolveUpNextIfIdle() {
        guard !hasPreresolvedUpNext else { return }
        hasPreresolvedUpNext = true
        guard UserDefaults.standard.object(forKey: Self.preresolveUpNextKey) as? Bool ?? true,
              let engine, activeStreamURL == nil, resolveStartedAt == nil,
              let entry = upNextItems.first, entry.unit == "EP" else { return }
        let next = entry.nextEpisodeOrChapter
        // The schedule is built from the same watching list: a row naming
        // this title with an episode number at or below the one wanted is
        // AniList saying it has not aired.
        if scheduleItems.contains(where: { $0.id == entry.id && $0.episodeNumber <= next }) { return }
        let request = StreamRequest(
            catalog: .anilist,
            catalogId: entry.id,
            episode: Int64(next),
            title: entry.title,
            preferDub: UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed",
            chosenName: nil,
            resumeFraction: nil,
            preload: true
        )
        let total = entry.totalCount
        let entryId = entry.id
        // On the main actor, with only the file read sent off it: the idle
        // recheck and the in-flight bookkeeping below both read model state.
        let task = Task(priority: .utility) { @MainActor [weak self] in
            defer { self?.preresolveInFlight = nil }
            // The snapshot's own row, when there is one; the list's episode
            // count otherwise.
            let aired = await Task.detached(priority: .utility) {
                DetailCache.peekAired(id: entryId, episode: next)
            }.value
            switch aired {
            case .some(false):
                return
            case .none where total > 0 && next > total:
                return
            default:
                break
            }
            // Idle is checked again right before the search, not only at the
            // top: the peek is long enough for a Handoff or the viewer's first
            // click to have started a play, and a preload begun after it
            // competes with that play for its swarm.
            guard let self, self.activeStreamURL == nil, self.resolveStartedAt == nil else { return }
            do {
                _ = try await engine.resolveStream(req: request)
            } catch {
                // Nothing visible depends on this: the real play resolves
                // cold exactly as it did before.
                print("[preload] up next episode \(next) of \(entry.id) not preresolved: \(error)")
            }
        }
        preresolveInFlight = (entry.id, Int64(next), task)
    }

    /// The registry records every catalog in one table and `watch_activity`
    /// returns all of it, so the anime History fed on films: two TMDB rows
    /// rendered as "Media 129552" among the anime, counted toward "21
    /// watches recorded on this device", and — because `openRegistryTitle`
    /// routes on the mode rather than on the row — opened AniList 129552,
    /// an unrelated manga, with a live "Add to List" pointed at it.
    /// `loadCinemaLibrary` has always filtered the other way.
    static func anilistActivity(_ rows: [ActivityRow]) -> [ActivityRow] {
        rows.filter { $0.catalog == .anilist }
    }

    /// `loadHistory` under screenshot mode may run before the home load has
    /// a trending list to build a profile from; an empty favourites row is
    /// fine there.
    private var trendingItemsAsSummaries: [MediaSummary] { [] }

    /// Loads the trending anime shelf that backs Search's Discover section.
    /// The same list `loadInitialCatalog` fetches; kept as its own method so
    /// the search page can top it up without re-running the whole home load.
    public func loadTrending() async {
        guard let engine else { return }
        isLoading = true
        defer { isLoading = false }
        let trending = (try? await engine.trending(mediaType: "ANIME", format: nil, limit: 24)) ?? []
        trendingItems = trending.map(Self.card)
    }

    /// Cmd+K's own live title search — deliberately not routed through
    /// `search()`: that mutates `searchResults`/`searchCurrentPage`, which
    /// belong to the Search tab, and the palette can be open from any screen.
    /// Anime only (matches the palette's own "Search shows..." placeholder;
    /// the Search tab is still the place to browse manga/novels).
    public func quickSearchTitles(_ query: String) async -> [MediaCard.Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !trimmed.isEmpty else { return [] }
        // Anime and manga, not anime alone. The palette is the one way into
        // a title from anywhere in the app, and it could not reach half the
        // catalog: typing a manga's name found the anime adaptation or
        // nothing. Two calls rather than one because AniList's `type` takes
        // a single value, and concurrently because they are independent.
        async let animeTask = engine.searchCatalog(query: trimmed, mediaType: "ANIME", filters: nil, page: 1)
        async let mangaTask = engine.searchCatalog(query: trimmed, mediaType: "MANGA", filters: nil, page: 1)
        let anime = (try? await animeTask) ?? []
        let manga = (try? await mangaTask) ?? []
        // Interleaved by popularity would put an obscure manga above the
        // anime everyone means; anime first keeps the common case first and
        // still makes the manga reachable.
        return (anime.prefix(6) + manga.prefix(4)).map { Self.card($0) }
    }

    /// Search's "Discover" section: an empty-query, trending-sorted browse of
    /// whichever type (Anime/Manga/Novel) is currently toggled, through the
    /// same paginated `searchCatalog` call `search()` uses — see
    /// `searchDiscoverItems`'s doc comment for why this exists separately
    /// from both `trendingItems` (Home's fixed, anime-only, unpaginated
    /// shelf) and `searchResults` (a real typed/filtered search).
    public func loadSearchDiscover(mediaType: String, page: Int32 = 1, append: Bool = false) async {
        guard let engine else { return }
        if append {
            isLoadingMoreSearchDiscover = true
        } else {
            searchDiscoverItems = []
            searchDiscoverHasMorePages = true
            isLoading = true
        }
        defer {
            if append { isLoadingMoreSearchDiscover = false } else { isLoading = false }
        }
        do {
            let filters = SearchFilters(genre: nil, year: nil, season: nil, format: nil, minScore: nil, status: nil, sort: "TRENDING_DESC")
            let summaries = try await engine.searchCatalog(query: "", mediaType: mediaType, filters: filters, page: page)
            await recordAniListSuccess()
            let cards = summaries.map { Self.card($0) }
            searchDiscoverItems = append ? searchDiscoverItems + cards : cards
            searchDiscoverPage = page
            searchDiscoverHasMorePages = cards.count >= 25
        } catch {
            await recordAniListFailure(error)
            print("Search discover failed: \(error)")
        }
    }

    /// Fills the home page.
    ///
    /// Everything here is real. This used to search for the literal string
    /// "Frieren" and then invent an Up Next entry and a week of airing times
    /// ("Monday, September 4", "in 2h 15m") out of the results — which made
    /// the app look populated in a screenshot while showing nothing a user
    /// could act on, and made the Schedule view a fiction.
    func loadInitialCatalog() async {
        guard let engine else { return }

        // Concurrent: all three are independent reads, and nothing here
        // touches `self` until every result is back, so fanning them out
        // carries none of the cross-task write races that ruled out
        // `async let` at the `refreshAll` level.
        async let trendingTask = engine.trending(mediaType: "ANIME", format: nil, limit: 24)
        async let watchingTask = engine.userList(status: "CURRENT", mediaType: "ANIME")
        async let profileTask = engine.viewerProfile()

        let trending = (try? await trendingTask) ?? []
        var watching = (try? await watchingTask) ?? []
        var profile = try? await profileTask
        if ScreenshotFixtures.isEnabled {
            watching = ScreenshotFixtures.watching(from: trending)
            profile = ScreenshotFixtures.profile(favourites: trending, favouriteManga: [])
        }
        trendingItems = trending.map(Self.card)
        if profile != nil || !trending.isEmpty || !watching.isEmpty {
            await recordAniListSuccess()
        }
        isSignedIn = profile != nil
        viewer = profile
        watchingItems = watching.map(Self.card)
        watchingSummaries = watching
        rebuildUpNext()

        // Only shows AniList actually has an airing time for. A show with no
        // `nextAiringEpisode` is not on the schedule; it is finished, or
        // between seasons.
        let formatter = SumiTheme.timeFormatter()
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "EEEE, MMMM d"
        let watchingIds = Set(watching.map(\.catalogId))
        var seenIds = Set<Int64>()
        var combinedAiring: [ScheduleView.ScheduleItem] = []

        for s in (watching + trending) {
            guard !seenIds.contains(s.catalogId),
                  let at = s.nextAiringAt,
                  let ep = s.nextEpisode else { continue }
            seenIds.insert(s.catalogId)
            let date = Date(timeIntervalSince1970: TimeInterval(at))
            combinedAiring.append(
                ScheduleView.ScheduleItem(
                    id: s.catalogId,
                    title: s.title,
                    coverImageURL: URL(string: s.coverImage),
                    episodeNumber: Int(ep),
                    airingTimeText: formatter.string(from: date),
                    countdownText: Self.countdown(to: date),
                    dayGroup: dayFormatter.string(from: date),
                    airingAt: at,
                    isWatching: watchingIds.contains(s.catalogId)
                )
            )
        }
        scheduleItems = combinedAiring.sorted { $0.airingAt < $1.airingAt }
    }

    /// "6h ago", "3d ago" — the same buckets `relativeDay` uses on the web.
    /// Builds the Up Next queue from `watchingSummaries`, ordered by the
    /// later of AniList's `updatedAt` and this device's last watch.
    ///
    /// AniList's `updatedAt` only moves when the list entry does, which is
    /// at the 85% mark. Watching half an episode and closing the player left
    /// the title where it was in the queue, still "2d ago", while History
    /// already had it on top.
    func rebuildUpNext() {
        var lastWatched: [Int64: Int64] = [:]
        for row in activity {
            guard let date = Self.watchedAtParser.date(from: row.watchedAt) else { continue }
            let seconds = Int64(date.timeIntervalSince1970)
            lastWatched[row.catalogId] = max(lastWatched[row.catalogId] ?? 0, seconds)
        }
        func touched(_ s: MediaSummary) -> Int64? {
            switch (s.updatedAt, lastWatched[s.catalogId]) {
            case let (remote?, local?): return max(remote, local)
            case let (remote, local): return remote ?? local
            }
        }
        // AniList's `watching` list comes back in whatever order the API
        // defaults to (not recency) — `upNextItems.first` is what the menu
        // bar's "Continue Watching" reads as the most-recently-watched
        // title, so leaving this unsorted meant it showed whichever show
        // happened to sit first in AniList's own list order, not whatever
        // was actually last touched.
        let sortedWatching = watchingSummaries.sorted { (touched($0) ?? 0) > (touched($1) ?? 0) }
        upNextItems = sortedWatching.map { s in
            let progress = Int(s.progress ?? 0)
            let total = Int(s.episodes ?? 0)
            // Same fallback caveat as Self.card: nextEpisode is nil once a
            // show stops airing, and MediaSummary has no separate airing
            // status to tell finished apart from mid-season, so only trust
            // nextEpisode itself as the "new episode" signal.
            let released = s.nextEpisode.map { Int($0) - 1 } ?? -1
            return UpNextQueueView.QueueEntry(
                id: s.catalogId,
                title: s.title,
                thumbnailURL: URL(string: s.coverImage),
                nextEpisodeOrChapter: progress + 1,
                totalCount: total,
                progressPercent: total > 0 ? Double(progress) / Double(total) * 100 : 0,
                watchedTimeAgo: touched(s).map(Self.relativeTime),
                hasNewEpisode: progress < released,
                unit: "EP"
            )
        }
    }

    /// SQLite's `datetime('now')`: `YYYY-MM-DD HH:MM:SS`, UTC, no zone marker.
    /// Read in the local zone it put a just-watched title hours away from
    /// AniList's Unix `updatedAt`, in whichever direction the zone points.
    private static let watchedAtParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func relativeTime(_ unixSeconds: Int64) -> String {
        let seconds = Date().timeIntervalSince1970 - TimeInterval(unixSeconds)
        let hours = Int(seconds / 3600)
        if hours < 1 { return "just now" }
        if hours < 24 { return "\(hours)h ago" }
        let days = hours / 24
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days)d ago" }
        return "\(days / 7)w ago"
    }

    static func countdown(to date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow)
        if seconds <= 0 { return "aired" }
        let hours = seconds / 3600
        if hours < 24 { return "in \(hours)h \(seconds % 3600 / 60)m" }
        return "in \(hours / 24)d \(hours % 24)h"
    }

    /// Search anime, manga, or light novels across the AniList catalog.
    /// `mediaType` is "ANIME", "MANGA", or "NOVEL"; `isManga` is kept for
    /// existing callers that only distinguish anime from manga. A blank
    /// `query` is allowed as long as a filter is set — AniList's `Page.media`
    /// returns a plain popularity-sorted browse when `search` is null, which
    /// is what lets picking a genre alone (no typed text) filter the results
    /// grid instead of doing nothing.
    ///
    /// `page`/`append` add pagination: `append: true` adds a page onto
    /// `searchResults` instead of replacing it, and `searchHasMorePages` is
    /// inferred from page size — the FFI call returns a bare list with no
    /// `hasNextPage`, so a page short of 25 is necessarily the last one.
    public func search(
        query: String,
        mediaType: String? = nil,
        isManga: Bool? = nil,
        filters: SearchFilters? = nil,
        page: Int32 = 1,
        append: Bool = false
    ) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // Every field of SearchFilters has to be listed here: this is the
        // guard that decides whether a query-less browse runs at all, so a
        // field missing from it makes that filter's dropdown look dead —
        // picking it clears the results instead of searching.
        let hasActiveFilter = filters.map {
            $0.genre != nil || $0.year != nil || $0.season != nil || $0.format != nil
                || $0.minScore != nil || $0.status != nil || $0.sort != nil
        } ?? false
        guard let engine, !trimmedQuery.isEmpty || hasActiveFilter else {
            activeSearchTask?.cancel()
            searchResults = []
            searchHasMorePages = true
            return
        }

        if !append {
            activeSearchTask?.cancel()
        }

        let task = Task { [weak self] in
            guard let self else { return }
            if append {
                self.isLoadingMoreSearchResults = true
            } else {
                self.searchResults = []
                self.searchHasMorePages = true
                self.isLoading = true
            }
            defer {
                if append { self.isLoadingMoreSearchResults = false } else { self.isLoading = false }
            }

            do {
                guard !Task.isCancelled else { return }
                let resolvedType = mediaType ?? (isManga == true ? "MANGA" : (isManga == false ? "ANIME" : nil))
                    ?? (self.currentNavSection == .novels ? "NOVEL" : (self.currentNavSection == .manga ? "MANGA" : "ANIME"))
                let summaries = try await engine.searchCatalog(query: trimmedQuery, mediaType: resolvedType, filters: filters, page: page)
                guard !Task.isCancelled else { return }
                await self.recordAniListSuccess()
                let cards = summaries.map { Self.card($0) }
                self.searchResults = append ? self.searchResults + cards : cards
                self.searchCurrentPage = page
                self.searchHasMorePages = cards.count >= 25
            } catch {
                guard !Task.isCancelled else { return }
                await self.recordAniListFailure(error)
                print("Search failed: \(error)")
            }
        }
        if !append {
            activeSearchTask = task
        }
        await task.value
    }
}
