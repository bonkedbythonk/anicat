import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

@Observable
public final class AppModel: @unchecked Sendable {
    public var engine: AnicatEngine?
    public var isInitialized = false
    public var isLoading = false
    public var errorMessage: String?

    // Active Navigation
    public var currentNavSection: SidebarView.NavSection = .upNext
    public var paletteOpen = false
    public var searchQuery: String = ""
    public var selectedMediaDetails: HeroBanner.Details?
    public var selectedEpisodes: [MediaDetailView.EpisodeItem] = []
    public var selectedMangaChapters: [MediaDetailView.MangaChapterItem] = []
    public var activeStreamURL: URL?

    // PlayerController & Playback Tracking
    public let playerController = PlayerController()
    public var currentPlaybackCatalog: FfiCatalog = .anilist
    public var currentPlaybackCatalogId: Int64?
    public var currentPlaybackEpisode: Int64?
    public var currentPlaybackTitle: String?
    private var lastRecordedSecond: Int64 = -1

    // Manga Reading Session
    public struct MangaReadingSession: Identifiable, Sendable {
        public var id: String { chapterId }
        public let title: String
        public let chapterTitle: String
        public let chapterId: String
        public let pageURLs: [URL]
        public let chapterIndex: Int
        public let chapters: [MediaDetailView.MangaChapterItem]
        public let anilistId: Int64?

        public init(
            title: String,
            chapterTitle: String,
            chapterId: String,
            pageURLs: [URL],
            chapterIndex: Int,
            chapters: [MediaDetailView.MangaChapterItem],
            anilistId: Int64?
        ) {
            self.title = title
            self.chapterTitle = chapterTitle
            self.chapterId = chapterId
            self.pageURLs = pageURLs
            self.chapterIndex = chapterIndex
            self.chapters = chapters
            self.anilistId = anilistId
        }
    }

    public var activeReadingSession: MangaReadingSession?

    // Dashboard State
    public var upNextItems: [UpNextQueueView.QueueEntry] = []
    public var watchingItems: [MediaCard.Item] = []
    public var trendingItems: [MediaCard.Item] = []
    public var searchResults: [MediaCard.Item] = []
    public var scheduleItems: [ScheduleView.ScheduleItem] = []

    // Home's configurable rows (below the fixed Up Next / Watching shelves).
    // The queue and Watching aren't configurable — they're the front page,
    // same split as HomeView.tsx.
    public var planningItems: [MediaCard.Item] = []
    public var smartPicks: [MediaCard.Item] = []
    public var newlyReleasingItems: [MediaCard.Item] = []
    public var seasonalItems: [MediaCard.Item] = []

