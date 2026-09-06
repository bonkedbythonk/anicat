import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

@Observable
public final class AppModel: @unchecked Sendable {
    // Progress/Discord IPC calls (recordProgress, discordSetPresence,
    // discordClearPresence) are synchronous FFI writes that can stall for as
    // long as SQLite or Discord's own read side does — see the notes on
    // `handlePlaybackPositionChange` and `stopPlayback`. Each call used to
    // get its own unstructured `Task.detached`, which fixed the main-thread
    // freeze but not ordering: a per-second tick spawns roughly one of these
    // a second, and if an earlier tick's task is the one that stalls, a
    // later tick's task can finish first and then get overwritten when the
    // stalled one finally runs — regressing the resume position in SQLite to
    // an earlier point than where the viewer actually stopped. A serial
    // queue keeps every write off the main actor while guaranteeing they
    // land in the order they were issued.
    let engineIOQueue = DispatchQueue(label: "com.anicat.engine-io", qos: .utility)

    private var activeDetailTask: Task<Void, Never>?
    private var activeDetailExtrasTask: Task<Void, Never>?
    private var activeLibraryTask: Task<Void, Never>?
    private var activeSearchTask: Task<Void, Never>?
    public private(set) var loadingCatalogId: Int64?

    public var engine: AnicatEngine?
    public var isInitialized = false
    public var isLoading = false
    public var errorMessage: String?
    /// Set alongside `errorMessage` when the failure is something retrying
    /// might actually fix (a resolve timeout, a candidate that turned out
    /// dead) — the error banner shows a Retry button when this is non-nil.
    /// `nil` for errors retrying can't help (a malformed URL, a genuinely
    /// missing title), so the banner doesn't offer a button that would just
    /// fail the same way again.
    public var errorRetryAction: (() -> Void)?
    public var isAniListDown: Bool = false
    private(set) var aniListFailureTimestamps: [Date] = []
    let aniListFailureThreshold = 3
    let aniListFailureWindow: TimeInterval = 30

    func isNetworkError(_ error: Error) -> Bool {
        if let anicatError = error as? AnicatError {
            if case .Network = anicatError {
                return true
            }
        }
        if error is URLError {
            return true
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    // `refreshAll` fans out into concurrent `async let` children (catalog,
    // library, shelves, history), and more than one of them can land here on
    // AniList success/failure at once. Neither `self` nor this method is
    // actor-isolated, so without pinning the mutation to one actor two
    // children racing on `aniListFailureTimestamps`/`isAniListDown` is a real
    // data race on that Array, not just a redundant write.
    @MainActor func recordAniListFailure(_ error: Error, at date: Date = Date()) {
        guard isNetworkError(error) else { return }

        // Rust client tags GraphQL downtime responses with an explicit prefix
        if let anicatError = error as? AnicatError, case .Network(let msg) = anicatError {
            if msg.contains("anilist_down:") {
                isAniListDown = true
                return
            }
        }

        aniListFailureTimestamps.append(date)
        aniListFailureTimestamps.removeAll { date.timeIntervalSince($0) > aniListFailureWindow }
        if aniListFailureTimestamps.count >= aniListFailureThreshold {
            isAniListDown = true
        }
    }

    @MainActor func recordAniListSuccess() {
        aniListFailureTimestamps.removeAll()
        if isAniListDown {
            isAniListDown = false
        }
    }

    // Active Navigation
    public var currentNavSection: SidebarView.NavSection = .upNext
    public var paletteOpen = false
    public var shortcutsOpen = false
    /// First-launch screen (`OnboardingView`). Shown once, on a launch with
    /// no AniList token; `anicat_onboarding_seen` remembers the dismissal
    /// and Settings' "Reset onboarding" clears it.
    public var onboardingOpen = false
    static let onboardingSeenKey = "anicat_onboarding_seen"

    public func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: Self.onboardingSeenKey)
        withAnimation(.smooth(duration: 0.4)) {
            onboardingOpen = false
        }
    }
    public var searchQuery: String = ""
    public var selectedMediaDetails: HeroBanner.Details?
    public var isDetailLoading: Bool = false
    private var activePrefetches: Set<Int64> = []
    // Which specific card triggered the currently-open (or opening) detail
    // page, as "<shelf>:<catalogId>" — e.g. "watching:12345". A bare
    // catalog id isn't enough: the same show can be visible in more than one
    // shelf at once (Up Next and Watching both show it), and tagging every
    // instance with that id for matchedGeometryEffect gave two "source"
    // views for one id — SwiftUI's behavior there is undefined, and that's
    // what caused both the missing Up Next posters and the open/close
    // jitter the first time this was tried. Nil for any open that didn't
    // come from a card (a relation/recommendation click inside the detail
    // page, schedule, etc.) — those get a plain fade, no morph.
    public var openingDetailSourceKey: String?
    public var selectedEpisodes: [MediaDetailView.EpisodeItem] = []
    public var selectedMangaChapters: [MediaDetailView.MangaChapterItem] = []
    public var selectedCharacters: [MediaDetailView.CharacterItem] = []
    public var selectedRelations: [MediaDetailView.RelationItem] = []
    public var selectedRecommendations: [MediaDetailView.RecommendationItem] = []
    public var selectedDiscussions: [MediaDetailView.DiscussionItem] = []
    public var activeStreamURL: URL?
    /// Backgrounds the full-screen `PlayerView` without touching playback —
    /// mpv keeps running (audio, position tracking, everything) exactly as
    /// `pause()`/`stopPlayback()` don't. Real system Picture-in-Picture
    /// (a floating window outside the app, works even if Anicat itself is
    /// hidden) isn't something mpv's Metal rendering path supports without
    /// bridging its frames into an `AVSampleBufferDisplayLayer` for AVKit's
    /// PIP APIs — a much larger, separate undertaking. This gets the part
    /// that was actually broken: navigating anywhere else in the app (the
    /// menu bar's Settings item included) while a video is open used to be
    /// impossible, since `PlayerView` rendered unconditionally over
    /// everything whenever `activeStreamURL` was non-nil regardless of which
    /// section was actually selected underneath.
    public var isPlayerMinimized: Bool = false

    // PlayerController & Playback Tracking
    public let playerController = PlayerController()
    /// The system Now Playing tile and the media keys behind it. Fed from
    /// the same title/episode/cover data Discord presence already gets.
    let nowPlaying = NowPlayingBridge()
    /// Keeps the display (and so the system) from idling out while an
    /// episode plays. See `SleepBlocker` for what a laptop does without it.
    let sleepBlocker = SleepBlocker.system()
    /// Cover of the playing title when it came from the detail fetch in
    /// `ensurePlaybackEpisodes` rather than an open page or a loaded shelf:
    /// a play from the Up Next shelf opens no page, and the shelf's
    /// `QueueEntry` is not one of the arrays `syncKnownTitles` reads.
    private var playbackCoverURL: URL?
    public var currentPlaybackCatalog: FfiCatalog = .anilist
    public var currentPlaybackCatalogId: Int64?
    public var currentPlaybackEpisode: Int64?
    public var currentPlaybackTitle: String?
    /// Set for the duration of the `resolveStream` FFI call inside
    /// `resolveAndPlay` — non-nil is what the loading overlay uses to show
    /// "Finding a stream… Ns" (and a Cancel button) instead of a bare
    /// spinner with no indication of what's happening or how long it's been.
    public var resolveStartedAt: Date?
    /// Cancelling this aborts whichever `resolveAndPlay` call is currently
    /// in flight — the Cancel button's target. `resolveStream` itself may
    /// keep running on the Rust side after this (the FFI call isn't
    /// preemptible mid-flight), same trade-off `torrent/search.rs` already
    /// makes when it abandons AnimeTosho's grace period rather than wait for
    /// it: abandoning the *wait* is what matters to the viewer, not whether
    /// the orphaned work on the other side of the FFI boundary stops
    /// instantly too.
    public var activeResolveTask: Task<Void, Never>?

    public func cancelResolve() {
        activeResolveTask?.cancel()
        activeResolveTask = nil
        resolveStartedAt = nil
        isLoading = false
    }
    private var lastRecordedSecond: Int64 = -1
    /// Separate from `lastRecordedSecond`'s once-a-second gate: pausing and
    /// resuming inside the same second must still flip Discord's "(Paused)"
    /// label immediately rather than waiting for the next second to tick
    /// over, since `pause()`/`play()` re-report the same truncated position.
    private var lastDiscordPaused: Bool?
    // Guards the AniList auto-advance below to one attempt per episode
    // rather than once a second for the rest of the episode once past 85%.
    private var hasAdvancedAniListForCurrentEpisode = false
    // Same idea, for auto-play-next: one attempt per episode once past the
    // near-end line below.
    private var hasAutoAdvancedEpisode = false