    /// One configurable home row: which one, its display title, and whether
    /// the user has it shown. Reorder is the array order itself.
    public struct HomeRowConfig: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var visible: Bool
    }

    static let defaultHomeRows: [HomeRowConfig] = [
        HomeRowConfig(id: "planning", title: "Planning", visible: true),
        HomeRowConfig(id: "smartPlaylist", title: "Smart Picks", visible: true),
        HomeRowConfig(id: "trending", title: "Trending Now", visible: true),
        HomeRowConfig(id: "newlyReleasing", title: "Newly Releasing", visible: true),
        HomeRowConfig(id: "seasonal", title: "Seasonal Highlights", visible: true),
    ]

    private static let homeRowsDefaultsKey = "anicat_home_rows"

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

    public var homeRowConfig: [HomeRowConfig] = AppModel.loadHomeRowConfig()

    private func persistHomeRowConfig() {
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

    // Library / Manga / Novels / History
    public var libraryItems: [MediaCard.Item] = []
    public var libraryStatus: String = "CURRENT"
    public var libraryType: String = "ANIME"
    public var mangaTrending: [MediaCard.Item] = []
    public var mangaReading: [MediaCard.Item] = []
    public var novelTrending: [MediaCard.Item] = []
    public var novelReading: [MediaCard.Item] = []
    public var viewer: ViewerProfile?
    public var activity: [ActivityRow] = []

    /// Titles for ids the History log has rows for, gathered from every list
    /// already loaded. The registry stores a `catalog_id` and nothing else —
    /// it has no idea what a show is called — so the name has to come from
    /// whatever the catalog views have already fetched.
    public var knownTitles: [Int64: String] {
        var out: [Int64: String] = [:]
        for item in watchingItems + trendingItems + libraryItems + mangaReading + novelReading + searchResults {
            out[item.id] = item.title
        }
        return out
    }

    /// Whether AniList answered with a viewer. The four catalog-backed views
    /// have nothing to show without it and say so rather than sitting empty.
    public var isSignedIn = false

    public init() {
        setupPlayerCallbacks()
    }

    private func setupPlayerCallbacks() {
        playerController.onPositionChange = { [weak self] currentTime, duration in
            self?.handlePlaybackPositionChange(currentTime: currentTime, duration: duration)
        }
        playerController.onPlaybackStopped = { [weak self] in
            self?.stopPlayback()
        }
    }

    /// Initializes the headless Rust engine and opens the SQLite registry.
    public func initialize(anilistToken: String? = nil, tmdbKey: String? = nil) async {
        guard engine == nil else { return }

        isLoading = true
        defer { isLoading = false }

        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dataDir = appSupport.appendingPathComponent("AniCat", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

            // Zero-Login iCloud Sync: retrieve token from iCloud Keychain if not explicitly provided
            let token = anilistToken ?? iCloudSyncService.shared.getAniListToken()

            let coreEngine = try AnicatEngine(
                dataDir: dataDir.path,
                anilistToken: token,
                tmdbKey: tmdbKey
            )
            self.engine = coreEngine

            let port = try await coreEngine.streamPort()
            print("AniCat Rust Engine ready! Dynamic stream server on port: \(port)")
            self.isInitialized = true

            // Bonjour Local Swarm Offload: advertise on macOS, browse on iOS
            #if os(macOS)
            BonjourDiscovery.shared.startAdvertising(port: port)
            #else
            BonjourDiscovery.shared.startBrowsing()
            #endif

            // Preload everything the signed-in views draw from. `refreshAll`
            // (not just `loadInitialCatalog`) is what fills Manga, Light
            // Novels and History — on a launch where the token was already in
            // the Keychain, `signIn` never runs, so those shelves stayed empty
            // until the user pasted a token again.
            await refreshAll()
        } catch {
            self.errorMessage = "Failed to start AniCat Engine: \(error.localizedDescription)"
            print(errorMessage!)
        }
    }

    /// Hands a pasted token to the running engine and reloads everything.
    ///
    /// This used to route back through `initialize`, which opens with
    /// `guard engine == nil else { return }` — the engine is built at launch,
    /// before any token exists, so that guard fired every time and the token
    /// reached the Keychain but never the AniList client. Saving appeared to
    /// do nothing at all.
    public func signIn(token: String) async {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !trimmed.isEmpty else { return }
        isLoading = true
        defer { isLoading = false }

        engine.setAnilistToken(token: trimmed)
        let profile = try? await engine.viewerProfile()
        guard profile != nil else {
            isSignedIn = false
            errorMessage = "AniList rejected that token."
            return
        }
        _ = iCloudSyncService.shared.saveAniListToken(trimmed)
        viewer = profile
        isSignedIn = true
        errorMessage = nil
        await refreshAll()
    }

    public func signOut() {
        engine?.setAnilistToken(token: nil)
        iCloudSyncService.shared.deleteAniListToken()
        isSignedIn = false
        viewer = nil
        watchingItems = []
        upNextItems = []
        scheduleItems = []
        libraryItems = []
        mangaReading = []
        novelReading = []
        planningItems = []
        smartPicks = []
    }

    /// Everything the signed-in views draw from, in one pass.
    public func refreshAll() async {
        await loadInitialCatalog()
        await loadLibrary()
        await loadReadingShelves()
        await loadHistory()
        await loadHomeDiscoverRows()
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
        let planning = isSignedIn ? ((try? await engine.userList(status: "PLANNING", mediaType: "ANIME")) ?? []) : []
        let newlyReleasing = (try? await engine.discover(
            mediaType: "ANIME", status: "RELEASING", season: nil, seasonYear: nil, limit: 24
        )) ?? []
        let (season, year) = Self.currentAniListSeason()
        let seasonal = (try? await engine.discover(
            mediaType: "ANIME", status: nil, season: season, seasonYear: Int32(year), limit: 24
        )) ?? []

        planningItems = planning.map(Self.card)
        newlyReleasingItems = newlyReleasing.map(Self.card)
        seasonalItems = seasonal.map(Self.card)

        let planningIds = Set(planningItems.map(\.id))
        let fill = trendingItems.filter { !planningIds.contains($0.id) }
        smartPicks = Array((planningItems.shuffled() + fill).prefix(20))
    }

    /// One entry per detail page navigated away from (relation click, related
    /// title, up-next card) while another was already open — mirrors the
    /// web's `detailStack`. Without it, "back" (swipe, the X button, mouse
    /// back button) always landed on the home screen: opening season 2 from
    /// season 1's detail page overwrote `selectedMediaDetails` in place, so
    /// there was nothing to return to except nil.
    private var detailHistory: [(id: Int64, isManga: Bool)] = []

    /// Opens the detail page for a title, fetching real AniList metadata and real streaming/registry episodes.
    public func openDetail(id: Int64, isManga: Bool = false) async {
        if let current = selectedMediaDetails {
            detailHistory.append((id: current.id, isManga: Self.isMangaFormat(current.format)))
        }
        await loadDetail(id: id, isManga: isManga)
    }

    /// Goes back one level in `detailHistory`, or all the way home when it's
    /// empty. Shared by the swipe-back gesture, the detail page's close
    /// button, and the mouse back button/Alt+Left — matching the web, where
    /// all three call the same `closeDetail`.
    public func closeDetail() {
        guard let previous = detailHistory.popLast() else {
            selectedMediaDetails = nil
            selectedEpisodes = []
            selectedMangaChapters = []
            return
        }
        Task { await loadDetail(id: previous.id, isManga: previous.isManga) }
    }

    private static func isMangaFormat(_ format: String?) -> Bool {
        format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT"
    }

    /// Closes the detail page and drops the whole `detailHistory`, unlike
    /// `closeDetail()` which pops one level. Use this when leaving the detail
    /// page for somewhere else entirely (switching sidebar sections), where
    /// there's nothing to go "back" to.
    public func clearDetail() {
        selectedMediaDetails = nil
        selectedEpisodes = []
        selectedMangaChapters = []
        detailHistory = []
    }

    /// Fetches and sets the detail page in place, without touching `detailHistory`.
    /// Used by `openDetail`/`closeDetail` above, and by any caller (like the
    /// post-playback refresh) that needs to reload the currently open title
    /// rather than navigate to a new one.
    private func loadDetail(id: Int64, isManga: Bool) async {
        guard let engine else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let d = try await engine.mediaDetail(catalogId: id, isManga: isManga)
            let episodes = d.episodes.map { e in
                MediaDetailView.EpisodeItem(
                    id: Int64(e.number),
                    number: Int(e.number),
                    title: e.title,
                    thumbnailURL: e.thumbnail.flatMap(URL.init(string:)),
                    isWatched: e.isWatched,
                    progressPercent: e.progressPercent,
                    runtimeMinutes: e.runtimeMinutes.map(Int.init)
                )
            }
            var chapters: [MediaDetailView.MangaChapterItem] = []
            if isManga || d.chapterCount != nil || d.format == "MANGA" || d.format == "NOVEL" || d.format == "ONE_SHOT" {
                let fetched = (try? await engine.mangaChapters(alId: id)) ?? []
                chapters = fetched.map {
                    MediaDetailView.MangaChapterItem(id: $0.id, number: $0.number, title: $0.title)
                }
            }

            self.selectedEpisodes = episodes.sorted(by: { $0.number < $1.number })
            self.selectedMangaChapters = chapters
            self.selectedMediaDetails = HeroBanner.Details(
                id: d.catalogId,
                title: d.title,
                romajiTitle: d.romajiTitle,
                bannerURL: d.bannerImage.flatMap(URL.init(string:)),
                coverURL: URL(string: d.coverImage),
                format: d.format,
                year: d.year.map(Int.init),
                studio: d.studio,
                synopsis: d.synopsis,
                genres: d.genres,
                averageScore: d.averageScore.map(Int.init),
                nextEpisodeText: nil,
                status: d.status,
                episodeCount: (d.episodeCount ?? d.chapterCount).map(Int.init),
                resumeEpisode: d.resumeEpisode.map(Int.init),
                resumeSeconds: d.resumeSeconds.map(Int.init),
                prequel: d.prequel.map(Self.relation),
                sequel: d.sequel.map(Self.relation),
                listStatus: d.listStatus,
                userScore: d.userScore,
                listEntryId: d.listEntryId,
                listProgress: d.listProgress.map(Int.init),
                isFavourite: d.isFavourite
            )
        } catch {
            errorMessage = "Could not open that title: \(error.localizedDescription)"
        }
    }

    public func openDetail(catalogId: Int64, isManga: Bool = false) async {
        await openDetail(id: catalogId, isManga: isManga)
    }

    /// Same format check `RootView`/`MediaDetailView` already use to route
    /// play vs. read actions for the open title.
    private func currentDetailIsManga() -> Bool {
        guard let format = selectedMediaDetails?.format else { return false }
        return format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT"
    }

    /// Changes the signed-in user's AniList list entry for the open title —
    /// status, score, or progress, independently. Refetches the detail page
    /// afterward rather than updating local state optimistically, so what's
    /// shown is what AniList actually saved.
    public func updateListEntry(status: String? = nil, score: Double? = nil, progress: Int64? = nil) async {
        guard let engine, let details = selectedMediaDetails else { return }
        do {
            try await engine.updateListEntry(catalogId: details.id, status: status, score: score, progress: progress)
            await openDetail(id: details.id, isManga: currentDetailIsManga())
        } catch {
            errorMessage = "Could not update AniList: \(error.localizedDescription)"
        }
    }

    public func toggleFavourite() async {
        guard let engine, let details = selectedMediaDetails else { return }
        do {
            try await engine.toggleFavourite(catalogId: details.id, isManga: currentDetailIsManga())
            await openDetail(id: details.id, isManga: currentDetailIsManga())
        } catch {
            errorMessage = "Could not update favourite: \(error.localizedDescription)"
        }
    }

    /// Removes the open title from the signed-in user's list entirely.
    public func removeFromList() async {
        guard let engine, let details = selectedMediaDetails, let entryId = details.listEntryId else { return }
        do {
            try await engine.removeFromList(listEntryId: entryId)
            await openDetail(id: details.id, isManga: currentDetailIsManga())
        } catch {
            errorMessage = "Could not remove from AniList: \(error.localizedDescription)"
        }
    }

    /// The episode list's mark-watched checkbox. Mirrors
    /// `handleUpdateProgress` in MediaDetail.tsx: watching episode N sets
    /// progress to N; un-watching it sets progress to N-1. Unlike the web
    /// build (which re-fetches the whole title server-side just to learn the
    /// episode total), the clamp-to-total-and-complete safety net runs here
    /// against `episodeCount`, already in hand from the open detail page —
    /// covers a provider that lists one extra episode (e.g. a special
    /// counted as `total+1`) without a second round trip.
    public func setEpisodeWatched(_ episode: Int, watched: Bool) async {
        guard let details = selectedMediaDetails else { return }
        var progress = watched ? episode : episode - 1
        var status: String?
        if let total = details.episodeCount, total > 0, progress >= total {
            progress = total
            status = "COMPLETED"
        } else if progress > 0, details.listStatus == nil || details.listStatus == "PLANNING" {
            status = "CURRENT"
        }
        await updateListEntry(status: status, progress: Int64(progress))
    }

    /// Opens the manga reader for a selected chapter, fetching real page images via engine.mangaPages.
    public func openReader(
        title: String,
        chapter: MediaDetailView.MangaChapterItem,
        allChapters: [MediaDetailView.MangaChapterItem] = [],
        anilistId: Int64? = nil
    ) async {
        guard let engine else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let pages = try await engine.mangaPages(chapterId: chapter.id)
            let urls = pages.compactMap { URL(string: $0) }
            let index = allChapters.firstIndex(where: { $0.id == chapter.id }) ?? 0
            let displayTitle = chapter.title.isEmpty ? "Chapter \(chapter.number)" : "CH \(chapter.number): \(chapter.title)"
            self.activeReadingSession = MangaReadingSession(
                title: title,
                chapterTitle: displayTitle,
                chapterId: chapter.id,
                pageURLs: urls,
                chapterIndex: index,
                chapters: allChapters,
                anilistId: anilistId
            )
            ContinuityManager.shared.advertiseReading(
                mangaId: chapter.id,
                title: title,
                chapter: chapter.number,
                pageIndex: 0
            )
        } catch {
            errorMessage = "Could not load chapter pages: \(error.localizedDescription)"
            print("Manga pages load failed: \(error)")
        }
    }

    public func closeReader() {
        activeReadingSession = nil
        ContinuityManager.shared.stopAdvertising()
    }

    public func nextChapter() async {
        guard let session = activeReadingSession else { return }
        let nextIndex = session.chapterIndex + 1
        if nextIndex < session.chapters.count {
            let nextChapter = session.chapters[nextIndex]
            await openReader(
                title: session.title,
                chapter: nextChapter,
                allChapters: session.chapters,
                anilistId: session.anilistId
            )
        }
    }

    public func prevChapter() async {
        guard let session = activeReadingSession else { return }
        let prevIndex = session.chapterIndex - 1
        if prevIndex >= 0 {
            let prevChapter = session.chapters[prevIndex]
            await openReader(
                title: session.title,
                chapter: prevChapter,
                allChapters: session.chapters,
                anilistId: session.anilistId
            )
        }
    }

    static func relation(_ r: RelatedTitle) -> HeroBanner.Details.Relation {
        HeroBanner.Details.Relation(
            id: r.catalogId,
            title: r.title,
            format: r.format,
            coverURL: URL(string: r.coverImage)
        )
    }

    /// Maps the engine's flat summary onto a card. One place, so a card in
    /// the Library draws its progress tick from the same fields as one in a
    /// home shelf.
    static func card(_ s: MediaSummary) -> MediaCard.Item {
        let total = s.episodes ?? s.chapters
        let progress = s.progress.map { Int($0) }
        let released = s.nextEpisode.map { Int($0) - 1 } ?? total.map { Int($0) }
        return MediaCard.Item(
            id: s.catalogId,
            title: s.title,
            coverImageURL: URL(string: s.coverImage),
            isManga: s.episodes == nil && s.chapters != nil,
            score: s.averageScore.map { Int($0) },
            progress: progress,
            totalEpisodesOrChapters: total.map { Int($0) },
            hasNewEpisode: {
                guard let p = progress, let r = released else { return false }
                return s.listStatus == "CURRENT" && p < r
            }()
        )
    }

    /// Loads the user's list for one status bucket.
    public func loadLibrary(status: String? = nil, type: String? = nil) async {
        guard let engine else { return }
        if let status { libraryStatus = status }
        if let type { libraryType = type }
        isLoading = true
        defer { isLoading = false }
        do {
            let rows = try await engine.userList(status: libraryStatus, mediaType: libraryType)
            libraryItems = rows.map(Self.card)
        } catch {
            libraryItems = []
            print("Library load failed: \(error)")
        }
    }

    /// Manga and light novels share a shape: a trending shelf plus whatever
    /// the user is already reading. Novels are AniList's `NOVEL` format under
    /// the `MANGA` type, not a type of their own.
    public func loadReadingShelves() async {
        guard let engine else { return }
        // Sequential rather than `async let`: the engine is a shared
        // reference and the strict-concurrency checker rejects sending it
        // into concurrent children. The three calls are cached AniList reads,
        // so the cost of serialising them is a few hundred milliseconds once
        // per visit, not per interaction.
        let trendingManga = (try? await engine.trending(mediaType: "MANGA", format: nil, limit: 24)) ?? []
        let novels = (try? await engine.trending(mediaType: "MANGA", format: "NOVEL", limit: 24)) ?? []
        let readingRows = (try? await engine.userList(status: "CURRENT", mediaType: "MANGA")) ?? []

        mangaTrending = trendingManga.map(Self.card)
        novelTrending = novels.map(Self.card)
        mangaReading = readingRows.filter { $0.format != "NOVEL" }.map(Self.card)
        novelReading = readingRows.filter { $0.format == "NOVEL" }.map(Self.card)
    }

    /// The History view: the AniList profile when signed in, and the local
    /// watch log either way — the registry recorded that without a token.
    public func loadHistory() async {
        guard let engine else { return }
        activity = (try? engine.watchActivity(limit: 500)) ?? []
        viewer = try? await engine.viewerProfile()
        isSignedIn = viewer != nil
    }

    /// Loads the trending anime shelf that backs Search's Discover section.
    /// The same list `loadInitialCatalog` fetches; kept as its own method so
    /// the search page can top it up without re-running the whole home load.
    public func loadTrending() async {
        guard let engine else { return }
        let trending = (try? await engine.trending(mediaType: "ANIME", format: nil, limit: 24)) ?? []
        trendingItems = trending.map(Self.card)
    }

    /// Search anime, manga, or light novels across the AniList catalog.
    /// `mediaType` is "ANIME", "MANGA", or "NOVEL"; `isManga` is kept for
    /// existing callers that only distinguish anime from manga.
    public func search(query: String, mediaType: String? = nil, isManga: Bool? = nil) async {
        guard let engine, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchResults = []
            return
        }

        isLoading = true
        defer { isLoading = false }

        do {
            let resolvedType = mediaType ?? (isManga == true ? "MANGA" : (isManga == false ? "ANIME" : nil))
                ?? (currentNavSection == .novels ? "NOVEL" : (currentNavSection == .manga ? "MANGA" : "ANIME"))
            let summaries: [MediaSummary]
            switch resolvedType {
            case "NOVEL":
                summaries = try await engine.searchNovel(query: query)
            case "MANGA":
                summaries = try await engine.searchMangaCatalog(query: query)
            default:
                summaries = try await engine.searchAnime(query: query)
            }
            self.searchResults = summaries.map { Self.card($0) }
        } catch {
            print("Search failed: \(error)")
        }
    }

    /// Handles real-time playback position changes from the player and records to SQLite.
    public func handlePlaybackPositionChange(currentTime: Double, duration: Double) {
        guard let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let engine else { return }

        let rawStop = Int64(currentTime)
        let dur = Int64(duration)
        let stopTime = dur > 0 ? min(rawStop, dur) : rawStop

        // Only record if whole second changed and valid
        guard stopTime != lastRecordedSecond, stopTime >= 0 else { return }
        lastRecordedSecond = stopTime

        try? engine.recordProgress(
            catalog: currentPlaybackCatalog,
            catalogId: catalogId,
            episodeNumber: episode,
            stopTime: stopTime,
            duration: dur
        )

        ContinuityManager.shared.advertisePlayback(
            catalogId: catalogId,
            title: currentPlaybackTitle ?? "Anime",
            episode: Int(episode),
            timePositionSeconds: currentTime
        )
    }

    /// Resolves a torrent release and prepares the stream URL for playback.
    public func resolveAndPlay(
        catalog: FfiCatalog = .anilist,
        catalogId: Int64,
        episode: Int64,
        title: String? = nil
    ) async throws -> URL {
        let effectiveTitle = title ?? self.selectedMediaDetails?.title ?? self.knownTitles[catalogId] ?? "Anime"
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.isPlaying = true

        guard let engine else {
            throw NSError(domain: "AniCat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        isLoading = true
        defer { isLoading = false }

        self.currentPlaybackCatalog = catalog
        self.currentPlaybackCatalogId = catalogId
        self.currentPlaybackEpisode = episode
        self.currentPlaybackTitle = effectiveTitle
        self.lastRecordedSecond = -1

        // Restore any existing progress from SQLite or media metadata
        var initialDuration: Double = 0.0
        var initialTime: Double = 0.0
        // Only from the recorded (real) duration, never the AniList runtime
        // estimate below — that's a flat ~24min for every episode, and an
        // estimate-of-an-estimate byte offset would tell the Rust pre-buffer
        // gate to warm the wrong part of the file.
        var resumeFraction: Double?
        if let progress = try? engine.getProgress(catalog: catalog, catalogId: catalogId, episodeNumber: episode) {
            initialTime = Double(progress.stopTime)
            initialDuration = Double(progress.duration)
            if initialTime > 0, initialDuration > 0 {
                resumeFraction = initialTime / initialDuration
            }
        }
        if initialDuration <= 0 {
            if let ep = selectedEpisodes.first(where: { $0.number == Int(episode) }),
               let runtime = ep.runtimeMinutes, runtime > 0 {
                initialDuration = Double(runtime * 60)
            }
        }
        self.playerController.currentTime = initialTime
        self.playerController.duration = initialDuration

        // Tells the torrent resolve's pre-buffer gate where mpv's `--start`
        // will actually land, so it warms that region of the swarm instead of
        // only proving byte 0 is healthy and handing off to a resume seek
        // that stalls forever on an unprioritized piece.
        // Settings' Sub/Dub picker was write-only until now — nothing read
        // `anicat_sub_dub` back, so choosing "Dubbed" changed nothing about
        // which release got picked.
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let req = StreamRequest(
            catalog: catalog,
            catalogId: catalogId,
            episode: episode,
            title: effectiveTitle,
            preferDub: preferDub,
            chosenName: nil,
            resumeFraction: resumeFraction
        )

        let handle = try await engine.resolveStream(req: req)
        guard let streamURL = URL(string: handle.url) else {
            throw NSError(domain: "AniCat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL: \(handle.url)"])
        }

        // Before returning streamURL, configure playerController with actual title, episode number, and duration
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.isPlaying = true
        if self.playerController.duration <= 0 && initialDuration > 0 {
            self.playerController.duration = initialDuration
        }

        self.activeStreamURL = streamURL

        // Apple Handoff: broadcast current playback activity to iPhone / iPad / Mac
        ContinuityManager.shared.advertisePlayback(
            catalogId: catalogId,
            title: effectiveTitle,
            episode: Int(episode),
            timePositionSeconds: playerController.currentTime
        )

        return streamURL
    }

    /// Stops playback, records final progress into SQLite, and clears the Apple Handoff broadcast.
    public func stopPlayback() {
        if let catalogId = currentPlaybackCatalogId,
           let episode = currentPlaybackEpisode,
           let engine {
            let dur = Int64(playerController.duration)
            let rawStop = Int64(playerController.currentTime)
            let stopTime = dur > 0 ? min(rawStop, dur) : rawStop
            try? engine.recordProgress(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episodeNumber: episode,
                stopTime: stopTime,
                duration: dur
            )
        }
        self.activeStreamURL = nil
        self.currentPlaybackCatalogId = nil
        self.currentPlaybackEpisode = nil
        self.currentPlaybackTitle = nil
        self.lastRecordedSecond = -1
        ContinuityManager.shared.stopAdvertising()

        Task {
            await loadHistory()
            if let currentDetails = selectedMediaDetails {
                await loadDetail(id: currentDetails.id, isManga: Self.isMangaFormat(currentDetails.format))
            }
        }
    }

    /// Handles dismissal hierarchy for ESC key:
    /// 1. CommandPalette (topmost overlay)
    /// 2. PlayerView (modal video playback)
    /// 3. MangaReaderView (modal manga reading)
    /// 4. MediaDetailView (detail page)
    @discardableResult
    public func handleEscapeKey() -> Bool {
        if paletteOpen {
            paletteOpen = false
            return true
        }
        if activeStreamURL != nil {
            stopPlayback()
            return true
        }
        if activeReadingSession != nil {
            closeReader()
            return true
        }
        if selectedMediaDetails != nil {
            closeDetail()
            return true
        }
        return false
    }

    /// Navigates to a specific section, closing any active playback, reader, or detail views.
    public func navigate(to section: SidebarView.NavSection) {
        stopPlayback()
        closeReader()
        clearDetail()
        currentNavSection = section
    }

    /// Fills the home page.
    ///
    /// Everything here is real. This used to search for the literal string
    /// "Frieren" and then invent an Up Next entry and a week of airing times
    /// ("Monday, September 4", "in 2h 15m") out of the results — which made
    /// the app look populated in a screenshot while showing nothing a user
    /// could act on, and made the Schedule view a fiction.
    private func loadInitialCatalog() async {
        guard let engine else { return }

        let trending = (try? await engine.trending(mediaType: "ANIME", format: nil, limit: 24)) ?? []
        trendingItems = trending.map(Self.card)

        let watching = (try? await engine.userList(status: "CURRENT", mediaType: "ANIME")) ?? []
        let profile = try? await engine.viewerProfile()
        isSignedIn = profile != nil
        viewer = profile
        watchingItems = watching.map(Self.card)

        upNextItems = watching.compactMap { s in
            let progress = Int(s.progress ?? 0)
            let total = Int(s.episodes ?? 0)
            let released = s.nextEpisode.map { Int($0) - 1 } ?? total
            return UpNextQueueView.QueueEntry(
                id: s.catalogId,
                title: s.title,
                thumbnailURL: URL(string: s.coverImage),
                nextEpisodeOrChapter: progress + 1,
                totalCount: total,
                progressPercent: total > 0 ? Double(progress) / Double(total) * 100 : 0,
                watchedTimeAgo: s.updatedAt.map(Self.relativeTime),
                hasNewEpisode: progress < released,
                unit: "EP"
            )
        }

        // Only shows AniList actually has an airing time for. A show with no
        // `nextAiringEpisode` is not on the schedule; it is finished, or
        // between seasons.
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
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
}