    // These four dedup flags only mean anything scoped to "the episode
    // currently loaded" — `resolveAndPlay` resets them for the episode
    // starting, `stopPlayback` for the one ending. They used to be reset by
    // hand at each site, and `stopPlayback` had dropped
    // `hasAdvancedAniListForCurrentEpisode` from its half (masked in
    // practice only because the next `resolveAndPlay` always resets it
    // before it's read again). One call at each site makes "new episode
    // session = all four reset" structural instead of something to remember
    // per flag.
    private func resetPerEpisodeDedupState(discordPaused: Bool?) {
        lastRecordedSecond = -1
        lastDiscordPaused = discordPaused
        hasAdvancedAniListForCurrentEpisode = false
        hasAutoAdvancedEpisode = false
        hasPreloadedNextEpisode = false
    }
    // One speculative resolve of the next episode per episode session, see
    // `nextEpisodePreloadPct`.
    private var hasPreloadedNextEpisode = false
    // Where in the current episode the next one is resolved ahead of time.
    // Far enough from the end that a cold resolve (search, race, pre-buffer;
    // 2 to 10 s, more on a slow swarm) has landed before auto-next fires at
    // `autoAdvanceRemainingSeconds`, and past the point where most viewers
    // who are going to stop have stopped, so the second download slot is
    // not spent on episodes nobody reaches. On a 24 min episode this is
    // 6 min of headroom.
    private static let nextEpisodePreloadPct: Double = 75.0
    // Same 85% line the Tauri build's `commands/playback.rs` uses for
    // "watched" — kept in sync with it, not derived from anything else.
    private static let watchedThresholdPct: Double = 85.0
    // How close to the real end counts as "the episode is over" for
    // auto-play-next. `eof-reached`/`playback-restart` are the obvious
    // signals but don't fire reliably against a torrent stream — seeking
    // into the tail of a file whose last pieces aren't downloaded yet leaves
    // mpv sitting in `seeking=true` indefinitely rather than reaching EOF
    // (documented against the other build's mpv integration; same swarm
    // underneath here). Watching position against duration, the same fix
    // used there, works regardless.
    private static let autoAdvanceRemainingSeconds: Double = 2.0

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
    // `didSet` keeps `knownTitles` a plain stored read instead of a fan-out
    // computed property: HistoryView's body used to read all six arrays
    // below every time it rendered, so any of them changing while History
    // was the open tab (a background refreshAll, an unrelated search)
    // re-evaluated the whole view and rebuilt this dict from scratch.
    public var watchingItems: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var trendingItems: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var searchResults: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    // Pagination for `search`: `search` itself doesn't get told AniList's
    // `hasNextPage` (the FFI call returns a bare list), so "more pages
    // exist" is inferred from a full page having come back — a page short of
    // 25 is necessarily the last one.
    public var searchCurrentPage: Int32 = 1
    public var searchHasMorePages: Bool = true
    public var isLoadingMoreSearchResults: Bool = false

    /// The Search tab's "Discover" section — deliberately separate storage
    /// from `trendingItems`, which the *Home* page's own trending shelf owns.
    /// It used to just read `trendingItems` directly, which is why switching
    /// Search's Anime/Manga/Novel toggle while browsing (no typed query, no
    /// filter) never changed anything: `trendingItems` is always anime,
    /// always the same fixed 24 items `loadTrending()` fetched once for Home,
    /// with no pagination at all. This is fetched through the same paginated
    /// `searchCatalog` path `search()` uses (an empty query + `TRENDING_DESC`
    /// sort), just kept in its own state so it doesn't collide with a real
    /// typed search's `searchResults`.
    public var searchDiscoverItems: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var searchDiscoverPage: Int32 = 1
    public var searchDiscoverHasMorePages: Bool = true
    public var isLoadingMoreSearchDiscover: Bool = false
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
    public var libraryItems: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var libraryStatus: String = "CURRENT"
    public var libraryType: String = "ANIME"
    public var mangaTrending: [MediaCard.Item] = []
    public var mangaReading: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var novelTrending: [MediaCard.Item] = []
    public var novelReading: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var viewer: ViewerProfile?
    public var activity: [ActivityRow] = []

    /// Titles for ids the History log has rows for, gathered from every list
    /// already loaded. The registry stores a `catalog_id` and nothing else —
    /// it has no idea what a show is called — so the name has to come from
    /// whatever the catalog views have already fetched. Maintained by
    /// `syncKnownTitles()` on write rather than rebuilt from all six source
    /// arrays on every read.
    public private(set) var knownTitles: [Int64: String] = [:]
    /// Same sourcing as `knownTitles`, for the Now Playing artwork of a
    /// title played without its page open.
    public private(set) var knownCovers: [Int64: URL] = [:]

    private func syncKnownTitles() {
        var titles: [Int64: String] = [:]
        var covers: [Int64: URL] = [:]
        for item in watchingItems + trendingItems + libraryItems + mangaReading + novelReading + searchResults {
            titles[item.id] = item.title
            if let cover = item.coverImageURL { covers[item.id] = cover }
        }
        knownTitles = titles
        knownCovers = covers
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
        playerController.onPlayingStateChange = { [weak self] _ in
            self?.syncPlaybackSession()
        }
        nowPlaying.attach(to: playerController)
        playerController.onPlaybackStopped = { [weak self] in
            self?.stopPlayback()
        }
        playerController.onNextEpisode = { [weak self] in
            Task { await self?.playAdjacentEpisode(offset: 1) }
        }
        playerController.onPreviousEpisode = { [weak self] in
            Task { await self?.playAdjacentEpisode(offset: -1) }
        }
        playerController.onSelectEpisode = { [weak self] number in
            Task { await self?.playSelectedEpisode(number) }
        }
    }

    /// Jumps straight to an arbitrary episode number from the player's
    /// episode list, rather than stepping one at a time like
    /// `playAdjacentEpisode`.
    /// The episode list of the title that is *playing*, as opposed to
    /// `selectedEpisodes`, which belongs to whatever detail page is open.
    /// The two used to be one array, on the assumption that the playing
    /// title is always the open page. It is not: a play from the Up Next
    /// shelf opens no page at all (so next/prev, auto-next and the preload
    /// had an empty list and did nothing), and the mini-player lets a
    /// different title's page open mid-episode (so "next" looked the current
    /// episode number up in another show's list).
    public private(set) var playbackEpisodes: [MediaDetailView.EpisodeItem] = []
    private var playbackEpisodesCatalogId: Int64?

    static func episodeItems(from d: MediaDetail) -> [MediaDetailView.EpisodeItem] {
        d.episodes.map { e in
            MediaDetailView.EpisodeItem(
                id: Int64(e.number),
                number: Int(e.number),
                title: e.title,
                thumbnailURL: e.thumbnail.flatMap(URL.init(string:)),
                isWatched: e.isWatched,
                progressPercent: e.progressPercent,
                synopsis: e.synopsis,
                airDate: e.airDate,
                runtimeMinutes: e.runtimeMinutes.map(Int.init)
            )
        }
        .sorted { $0.number < $1.number }
    }

    /// Points `playbackEpisodes` at the right list for `catalogId`: the open
    /// page's list when it is the same title, otherwise a fetch (served from
    /// the engine's hour-long detail cache on any title opened recently).
    /// The fetch runs alongside the resolve rather than ahead of it, and
    /// the navigation state is recomputed when it lands.
    private func ensurePlaybackEpisodes(for catalogId: Int64, engine: AnicatEngine) {
        if selectedMediaDetails?.id == catalogId, !selectedEpisodes.isEmpty {
            playbackEpisodes = selectedEpisodes
            playbackEpisodesCatalogId = catalogId
            return
        }
        guard playbackEpisodesCatalogId != catalogId || playbackEpisodes.isEmpty else { return }
        playbackEpisodes = []
        playbackEpisodesCatalogId = catalogId
        playbackCoverURL = nil
        Task { [weak self] in
            guard let detail = try? await engine.mediaDetail(catalogId: catalogId, isManga: false) else { return }
            guard let self, self.currentPlaybackCatalogId == catalogId else { return }
            self.playbackEpisodes = Self.episodeItems(from: detail)
            self.playbackCoverURL = URL(string: detail.coverImage)
            self.updateEpisodeNavigationState()
        }
    }

    public func playSelectedEpisode(_ number: Int) async {
        guard let catalogId = currentPlaybackCatalogId else { return }
        guard playbackEpisodes.contains(where: { $0.number == number }) else { return }
        do {
            _ = try await resolveAndPlay(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: Int64(number)
            )
        } catch {
            errorMessage = "Failed to load episode \(number): \(error.localizedDescription)"
        }
    }

    /// Advances or rewinds one entry in `playbackEpisodes` from whatever is
    /// currently playing.
    public func playAdjacentEpisode(offset: Int) async {
        guard let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode else { return }
        let sorted = playbackEpisodes
        guard let index = sorted.firstIndex(where: { $0.number == Int(episode) }) else { return }
        let targetIndex = index + offset
        guard sorted.indices.contains(targetIndex) else { return }
        let target = sorted[targetIndex]
        do {
            _ = try await resolveAndPlay(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: Int64(target.number)
            )
        } catch {
            errorMessage = "Failed to load episode \(target.number): \(error.localizedDescription)"
        }
    }

    /// Recomputes whether the player's next/prev buttons have anywhere to
    /// go, against `playbackEpisodes` — called after every episode change
    /// and whenever that list arrives, since it (and the current position
    /// within it) is the only thing that decides it.
    private func updateEpisodeNavigationState() {
        let sorted = playbackEpisodes
        playerController.episodeList = sorted
        guard let episode = currentPlaybackEpisode else {
            playerController.hasNextEpisode = false
            playerController.hasPreviousEpisode = false
            return
        }
        guard let index = sorted.firstIndex(where: { $0.number == Int(episode) }) else {
            playerController.hasNextEpisode = false
            playerController.hasPreviousEpisode = false
            return
        }
        playerController.hasNextEpisode = sorted.indices.contains(index + 1)
        playerController.hasPreviousEpisode = sorted.indices.contains(index - 1)
        refreshNowPlayingMetadata()
    }

    /// Republishes the Now Playing tile from what is known right now. Runs
    /// with every navigation-state recompute because the two late arrivals
    /// (the episode title from `playbackEpisodes`, the cover from the
    /// detail fetch) both land through `updateEpisodeNavigationState`;
    /// publishing once at play time showed a bare episode number and no
    /// artwork for anything started from the Up Next shelf.
    private func refreshNowPlayingMetadata() {
        guard activeStreamURL != nil, let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode else { return }
        let track = NowPlayingBridge.Track(
            title: currentPlaybackTitle ?? playerController.title,
            episodeNumber: Int(episode),
            episodeTitle: playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        )
        let pageCover = selectedMediaDetails?.id == catalogId ? selectedMediaDetails?.coverURL : nil
        nowPlaying.setTrack(
            track,
            elapsed: playerController.currentTime,
            duration: playerController.duration,
            rate: playerController.isPlaying ? playerController.playbackRate : 0,
            coverURL: pageCover ?? playbackCoverURL ?? knownCovers[catalogId]
        )
        nowPlaying.setNavigation(
            hasNext: playerController.hasNextEpisode,
            hasPrevious: playerController.hasPreviousEpisode
        )
    }

    /// The one place that follows "is an episode playing right now": every
    /// `isPlaying` edge (`PlayerController.onPlayingStateChange`), each new
    /// stream in `resolveAndPlay`, and `stopPlayback`. Anything whose
    /// lifetime is "while video is on" hangs off this so a pause, a
    /// transition and a close cannot each forget one of them.
    private func syncPlaybackSession() {
        guard activeStreamURL != nil else {
            sleepBlocker.release()
            nowPlaying.clear()
            return
        }
        if playerController.isPlaying, let episode = currentPlaybackEpisode {
            let title = currentPlaybackTitle ?? playerController.title
            sleepBlocker.hold(reason: "Anicat is playing \(title), episode \(episode)")
        } else {
            // Paused is idle as far as the viewer is concerned: a laptop
            // left on a paused frame should sleep like any other.
            sleepBlocker.release()
        }
        nowPlaying.updateProgress(
            elapsed: playerController.currentTime,
            duration: playerController.duration,
            rate: playerController.isPlaying ? playerController.playbackRate : 0
        )
    }

    /// Initializes the headless Rust engine and opens the SQLite registry.
    public func initialize(anilistToken: String? = nil, tmdbKey: String? = nil) async {
        guard engine == nil else { return }

        // Paints last-known home state before the engine has even finished
        // constructing, and skips the launch spinner entirely for a relaunch
        // that has one. `refreshAll` below still runs and replaces it.
        let cachedHome = HomeCache.load()
        if let cachedHome { applyHomeCache(cachedHome) }
        isLoading = cachedHome == nil
        defer { isLoading = false }

        do {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dataDir = appSupport.appendingPathComponent("Anicat", isDirectory: true)
            try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)

            // Zero-Login iCloud Sync: retrieve token from iCloud Keychain if not explicitly provided
            let token = anilistToken ?? iCloudSyncService.shared.getAniListToken()

            let coreEngine = try AnicatEngine(
                dataDir: dataDir.path,
                anilistToken: token,
                tmdbKey: tmdbKey
            )
            self.engine = coreEngine
            if let token, !token.isEmpty {
                self.isSignedIn = true
                // A token already in the Keychain means the first run
                // happened on some earlier build; nothing left to onboard.
                UserDefaults.standard.set(true, forKey: Self.onboardingSeenKey)
            } else if !UserDefaults.standard.bool(forKey: Self.onboardingSeenKey) {
                self.onboardingOpen = true
            }

            let port = try await coreEngine.streamPort()
            print("Anicat Rust Engine ready! Dynamic stream server on port: \(port)")
            self.isInitialized = true

            // The librqbit session and its DHT bootstrap, paid now instead of
            // on the first press of Play. `resolve` logs `session=...ms`;
            // before this it was the whole cold-start cost of the first play
            // of every app session, after it that number is ~0.
            Task.detached(priority: .utility) { await coreEngine.warmUp() }

            // A no-op when Discord isn't running — the IPC connect just fails
            // and logs a warning on the Rust side.
            coreEngine.discordConnect()

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
            //
            // Skipped entirely when the cache just painted the screen and is
            // still fresh: a relaunch-heavy stretch (testing, crash-restart
            // loops) used to pay for a full ~5-call AniList refresh on every
            // single launch regardless of how recently the last one landed,
            // which is exactly the kind of repeated traffic that queues up
            // behind AniList's own proactive rate-limit backoff and starts
            // surfacing as data that just stops loading.
            let homeCacheAge = HomeCache.ageInSeconds()
            let homeCacheIsFresh = cachedHome != nil && homeCacheAge.map { $0 < Self.detailFreshnessWindow } == true
            if !homeCacheIsFresh {
                await refreshAll(showLoading: cachedHome == nil)
            }
        } catch {
            self.errorMessage = "Failed to start Anicat Engine: \(error.localizedDescription)"
            print(errorMessage!)
        }
    }

    private func applyHomeCache(_ snapshot: HomeCache.Snapshot) {
        trendingItems = snapshot.trending
        watchingItems = snapshot.watching
        upNextItems = snapshot.upNext
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
    }

    private func persistHomeCache() {
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
            seasonal: seasonalItems
        ))
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

        let planning = await planningTask
        let newlyReleasing = (try? await newlyReleasingTask) ?? []
        let seasonal = (try? await seasonalTask) ?? []

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
    /// One entry per detail page navigated away from (relation click, related
    /// title, up-next card) while another was already open — mirrors the
    /// web's `detailStack`. Without it, "back" (swipe, the X button, mouse
    /// back button) always landed on the home screen: opening season 2 from
    /// season 1's detail page overwrote `selectedMediaDetails` in place, so
    /// there was nothing to return to except nil.
    private var detailHistory: [(id: Int64, isManga: Bool, tab: MediaDetailView.DetailTab?)] = []

    /// The mirror image of `detailHistory`: entries popped by `closeDetail()`
    /// land here so a forward swipe/gesture can redo them, browser-style.
    /// Any *fresh* navigation (a new relation click, not a back/forward step)
    /// clears it — once you branch off the path you were on, "forward" no
    /// longer means anything.
    private var detailForwardStack: [(id: Int64, isManga: Bool, tab: MediaDetailView.DetailTab?)] = []

    /// Kept live by `MediaDetailView`'s own tab-change callback so that
    /// whichever navigation site pushes onto `detailHistory`/`detailForwardStack`
    /// next can capture "what tab was the page I'm leaving on". Without this,
    /// `MediaDetailView` mounts fresh (it's `.id(details.id)`-keyed, so its own
    /// `@State selectedTab` can't survive a title change) every time you
    /// navigate to a different title and back, and always fell back to its
    /// default tab — clicking a relation's manga, then going back to the
    /// anime, always landed back on Episodes even if Related was open.
    public var currentDetailTab: MediaDetailView.DetailTab?

    /// Set right before a back/forward navigation reloads the page, so
    /// `MediaDetailView`'s init can restore the tab that was open the last
    /// time this title was visited instead of recomputing its usual default.
    public private(set) var restoredDetailTab: MediaDetailView.DetailTab?

    /// Opens the detail page for a title, fetching real AniList metadata and real streaming/registry episodes.
    public func openDetail(id: Int64, title: String? = nil, coverURL: URL? = nil, isManga: Bool = false) async {
        // If already loading or displaying this exact title, do not re-trigger or cancel the existing in-flight task
        if loadingCatalogId == id || (selectedMediaDetails?.id == id && !isDetailLoading) {
            if let task = activeDetailTask {
                await task.value
            }
            return
        }

        // Only save current title to history if it's a different title and not a provisional loading placeholder
        if let current = selectedMediaDetails, current.id != id, !isDetailLoading {
            detailHistory.append((id: current.id, isManga: Self.isMangaFormat(current.format), tab: currentDetailTab))
        }
        detailForwardStack = []
        // A fresh forward navigation (a relation click, not a back/forward
        // step) should use the new page's own default tab, not whatever a
        // previous back-step happened to leave here.
        restoredDetailTab = nil
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        loadingCatalogId = id
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.loadDetail(id: id, title: title, coverURL: coverURL, isManga: isManga)
        }
        activeDetailTask = task
        await task.value
    }

    /// Goes back one level in `detailHistory`, or all the way home when it's
    /// empty. Shared by the swipe-back gesture, the detail page's close
    /// button, and the mouse back button/Alt+Left — matching the web, where
    /// all three call the same `closeDetail`.
    public func closeDetail() {
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        guard let previous = detailHistory.popLast() else {
            // Dropping all the way out to home clears the forward stack —
            // home is the root feed, not a detail page, so forward gestures
            // must never hijack home-screen shelf scrolling or reopen details.
            detailForwardStack = []
            // Animate `selectedMediaDetails = nil` alongside `openingDetailSourceKey = nil`
            // in the same transaction so MediaDetailView dissolves away smoothly over
            // the persistent sectionContent underneath, avoiding an un-animated layout pass or hard cut.
            withAnimation(.easeInOut(duration: 0.32)) {
                openingDetailSourceKey = nil
                selectedMediaDetails = nil
            }
            return
        }
        // Stepping back to a previous entry in `detailHistory`, not a card
        // tap — no source card to morph from, so this is a plain fade.
        openingDetailSourceKey = nil
        if let current = selectedMediaDetails, !isDetailLoading {
            detailForwardStack.append((id: current.id, isManga: Self.isMangaFormat(current.format), tab: currentDetailTab))
        }
        restoredDetailTab = previous.tab
        // Load cached snapshot immediately so the back transition renders
        // synchronously without waiting for an async Task to start up.
        if let cached = DetailCache.load(id: previous.id, isManga: previous.isManga) {
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = cached.episodes
                selectedMangaChapters = cached.mangaChapters
                selectedRelations = cached.relations
                selectedRecommendations = cached.recommendations
                selectedCharacters = cached.characters
                selectedDiscussions = cached.discussions
                selectedMediaDetails = cached.details
            }
        }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.loadDetail(id: previous.id, isManga: previous.isManga)
        }
        activeDetailTask = task
    }

    /// Redoes one level in `detailForwardStack` — the swipe-forward gesture's
    /// and the mouse forward button's counterpart to `closeDetail()`. A no-op
    /// when there's nothing to redo (browser back/forward buttons work the
    /// same way: disabled/inert past the end of either stack).
    public var canGoForward: Bool { !detailForwardStack.isEmpty }

    public func goForwardDetail() {
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        guard let next = detailForwardStack.popLast() else { return }
        openingDetailSourceKey = nil
        if let current = selectedMediaDetails, !isDetailLoading {
            detailHistory.append((id: current.id, isManga: Self.isMangaFormat(current.format), tab: currentDetailTab))
        }
        restoredDetailTab = next.tab
        // Load cached snapshot immediately so the forward transition renders
        // synchronously without waiting for an async Task to start up.
        if let cached = DetailCache.load(id: next.id, isManga: next.isManga) {
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = cached.episodes
                selectedMangaChapters = cached.mangaChapters
                selectedRelations = cached.relations
                selectedRecommendations = cached.recommendations
                selectedCharacters = cached.characters
                selectedDiscussions = cached.discussions
                selectedMediaDetails = cached.details
            }
        }
        let task = Task { [weak self] () -> Void in
            guard let self else { return }
            await self.loadDetail(id: next.id, isManga: next.isManga)
        }
        activeDetailTask = task
    }

    public static func isMangaFormat(_ format: String?) -> Bool {
        format == "MANGA" || format == "NOVEL" || format == "ONE_SHOT"
    }

    /// Closes the detail page and drops the whole `detailHistory`, unlike
    /// `closeDetail()` which pops one level. Use this when leaving the detail
    /// page for somewhere else entirely (switching sidebar sections), where
    /// there's nothing to go "back" to.
    public func clearDetail() {
        activeDetailTask?.cancel()
        activeDetailExtrasTask?.cancel()
        withAnimation(.easeInOut(duration: 0.32)) {
            openingDetailSourceKey = nil
            selectedMediaDetails = nil
        }
        detailHistory = []
        detailForwardStack = []
    }

    /// Fetches and sets the detail page in place, without touching `detailHistory`.
    /// Used by `openDetail`/`closeDetail` above, and by any caller (like the
    /// post-playback refresh) that needs to reload the currently open title
    /// rather than navigate to a new one.
    /// How long a cached detail snapshot is trusted before `loadDetail` pays
    /// for a fresh AniList round trip again. Testing/dev cycles that relaunch
    /// or reopen the same title over and over used to fire the full fetch
    /// every single time regardless of how recently it had already landed,
    /// which is exactly the kind of repeated, low-value traffic that queues
    /// up behind AniList's own proactive rate-limit backoff (see
    /// `anilist/client.rs`) and starts surfacing as data that just stops
    /// loading. `forceRefresh` bypasses this for callers that know the data
    /// really did just change (a list-entry mutation, mark-watched).
    static let detailFreshnessWindow: TimeInterval = 180

    private func loadDetail(id: Int64, title: String? = nil, coverURL: URL? = nil, isManga: Bool, forceRefresh: Bool = false) async {
        guard let engine, !Task.isCancelled else { return }
        loadingCatalogId = id
        // Episode numbers repeat across titles, so a stale entry here would
        // show as "downloaded"/"downloading" on the wrong show's episode 1
        // the moment the detail page switches.
        downloadStates = [:]

        // Read before `.load()` touches the file's mtime for its own LRU
        // purposes, or every read would measure as "just saved".
        let cacheAge = DetailCache.ageInSeconds(id: id, isManga: isManga)

        // A cached snapshot renders immediately and the real fetch below
        // still runs and replaces it — this only skips the blank spinner,
        // never the refresh. Without it, every open (even a title seen many
        // times) paid AniList's full round trip up front, and a session
        // that had already made a few other AniList calls could be sitting
        // behind that client's own proactive rate-limit backoff on top of
        // it (see `anilist/client.rs`) — invisible as a "why is this only
        // sometimes slow" spinner instead of the load it actually was.
        let cached = DetailCache.load(id: id, isManga: isManga)
        if let cached {
            isDetailLoading = false
            // Explicit for the same reason as `closeDetail()`: an
            // `.animation(value:)` modifier watching this `@Observable`
            // property doesn't reliably animate its insertion transition.
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = cached.episodes
                selectedMangaChapters = cached.mangaChapters
                selectedRelations = cached.relations
                selectedRecommendations = cached.recommendations
                selectedCharacters = cached.characters
                selectedDiscussions = cached.discussions
                selectedMediaDetails = cached.details
            }
        } else {
            // Optimistic immediate transition: render provisional details and skeletons in 0ms!
            let provisionalTitle = title ?? knownTitles[id] ?? "Loading..."
            let provisional = HeroBanner.Details(
                id: id,
                title: provisionalTitle,
                coverURL: coverURL,
                format: isManga ? "MANGA" : "ANIME"
            )
            isDetailLoading = true
            withAnimation(.easeInOut(duration: 0.32)) {
                selectedEpisodes = []
                selectedMangaChapters = []
                selectedRelations = []
                selectedRecommendations = []
                selectedCharacters = []
                selectedDiscussions = []
                selectedMediaDetails = provisional
            }
        }

        // Cache is recent enough to trust outright — skip the network round
        // trip entirely rather than "render cache, then sync anyway".
        if !forceRefresh, cached != nil, let cacheAge, cacheAge < Self.detailFreshnessWindow {
            loadingCatalogId = nil
            isDetailLoading = false
            return
        }

        defer {
            isLoading = false
            if loadingCatalogId == id {
                loadingCatalogId = nil
            }
            if self.selectedMediaDetails?.id == id && self.isDetailLoading {
                self.isDetailLoading = false
            }
        }
        do {
            if Task.isCancelled { return }
            let d: MediaDetail
            if let primary = try? await engine.mediaDetail(catalogId: id, isManga: isManga) {
                d = primary
            } else {
                if Task.isCancelled { return }
                d = try await engine.mediaDetail(catalogId: id, isManga: !isManga)
            }
            if Task.isCancelled { return }
            let episodes = Self.episodeItems(from: d)
            var chapters: [MediaDetailView.MangaChapterItem] = []
            // `mangaChapters` only ever searches MangaDex, which carries
            // manga/manhwa/manhua — never prose light novels. Sending a
            // NOVEL-format title through it wasn't just returning nothing:
            // MangaDex's own title search would occasionally match an
            // unrelated manga with a similar name and hand back ITS
            // chapters, which the reader then opened as if they were the
            // novel's own pages. There is no light-novel content source
            // wired up in the native app yet — see `MediaDetailView`'s
            // `.manga` tab case, which shows a distinct "not available"
            // empty state for `format == "NOVEL"` rather than the generic
            // "no chapters found" a real manga search failure gets.
            if d.format != "NOVEL", isManga || d.chapterCount != nil || Self.isMangaFormat(d.format) {
                if Task.isCancelled { return }
                let fetched = (try? await engine.mangaChapters(detail: d)) ?? []
                chapters = fetched.map {
                    MediaDetailView.MangaChapterItem(id: $0.id, number: $0.number, title: $0.title)
                }
            }
            if Task.isCancelled { return }

            let relations = d.relations.map { r in
                MediaDetailView.RelationItem(
                    id: r.catalogId,
                    relationType: r.relationType,
                    title: r.title,
                    format: r.format,
                    coverURL: URL(string: r.coverImage),
                    status: r.status,
                    averageScore: r.averageScore.map(Int.init)
                )
            }

            let recommendations = d.recommendations.map { rec in
                MediaDetailView.RecommendationItem(
                    id: rec.catalogId,
                    title: rec.title,
                    format: rec.format,
                    coverURL: URL(string: rec.coverImage),
                    averageScore: rec.averageScore.map(Int.init),
                    rating: rec.rating.map(Int.init)
                )
            }

            self.selectedEpisodes = episodes
            if currentPlaybackCatalogId == id {
                playbackEpisodes = episodes
                playbackEpisodesCatalogId = id
                updateEpisodeNavigationState()
            }
            self.selectedMangaChapters = chapters
            self.selectedRelations = relations
            self.selectedRecommendations = recommendations
            // Characters/discussions are fetched separately below and
            // weren't part of this response — falling back to whatever the
            // cache already had (rather than always clearing to empty) is
            // what stops the cast grid this function just rendered from
            // cache flashing empty the instant this fresh fetch lands.
            self.selectedCharacters = cached?.characters ?? []
            self.selectedDiscussions = cached?.discussions ?? []
            let freshDetails = HeroBanner.Details(
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
                isFavourite: d.isFavourite,
                malId: d.malId
            )
            if cached == nil {
                withAnimation(.easeInOut(duration: 0.24)) {
                    self.selectedMediaDetails = freshDetails
                    self.isDetailLoading = false
                }
            } else {
                self.selectedMediaDetails = freshDetails
                self.isDetailLoading = false
            }
            await recordAniListSuccess()
            persistDetailCache(id: id, isManga: isManga)

            // Asynchronously load real Cast & Staff and Discussions from AniList if not already populated
            activeDetailExtrasTask?.cancel()
            let needsCharacters = (cached?.characters.isEmpty ?? true) || self.selectedCharacters.isEmpty
            let needsDiscussions = (cached?.discussions.isEmpty ?? true) || self.selectedDiscussions.isEmpty
            if needsCharacters || needsDiscussions {
                activeDetailExtrasTask = Task { [weak self, weak engine] in
                    guard let self, let engine, !Task.isCancelled else { return }
                    if needsCharacters {
                        if let chars = try? await engine.mediaCharacters(catalogId: id) {
                            guard !Task.isCancelled else { return }
                            let mapped = chars.map { c in
                                MediaDetailView.CharacterItem(
                                    id: c.id,
                                    name: c.name,
                                    imageURL: c.imageUrl.flatMap(URL.init(string:)),
                                    role: c.role,
                                    voiceActorName: c.voiceActorName,
                                    voiceActorImageURL: c.voiceActorImageUrl.flatMap(URL.init(string:))
                                )
                            }
                            if self.selectedMediaDetails?.id == id {
                                self.selectedCharacters = mapped
                                self.persistDetailCache(id: id, isManga: isManga)
                            }
                        }
                    }
                    if needsDiscussions {
                        guard !Task.isCancelled else { return }
                        if let disc = try? await engine.mediaDiscussions(catalogId: id) {
                            guard !Task.isCancelled else { return }
                            let mapped = disc.map { t in
                                MediaDetailView.DiscussionItem(
                                    id: t.id,
                                    title: t.title,
                                    replyCount: Int(t.replyCount),
                                    viewCount: Int(t.viewCount),
                                    authorName: t.authorName,
                                    authorAvatarURL: t.authorAvatarUrl.flatMap(URL.init(string:)),
                                    repliedAt: t.repliedAt
                                )
                            }
                            if self.selectedMediaDetails?.id == id {
                                self.selectedDiscussions = mapped
                                self.persistDetailCache(id: id, isManga: isManga)
                            }
                        }
                    }
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.isDetailLoading = false
            await recordAniListFailure(error)
            // A cached snapshot is already on screen (from the top of this
            // function) — a failed refresh shouldn't blank it out from under
            // the viewer, just quietly leave what's already showing.
            if cached == nil {
                let msg = error.localizedDescription
                errorMessage = "Could not open that title: \(msg)"
                // Roll back provisional screen so viewer isn't left on an empty zombie page
                if self.selectedMediaDetails?.id == id {
                    if let previous = self.detailHistory.popLast() {
                        self.restoredDetailTab = previous.tab
                        await self.loadDetail(id: previous.id, isManga: previous.isManga)
                    } else {
                        withAnimation(.easeInOut(duration: 0.32)) {
                            self.selectedMediaDetails = nil
                        }
                    }
                }
            }
        }
    }

    /// Snapshots the detail page's current in-memory state to disk under
    /// `(id, isManga)`. Called after each piece of the page lands (initial
    /// detail, then characters, then discussions) so a cache read later gets
    /// whatever was available last time, not just what happened to be ready
    /// at the very first save.
    private func persistDetailCache(id: Int64, isManga: Bool) {
        guard let details = selectedMediaDetails, details.id == id else { return }
        DetailCache.save(
            DetailCache.Snapshot(
                details: details,
                episodes: selectedEpisodes,
                mangaChapters: selectedMangaChapters,
                relations: selectedRelations,
                recommendations: selectedRecommendations,
                characters: selectedCharacters,
                discussions: selectedDiscussions
            ),
            id: id,
            isManga: isManga
        )
    }

    public func openDetail(catalogId: Int64, title: String? = nil, coverURL: URL? = nil, isManga: Bool = false) async {
        await openDetail(id: catalogId, title: title, coverURL: coverURL, isManga: isManga)
    }

    /// Speculatively warms up in-memory/disk caches for a title when hovered on desktop.
    public func prefetchDetail(id: Int64, isManga: Bool) {
        guard let engine, !isAniListDown else { return }
        if DetailCache.load(id: id, isManga: isManga) != nil { return }
        guard !activePrefetches.contains(id) else { return }
        activePrefetches.insert(id)
        Task(priority: .background) { [weak self, weak engine] in
            guard let self, let engine else { return }
            defer { self.activePrefetches.remove(id) }
            // 200ms debounce to avoid triggering on quick cursor sweeps across cards
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            _ = try? await engine.mediaDetail(catalogId: id, isManga: isManga)
        }
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
            await recordAniListSuccess()
            // Not `openDetail(id:)`: its "already viewing this title" guard
            // (`selectedMediaDetails?.id == id && !isDetailLoading`) always
            // matches here, since this mutation runs on the page currently
            // open — so it silently no-op'd instead of refreshing, and the
            // mark-watched checkbox (this is also what it calls) looked like
            // it did nothing after a real, slow AniList round trip.
            // `loadDetail` is the same fetch without that dedup guard.
            // `forceRefresh` because this mutation just made the cache stale
            // by definition — the freshness-window skip below exists for
            // "reopened the same title I already just saw", not this.
            await loadDetail(id: details.id, isManga: currentDetailIsManga(), forceRefresh: true)
        } catch {
            await recordAniListFailure(error)
            errorMessage = "Could not update AniList: \(error.localizedDescription)"
        }
    }

    /// Keyed by episode number, scoped to whichever title's detail page is
    /// open — episode numbers only need to be unique within one show, and
    /// only one show's episode list is ever on screen at a time.
    public var downloadStates: [Int: MediaDetailView.EpisodeDownloadState] = [:]

    /// One entry per episode ever downloaded (or downloading) this session,
    /// unlike `downloadStates` which is wiped every time the detail page
    /// switches title. This is what `DownloadsView` reads — it has to
    /// survive the detail page closing, since a download keeps running on
    /// the Rust side regardless of what's on screen.
    public struct LibraryDownload: Identifiable, Sendable {
        public var id: String { "\(catalogId)_\(episode)" }
        public let catalogId: Int64
        public let episode: Int
        public let title: String
        public let coverURL: URL?
        public var state: MediaDetailView.EpisodeDownloadState
    }

    public var libraryDownloads: [LibraryDownload] = []

    // MARK: - Syosetu novel reading
    //
    // Direct-URL only: the viewer pastes a `ncode.syosetu.com/nXXXXXX/` link
    // rather than the app resolving one from an AniList/RanobeDB entry — see
    // `reader::syosetu`'s module comment in the core crate. AniList-linked
    // light novel matching is a separate, unstarted piece of work.
    public struct SyosetuSession {
        public var sourceURL: String
        public var info: NovelInfo?
        public var currentChapterIndex: Int = 0
        public var chapterTitle: String = ""
        public var chapterText: String = ""
        public var isLoading = false
        public var errorMessage: String?
    }

    public var syosetuSession: SyosetuSession?

    public func openSyosetuReader(url: String) {
        syosetuSession = SyosetuSession(sourceURL: url)
        Task { await loadSyosetuInfo(url: url) }
    }

    public func closeSyosetuReader() {
        syosetuSession = nil
    }

    private func loadSyosetuInfo(url: String) async {
        guard let engine else { return }
        syosetuSession?.isLoading = true
        syosetuSession?.errorMessage = nil
        do {
            let info = try await engine.novelInfo(url: url)
            guard syosetuSession?.sourceURL == url else { return }
            syosetuSession?.info = info
            syosetuSession?.isLoading = false
            if let first = info.chapters.first {
                await loadSyosetuChapter(url: first.url, index: 0)
            }
        } catch {
            guard syosetuSession?.sourceURL == url else { return }
            syosetuSession?.isLoading = false
            syosetuSession?.errorMessage = error.localizedDescription
        }
    }

    public func loadSyosetuChapter(url: String, index: Int) async {
        guard let engine, let session = syosetuSession else { return }
        let sourceURL = session.sourceURL
        syosetuSession?.isLoading = true
        syosetuSession?.errorMessage = nil
        do {
            let chapter = try await engine.novelChapter(url: url)
            guard syosetuSession?.sourceURL == sourceURL else { return }
            syosetuSession?.currentChapterIndex = index
            syosetuSession?.chapterTitle = chapter.title
            syosetuSession?.chapterText = chapter.text
            syosetuSession?.isLoading = false
        } catch {
            guard syosetuSession?.sourceURL == sourceURL else { return }
            syosetuSession?.isLoading = false
            syosetuSession?.errorMessage = error.localizedDescription
        }
    }

    /// "Stream Servers": every release the indexers found for this episode.
    public func loadReleaseCandidates(episode: Int) async -> [MediaDetailView.ReleaseCandidateItem] {
        guard let engine, let details = selectedMediaDetails else { return [] }
        do {
            let choices = try await engine.listReleaseCandidates(
                catalog: .anilist,
                catalogId: details.id,
                episode: Int64(episode),
                title: details.title
            )
            return choices.map {
                MediaDetailView.ReleaseCandidateItem(name: $0.name, seeders: Int($0.seeders), isDub: $0.isDub)
            }
        } catch {
            return []
        }
    }

    /// Starts a "Download Episode" and polls its progress into
    /// `downloadStates` until it finishes, one way or the other. The poll
    /// loop is the only client of `episodeDownloadStatus` — the row itself
    /// just reads `downloadStates[episode]`, same as every other piece of
    /// reactive state this model exposes.
    public func startDownload(episode: Int) async {
        guard let engine, let details = selectedMediaDetails else { return }
        guard downloadStates[episode] == nil || downloadStates[episode] == .notStarted else { return }
        downloadStates[episode] = .downloading(percent: 0)
        setLibraryDownload(catalogId: details.id, episode: episode, title: details.title, coverURL: details.coverURL, state: .downloading(percent: 0))
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        do {
            try await engine.startEpisodeDownload(
                catalog: .anilist,
                catalogId: details.id,
                episode: Int64(episode),
                title: details.title,
                preferDub: preferDub
            )
        } catch {
            downloadStates[episode] = .failed(message: error.localizedDescription)
            setLibraryDownload(catalogId: details.id, episode: episode, title: details.title, coverURL: details.coverURL, state: .failed(message: error.localizedDescription))
            return
        }

        // Captured up front rather than re-read from `selectedMediaDetails`
        // each tick — the detail page can move to a different title mid-poll
        // and this loop must keep tracking the episode it started for, not
        // whatever happens to be open.
        let catalogId = details.id
        let title = details.title
        let coverURL = details.coverURL
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let status = await engine.episodeDownloadStatus(
                catalog: .anilist,
                catalogId: catalogId,
                episode: Int64(episode)
            )
            let mirrorToDetailPage = selectedMediaDetails?.id == catalogId
            switch status {
            case .notStarted:
                if mirrorToDetailPage { downloadStates[episode] = .notStarted }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .notStarted)
            case .downloading(let percent):
                if mirrorToDetailPage { downloadStates[episode] = .downloading(percent: percent) }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .downloading(percent: percent))
                continue
            case .done(let path):
                if mirrorToDetailPage { downloadStates[episode] = .done(path: path) }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .done(path: path))
            case .failed(let message):
                if mirrorToDetailPage { downloadStates[episode] = .failed(message: message) }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .failed(message: message))
            }
            return
        }
    }

    private func setLibraryDownload(catalogId: Int64, episode: Int, title: String, coverURL: URL?, state: MediaDetailView.EpisodeDownloadState) {
        if let idx = libraryDownloads.firstIndex(where: { $0.catalogId == catalogId && $0.episode == episode }) {
            libraryDownloads[idx].state = state
        } else {
            libraryDownloads.append(LibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: state))
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

    public func toggleFavourite() async {
        guard let engine, let details = selectedMediaDetails else { return }
        do {
            try await engine.toggleFavourite(catalogId: details.id, isManga: currentDetailIsManga())
            await recordAniListSuccess()
            // See `removeFromList`/`updateListEntry` — same `openDetail(id:)`
            // dedup-guard no-op.
            await loadDetail(id: details.id, isManga: currentDetailIsManga(), forceRefresh: true)
        } catch {
            await recordAniListFailure(error)
            errorMessage = "Could not update favourite: \(error.localizedDescription)"
        }
    }

    /// Removes the open title from the signed-in user's list entirely.
    public func removeFromList() async {
        guard let engine, let details = selectedMediaDetails, let entryId = details.listEntryId else { return }
        do {
            try await engine.removeFromList(listEntryId: entryId)
            await recordAniListSuccess()
            // Not `openDetail(id:)` — see the identical fix on
            // `updateListEntry`: its "already viewing this title" guard
            // always matches here since this runs on the page currently
            // open, so the refresh silently no-op'd and the list-status
            // menu kept showing the removed entry's old status.
            await loadDetail(id: details.id, isManga: currentDetailIsManga(), forceRefresh: true)
        } catch {
            await recordAniListFailure(error)
            errorMessage = "Could not remove from AniList: \(error.localizedDescription)"
        }
    }

    /// The progress/status pair a mark-watched implies. Shared by the
    /// episode list's checkbox and the player's 85% auto-advance rather than
    /// written twice: the two disagreeing is how a binge that finished a
    /// season left the list entry on CURRENT at `total`.
    static func listEntryUpdate(
        episode: Int,
        watched: Bool,
        episodeCount: Int?,
        listStatus: String?
    ) -> (progress: Int, status: String?) {
        var progress = watched ? episode : episode - 1
        var status: String?
        if let total = episodeCount, total > 0, progress >= total {
            progress = total
            status = "COMPLETED"
        } else if progress > 0, listStatus == nil || listStatus == "PLANNING" {
            status = "CURRENT"
        }
        return (progress, status)
    }

    /// The player's 85% auto-advance, which cannot go through
    /// `setEpisodeWatched`/`updateListEntry` unconditionally: both open with
    /// `guard let details = selectedMediaDetails`, and playback started from
    /// a home shelf has no detail page open at all — so bingeing from the
    /// home screen advanced the local watch registry on every episode while
    /// AniList silently never moved. With the page open this still routes
    /// through the checkbox's own path so the list updates optimistically
    /// under the viewer; without it, the entry's current state is fetched
    /// (one call, once per episode, only on the threshold crossing) and the
    /// mutation is sent directly.
    func advanceAniListProgress(catalogId: Int64, episode: Int) async {
        if let details = selectedMediaDetails, details.id == catalogId {
            guard (details.listProgress ?? 0) < episode else { return }
            await setEpisodeWatched(episode, watched: true)
            return
        }
        guard let engine else { return }
        do {
            let detail = try await engine.mediaDetail(catalogId: catalogId, isManga: false)
            // Read from AniList rather than assumed 0: without the detail
            // page there is no local copy of the entry, and re-sending a
            // progress the list already passed would drag it backwards on a
            // rewatch.
            guard Int(detail.listProgress ?? 0) < episode else { return }
            let (progress, status) = Self.listEntryUpdate(
                episode: episode,
                watched: true,
                episodeCount: (detail.episodeCount ?? detail.chapterCount).map(Int.init),
                listStatus: detail.listStatus
            )
            try await engine.updateListEntry(
                catalogId: catalogId,
                status: status,
                score: nil,
                progress: Int64(progress)
            )
            await recordAniListSuccess()
        } catch {
            await recordAniListFailure(error)
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
        let (progress, status) = Self.listEntryUpdate(
            episode: episode,
            watched: watched,
            episodeCount: details.episodeCount,
            listStatus: details.listStatus
        )
        // Optimistic: `updateListEntry` below is a real AniList mutation
        // followed by a full re-fetch to reconcile — two sequential network
        // round trips before the checkbox would otherwise show anything.
        // Flipping locally first (same progress-cutoff rule the server uses)
        // makes the toggle feel instant; the re-fetch still lands afterward
        // and corrects this if the server's answer differs.
        selectedEpisodes = selectedEpisodes.map { ep in
            let shouldBeWatched = ep.number <= progress
            guard ep.isWatched != shouldBeWatched else { return ep }
            return MediaDetailView.EpisodeItem(
                id: ep.id,
                number: ep.number,
                title: ep.title,
                thumbnailURL: ep.thumbnailURL,
                isWatched: shouldBeWatched,
                progressPercent: ep.progressPercent,
                synopsis: ep.synopsis,
                airDate: ep.airDate,
                runtimeMinutes: ep.runtimeMinutes
            )
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
                anilistId: anilistId,
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
            }()
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
    private func fetchLibrary() async {
        guard let engine, !Task.isCancelled else { return }
        do {
            let rows = try await engine.userList(status: libraryStatus, mediaType: libraryType)
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
        let readingRows = (try? await readingRowsTask) ?? []

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

    /// Just the watch log, for `refreshAll`'s concurrent batch — the
    /// viewer/isSignedIn part is dropped here because `loadInitialCatalog`,
    /// running at the same time, already fetches and sets both; doing it
    /// again here would be a second `viewerProfile` round trip racing to
    /// write the same two properties.
    private func fetchWatchActivity() async {
        guard let engine else { return }
        activity = (try? engine.watchActivity(limit: 500)) ?? []
    }

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
        let hasActiveFilter = filters.map {
            $0.genre != nil || $0.year != nil || $0.minScore != nil || $0.status != nil || $0.sort != nil
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

    /// Cmd+K's own live title search — deliberately not routed through
    /// `search()`: that mutates `searchResults`/`searchCurrentPage`, which
    /// belong to the Search tab, and the palette can be open from any screen.
    /// Anime only (matches the palette's own "Search shows..." placeholder;
    /// the Search tab is still the place to browse manga/novels).
    public func quickSearchTitles(_ query: String) async -> [MediaCard.Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let engine, !trimmed.isEmpty else { return [] }
        guard let summaries = try? await engine.searchCatalog(query: trimmed, mediaType: "ANIME", filters: nil, page: 1) else {
            return []
        }
        return summaries.map { Self.card($0) }
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
            let filters = SearchFilters(genre: nil, year: nil, minScore: nil, status: nil, sort: "TRENDING_DESC")
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

    /// Handles real-time playback position changes from the player and records to SQLite.
    ///
    /// The Discord Rich Presence write and the SQLite progress write are both
    /// blocking calls into the Rust core — `discord_rich_presence`'s IPC
    /// write can stall for as long as Discord's own read side does, and this
    /// used to run synchronously on the main thread on every pause/resume
    /// and once a second during playback. A single slow Discord write froze
    /// the whole player: mpv had already paused internally, but the redraw
    /// mpv's update callback queues onto the main thread (see
    /// `MpvSurface`'s render callback) couldn't run until the blocked
    /// call returned, so the screen and the play/pause button both sat
    /// frozen for however long that took. Both calls are dispatched off the
    /// main thread below; only the cheap bookkeeping (dedup flags,
    /// `ContinuityManager`) stays synchronous.
    public func handlePlaybackPositionChange(currentTime: Double, duration: Double) {
        guard let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let engine else { return }

        let rawStop = Int64(currentTime)
        let dur = Int64(duration)
        let stopTime = dur > 0 ? min(rawStop, dur) : rawStop
        guard stopTime >= 0 else { return }

        let isPaused = !playerController.isPlaying
        let pauseEdgeChanged = isPaused != lastDiscordPaused
        if pauseEdgeChanged {
            lastDiscordPaused = isPaused
        }

        // Auto-advance AniList progress past the same 85% line that counts
        // an episode "watched" elsewhere, so bingeing through the built-in
        // player keeps the AniList list in sync the way ticking the episode
        // list's checkbox by hand already does — without this, only that
        // manual checkbox ever moved AniList's progress, while the local
        // watch-history registry (and so the resume offer) advanced on every
        // episode played. The two tracked different things and the resume
        // offer could point well past whatever AniList actually showed.
        if currentPlaybackCatalog == .anilist, !hasAdvancedAniListForCurrentEpisode, dur > 0 {
            let percent = Double(stopTime) / Double(dur) * 100
            if percent >= Self.watchedThresholdPct {
                hasAdvancedAniListForCurrentEpisode = true
                // Reuses the episode list's own mark-watched path (status
                // transitions, COMPLETED-on-last-episode clamp) when the
                // detail page is open, and sends the same mutation itself
                // when it isn't — see `advanceAniListProgress`.
                Task { await self.advanceAniListProgress(catalogId: catalogId, episode: Int(episode)) }
            }
        }

        // Resolve the next episode into the second selected-file slot before
        // it is needed. Without this every auto-next was a cold resolve, a
        // black gap between episodes for as long as search plus pre-buffer
        // took. The result is not read here; the real play hits the reuse
        // path in `TorrentManager::resolve`. `preload: true` keeps it from
        // taking the playing-file pin off the episode mpv is reading.
        if currentPlaybackCatalog == .anilist, !hasPreloadedNextEpisode, dur > 0,
           playerController.hasNextEpisode,
           Double(stopTime) / Double(dur) * 100 >= Self.nextEpisodePreloadPct {
            hasPreloadedNextEpisode = true
            let sorted = playbackEpisodes
            if let index = sorted.firstIndex(where: { $0.number == Int(episode) }),
               sorted.indices.contains(index + 1) {
                let next = Int64(sorted[index + 1].number)
                let req = StreamRequest(
                    catalog: .anilist,
                    catalogId: catalogId,
                    episode: next,
                    title: currentPlaybackTitle,
                    preferDub: UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed",
                    chosenName: nil,
                    resumeFraction: nil,
                    preload: true
                )
                Task.detached(priority: .utility) {
                    do {
                        _ = try await engine.resolveStream(req: req)
                    } catch {
                        // A failed preload costs nothing visible: the real
                        // play resolves cold exactly as it did before.
                        print("[preload] episode \(next) not preloaded: \(error)")
                    }
                }
            }
        }

        // Auto-play-next: same near-end-of-duration check as the watched
        // threshold above, gated on the setting and on there being a next
        // episode at all. `playAdjacentEpisode` reuses the ordinary
        // next-episode path (episode list refresh, resume state, everything
        // `nextEpisode()`'s manual button already does) rather than
        // duplicating it here.
        if !hasAutoAdvancedEpisode, dur > 0, Double(dur) - currentTime <= Self.autoAdvanceRemainingSeconds,
           playerController.autoPlayNextEnabled, playerController.hasNextEpisode {
            hasAutoAdvancedEpisode = true
            Task { await self.playAdjacentEpisode(offset: 1) }
        }

        // Only record if whole second changed and valid
        let secondChanged = stopTime != lastRecordedSecond
        guard pauseEdgeChanged || secondChanged else { return }
        if secondChanged {
            lastRecordedSecond = stopTime
            // Pause edges reach the tile through `syncPlaybackSession`;
            // this is only the once-a-second elapsed time, three keys on a
            // dictionary already built.
            nowPlaying.updateProgress(
                elapsed: currentTime,
                duration: duration,
                rate: isPaused ? 0 : playerController.playbackRate
            )
        }

        let title = currentPlaybackTitle ?? "Anime"
        let episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        let totalEpisodes = Int64(selectedMediaDetails?.episodeCount ?? 0)
        let catalog = currentPlaybackCatalog

        engineIOQueue.async {
            if pauseEdgeChanged {
                engine.discordSetPresence(
                    title: title,
                    episode: episode,
                    episodeTitle: episodeTitle,
                    totalEpisodes: totalEpisodes,
                    pos: stopTime,
                    duration: dur,
                    paused: isPaused
                )
            }
            if secondChanged {
                try? engine.recordProgress(
                    catalog: catalog,
                    catalogId: catalogId,
                    episodeNumber: episode,
                    stopTime: stopTime,
                    duration: dur
                )
                if !isPaused {
                    engine.discordSetPresence(
                        title: title,
                        episode: episode,
                        episodeTitle: episodeTitle,
                        totalEpisodes: totalEpisodes,
                        pos: stopTime,
                        duration: dur,
                        paused: false
                    )
                }
            }
        }

        if secondChanged {
            ContinuityManager.shared.advertisePlayback(
                catalogId: catalogId,
                title: title,
                episode: Int(episode),
                timePositionSeconds: currentTime
            )
        }
    }

    /// Races `resolveStream` against a plain timer so a stalled search or a
    /// dead swarm fails fast with a clear message instead of hanging with no
    /// ceiling at all. Returns just the stream URL string — `StreamHandle`
    /// itself isn't `Sendable` (a plain uniffi-generated struct), and the
    /// URL is the only field any caller reads.
    private static func resolveWithTimeout(
        engine: AnicatEngine,
        req: StreamRequest,
        timeoutSeconds: Double
    ) async throws -> String {
        // `StreamRequest` is a plain uniffi-generated value struct — no
        // shared mutable state — but isn't marked `Sendable`, so the strict
        // concurrency checker won't let it cross into `addTask`'s closure
        // without this box making the "trust me" explicit.
        final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }
        let boxedReq = UncheckedBox(req)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await engine.resolveStream(req: boxedReq.value).url }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw NSError(
                    domain: "Anicat",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No stream found after \(Int(timeoutSeconds))s. The search or download may be stalled — try again, or try a different episode."]
                )
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Resolves a torrent release and prepares the stream URL for playback.
    public func resolveAndPlay(
        catalog: FfiCatalog = .anilist,
        catalogId: Int64,
        episode: Int64,
        title: String? = nil,
        chosenName: String? = nil
    ) async throws -> URL {
        let effectiveTitle = title ?? self.selectedMediaDetails?.title ?? self.knownTitles[catalogId] ?? "Anime"
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.isPlaying = true

        guard let engine else {
            throw NSError(domain: "Anicat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        isLoading = true
        defer { isLoading = false }

        // From here on, anything mpv reports belongs to the outgoing file,
        // unless this is the same episode being asked for again: then no
        // new file will load, no FILE_LOADED will clear the gate, and the
        // numbers mpv is emitting are the right file's already.
        let replayingCurrent = activeStreamURL != nil
            && currentPlaybackCatalogId == catalogId
            && currentPlaybackEpisode == episode
        self.currentPlaybackCatalog = catalog
        self.currentPlaybackCatalogId = catalogId
        self.currentPlaybackEpisode = episode
        self.playerController.awaitingNewFile = !replayingCurrent
        ensurePlaybackEpisodes(for: catalogId, engine: engine)
        self.currentPlaybackTitle = effectiveTitle
        // A fresh play always opens full-screen, not stuck minimized from
        // whatever the last session left it as.
        self.isPlayerMinimized = false
        resetPerEpisodeDedupState(discordPaused: false)
        // Cleared up front rather than left showing the previous episode's
        // skip window for however long the fetch below takes.
        self.playerController.setAniSkipTimes(nil)
        // Same reasoning: a new episode's overlay shouldn't briefly letterbox
        // itself against the last episode's aspect ratio before mpv reports
        // the new one.
        self.playerController.videoDisplayWidth = nil
        self.playerController.videoDisplayHeight = nil

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
            if let ep = playbackEpisodes.first(where: { $0.number == Int(episode) }),
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
            chosenName: chosenName,
            resumeFraction: resumeFraction,
            preload: false
        )

        // Real feedback instead of a bare spinner: resolve is a single
        // opaque FFI call with no intermediate progress at all (unlike
        // `torrent/search.rs`'s own internal racing/grace-period logic,
        // which the timeout below mirrors), so the UI has nothing to show
        // except how long it's been waiting. And with no ceiling at all, a
        // stalled search or a dead swarm hung here indefinitely — three
        // minutes staring at a spinner with no way out, not a fast failure.
        resolveStartedAt = Date()
        defer { resolveStartedAt = nil }
        // 120s, not the original 45: `torrent/mod.rs`'s own `PREBUFFER_TIMEOUT`
        // is 40s *per candidate*, and a legitimate resolve can burn through
        // several tiers of fallback (the raced pair, the sequential rest of
        // the shortlist, then an extended pool of 6 more) before landing on
        // one that actually works — a real measured case in that file's own
        // comments describes 17 candidates, all four shortlisted ones dead,
        // before it succeeded further down the pool. 45s was cutting that
        // process off mid-fallback, not just catching genuinely stuck
        // resolves — likely exactly what happened resuming episode 9 here:
        // picking a specific release manually skips the fallback chain
        // entirely and went straight to a release that worked, instantly.
        let handleURL: String
        do {
            handleURL = try await Self.resolveWithTimeout(engine: engine, req: req, timeoutSeconds: 120)
            // The Cancel button (`cancelResolve`) only cancels *waiting* on
            // this Task, not the FFI call itself mid-flight — check here so
            // a resolve that finishes after the viewer already gave up
            // doesn't start playback anyway.
            guard !Task.isCancelled else {
                throw CancellationError()
            }
        } catch {
            // No new file is coming; whatever is still playing owns the
            // position again.
            self.playerController.awaitingNewFile = false
            throw error
        }
        guard let streamURL = URL(string: handleURL) else {
            self.playerController.awaitingNewFile = false
            throw NSError(domain: "Anicat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL: \(handleURL)"])
        }

        // Before returning streamURL, configure playerController with actual title, episode number, and duration
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        self.playerController.isPlaying = true
        if self.playerController.duration <= 0 && initialDuration > 0 {
            self.playerController.duration = initialDuration
        }

        // Same explicit curve/duration the detail page's own open/close uses
        // (`closeDetail`, `loadDetail`) rather than leaning on a bare
        // `.animation(value:)` modifier at the view side — relying on that
        // alone left the player's entrance timed by whatever SwiftUI's
        // default "smooth" spring happens to be, uncoordinated with
        // everything else that's mounting at the same instant (the chrome
        // bars' own appear animation, the mini-player fading out if it was
        // showing), which is what read as jittery rather than one clean
        // transition.
        withAnimation(.easeInOut(duration: 0.32)) {
            self.activeStreamURL = streamURL
        }
        // Publishes the Now Playing tile as a side effect, here and not on
        // the first position tick: media keys route to the app only once
        // the tile is up with `playbackState == .playing`, and mpv has not
        // yet been handed the URL, so this is before the first frame.
        updateEpisodeNavigationState()
        syncPlaybackSession()

        // AniSkip is keyed by MAL id, so only anime (not the other catalogs
        // `resolveAndPlay` might grow) and only titles AniList actually has a
        // MAL mapping for. Fire-and-forget: skip times are a nicety, not
        // worth delaying the return of `streamURL` over.
        if catalog == .anilist, let malId = selectedMediaDetails?.malId {
            let episodeNumber = Int(episode)
            let episodeLength = self.playerController.duration
            Task { [weak self] in
                let times = await AniSkipClient.skipTimes(malId: malId, episode: episodeNumber, episodeLengthSeconds: episodeLength)
                guard let self else { return }
                // The viewer may have already moved on (next/prev, closed the
                // player) by the time this lands — a stale result applied to
                // whatever's playing now would show the wrong episode's skip
                // window.
                guard self.currentPlaybackCatalogId == catalogId, self.currentPlaybackEpisode == episode else { return }
                self.playerController.setAniSkipTimes(times)
            }
        } else if catalog == .anilist {
            // Was silent — "AniSkip doesn't work" with nothing to say why is
            // exactly this case: AniList has no MAL cross-reference for this
            // title at all, so there was never going to be a request to
            // begin with, not a failed one.
            print("[AniSkip] no MAL id for AniList id \(catalogId) — skip times unavailable for this title")
        }

        // Apple Handoff: broadcast current playback activity to iPhone / iPad / Mac
        ContinuityManager.shared.advertisePlayback(
            catalogId: catalogId,
            title: effectiveTitle,
            episode: Int(episode),
            timePositionSeconds: playerController.currentTime
        )

        engine.discordSetPresence(
            title: effectiveTitle,
            episode: episode,
            episodeTitle: playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? "",
            totalEpisodes: Int64(selectedMediaDetails?.episodeCount ?? 0),
            pos: Int64(playerController.currentTime),
            duration: Int64(playerController.duration),
            paused: false
        )

        return streamURL
    }

    /// Stops playback, records final progress into SQLite, and clears the Apple Handoff broadcast.
    public func stopPlayback() {
        // Both calls are IPC writes into the Rust engine — `recordProgress`
        // hits SQLite, `discordClearPresence` hits Discord's socket, and the
        // comment on `handlePlaybackPositionChange` already documents that a
        // slow Discord read side can stall a call like this for as long as
        // Discord takes to answer. Closing the player is the one action a
        // viewer expects to be instant; running these inline on the main
        // actor reintroduces the exact freeze that method was detached to fix.
        if let engine, let catalogId = currentPlaybackCatalogId, let episode = currentPlaybackEpisode {
            let dur = Int64(playerController.duration)
            let rawStop = Int64(playerController.currentTime)
            let stopTime = dur > 0 ? min(rawStop, dur) : rawStop
            let catalog = currentPlaybackCatalog
            engineIOQueue.async {
                try? engine.recordProgress(
                    catalog: catalog,
                    catalogId: catalogId,
                    episodeNumber: episode,
                    stopTime: stopTime,
                    duration: dur
                )
                engine.discordClearPresence()
            }
        } else {
            engine?.discordClearPresence()
        }
        // Release the playing-file pin and pause the session's torrents.
        // Without it a closed player kept downloading the rest of the
        // episode, and the preloaded next one, at full speed.
        if let engine {
            Task.detached(priority: .utility) { await engine.playbackStopped() }
        }
        self.activeStreamURL = nil
        self.isPlayerMinimized = false
        self.currentPlaybackCatalogId = nil
        self.currentPlaybackEpisode = nil
        self.currentPlaybackTitle = nil
        resetPerEpisodeDedupState(discordPaused: nil)
        playerController.hasNextEpisode = false
        playerController.hasPreviousEpisode = false
        playerController.episodeList = []
        playbackEpisodes = []
        playbackEpisodesCatalogId = nil
        playbackCoverURL = nil
        ContinuityManager.shared.stopAdvertising()
        syncPlaybackSession()

        // Pinned to the main actor rather than inheriting the caller's
        // context: from the app this is always main, but a test calling
        // stopPlayback from a nonisolated context ran this on a cooperative
        // thread, and reading selectedMediaDetails there while the main
        // thread replaced it was a SIGBUS on a freed HeroBanner.Details.
        Task { @MainActor in
            await loadHistory()
            if let currentDetails = selectedMediaDetails {
                await loadDetail(id: currentDetails.id, isManga: Self.isMangaFormat(currentDetails.format))
            }
        }
    }

    /// Handles dismissal hierarchy for ESC key:
    /// 1. KeyboardShortcutsOverlay (topmost help modal)
    /// 2. CommandPalette (topmost overlay)
    /// 3. PlayerView (modal video playback)
    /// 4. MangaReaderView (modal manga reading)
    /// 5. MediaDetailView (detail page)
    @discardableResult
    public func handleEscapeKey() -> Bool {
        if onboardingOpen {
            // Escape reads as "not now", the same as the Skip button.
            completeOnboarding()
            return true
        }
        if shortcutsOpen {
            shortcutsOpen = false
            return true
        }
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
        shortcutsOpen = false
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

        // Concurrent: all three are independent reads, and nothing here
        // touches `self` until every result is back, so fanning them out
        // carries none of the cross-task write races that ruled out
        // `async let` at the `refreshAll` level.
        async let trendingTask = engine.trending(mediaType: "ANIME", format: nil, limit: 24)
        async let watchingTask = engine.userList(status: "CURRENT", mediaType: "ANIME")
        async let profileTask = engine.viewerProfile()

        let trending = (try? await trendingTask) ?? []
        let watching = (try? await watchingTask) ?? []
        let profile = try? await profileTask
        trendingItems = trending.map(Self.card)
        if profile != nil || !trending.isEmpty || !watching.isEmpty {
            await recordAniListSuccess()
        }
        isSignedIn = profile != nil
        viewer = profile
        watchingItems = watching.map(Self.card)

        // AniList's `watching` list comes back in whatever order the API
        // defaults to (not recency) — `upNextItems.first` is what the menu
        // bar's "Continue Watching" reads as the most-recently-watched
        // title, so leaving this unsorted meant it showed whichever show
        // happened to sit first in AniList's own list order, not whatever
        // was actually last touched.
        let sortedWatching = watching.sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
        upNextItems = sortedWatching.compactMap { s in
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
                watchedTimeAgo: s.updatedAt.map(Self.relativeTime),
                hasNewEpisode: progress < released,
                unit: "EP"
            )
        }

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
