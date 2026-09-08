import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

/// One entry of `AppModel.personPageStack`: the AniList records that used to
/// be a `Platform.openExternal` out of the app. Identified by catalog id
/// alone, because that is the whole address of one — there is nothing else
/// to carry and nothing local to key it against.
public enum PersonPage: Equatable, Hashable, Identifiable, Sendable {
    case character(id: Int64)
    case staff(id: Int64)
    case thread(id: Int64)
    case studio(id: Int64)

    public var id: String {
        switch self {
        case .character(let id): return "character-\(id)"
        case .staff(let id): return "staff-\(id)"
        case .thread(let id): return "thread-\(id)"
        case .studio(let id): return "studio-\(id)"
        }
    }

    /// The page this replaced, kept as the "Open on AniList" destination on
    /// each page so nothing that was reachable before became unreachable.
    public var anilistURL: URL? {
        switch self {
        case .character(let id): return URL(string: "https://anilist.co/character/\(id)")
        case .staff(let id): return URL(string: "https://anilist.co/staff/\(id)")
        case .thread(let id): return URL(string: "https://anilist.co/forum/thread/\(id)")
        case .studio(let id): return URL(string: "https://anilist.co/studio/\(id)")
        }
    }
}

@Observable
@MainActor
public final class AppModel {
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

    /// Blocks until every progress/Discord write queued so far has run.
    /// For tests that read the registry right after a position tick: the
    /// writes are deliberately asynchronous (see the queue's comment) and
    /// a synchronous read raced them, failing about two runs in three once
    /// the suite grew enough parallel load.
    func drainEngineIO() {
        engineIOQueue.sync {}
    }

    var activeDetailTask: Task<Void, Never>?
    var activeDetailExtrasTask: Task<Void, Never>?
    var activeLibraryTask: Task<Void, Never>?
    var activeSearchTask: Task<Void, Never>?
    public internal(set) var loadingCatalogId: Int64?

    public var engine: AnicatEngine?
    public var isInitialized = false
    public var isLoading = false
    public var errorMessage: String?
    #if os(iOS)
    /// A play held back because the phone is on cellular. See
    /// `playGuardedByCellular`.
    public var cellularPrompt: CellularPrompt?
    /// The grant the current episode is being read through, when it is
    /// coming from a Mac rather than from this phone's own engine.
    public var activeRemoteStreamToken: String?
    #endif
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
            // A 429 is our own request budget, not AniList's health, and the
            // client already knows the cooldown and waits it out. Counting it
            // here let a burst of throttled writes cross the failure
            // threshold and raise the "AniList is down" banner over a service
            // that was answering everyone else fine.
            if msg.contains("HTTP 429") {
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
    var activePrefetches: Set<Int64> = []
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

    // MARK: - Detail extras

    /// Works by studio id, for the "More from" shelf at the foot of the
    /// detail page. Keyed by studio rather than by title so two shows from
    /// the same studio share one fetch, and never pruned: a session opens
    /// few enough studios that the map stays smaller than a single detail
    /// snapshot.
    var studioWorks: [Int64: [MediaSummary]] = [:]
    /// Studio ids with a `studioWorks` fetch already in flight. The shelf
    /// asks on `onAppear`, which fires again on every scroll back into
    /// view — without this each return trip started another request.
    var studioWorksInFlight: Set<Int64> = []

    // MARK: - People and threads

    /// A stack, not a single page: a character page lists its voice actors,
    /// a staff page lists the characters that actor voiced, and either one
    /// can be opened from the other indefinitely. Back has to step through
    /// that chain, so a lone `selectedCharacter?` would strand the reader on
    /// the detail page two taps in.
    public var personPageStack: [PersonPage] = []
    /// Content for `personPageStack.last` only. Everything below the top is
    /// re-fetched on the way back rather than kept, because these records
    /// are large (a prolific staff member's credits run to hundreds of
    /// entries) and the engine's own AniList cache makes the refetch cheap.
    public var loadedCharacter: FfiCharacterDetail?
    public var loadedStaff: FfiStaffDetail?
    public var loadedThread: FfiThreadDetail?
    public var loadedStudio: FfiStudioDetail?
    /// Page 1 arrives inside `loadedThread`; `loadMoreThreadComments`
    /// appends later pages here rather than replacing, so the list grows.
    public var loadedThreadComments: [FfiThreadComment] = []
    public var threadHasMoreComments = false
    public var isLoadingMoreThreadComments = false
    /// `threadDetail` already returned page 1, so the next fetch is page 2.
    var threadCommentsNextPage: Int64 = 2
    public var isPersonPageLoading = false
    public var personPageError: String?
    var activePersonPageTask: Task<Void, Never>?
    var activeThreadCommentsTask: Task<Void, Never>?

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

    /// Which episode thumbnail this play was started from, as
    /// "episode:<catalogId>:<number>" for a detail-page row or
    /// "upnext:<catalogId>:<number>" for an Up Next row — the
    /// `matchedGeometryEffect` id that flies that still into the video
    /// frame. The two prefixes are deliberately different rather than one
    /// shared "episode:" form: an Up Next play opens the show's page before
    /// it resolves (see `playFromShelf`), so a shared key would leave the
    /// shelf row *and* that page's own row for the same episode both tagged
    /// as sources for one id — the undefined behavior
    /// `openingDetailSourceKey` documents. Nil for any play with no row
    /// behind it (menu-bar Resume, auto-next, Handoff); those just fade in.
    public var openingPlayerSourceKey: String?
    /// The still the key above names, so the player can draw it without
    /// reaching back into whichever list the play came from.
    public var openingPlayerThumbnailURL: URL?

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
    var playbackCoverURL: URL?
    /// MyAnimeList id of the *playing* title, which is what AniSkip is keyed
    /// by. Filled from the same place `playbackEpisodes` is, because
    /// `selectedMediaDetails` is the open page's — a play from the Up Next
    /// shelf or from another show's page read either no id or the wrong
    /// one, and AniSkip simply never fired there.
    var playbackMalId: Int64?
    /// Set when AniSkip was asked for before mpv reported the file's
    /// duration; the first duration tick re-asks with the real length.
    var aniSkipAwaitingDuration = false
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

    var lastRecordedSecond: Int64 = -1
    /// Separate from `lastRecordedSecond`'s once-a-second gate: pausing and
    /// resuming inside the same second must still flip Discord's "(Paused)"
    /// label immediately rather than waiting for the next second to tick
    /// over, since `pause()`/`play()` re-report the same truncated position.
    var lastDiscordPaused: Bool?
    // Guards the AniList auto-advance below to one attempt per episode
    // rather than once a second for the rest of the episode once past 85%.
    var hasAdvancedAniListForCurrentEpisode = false
    // Same idea, for auto-play-next: one attempt per episode once past the
    // near-end line below.
    var hasAutoAdvancedEpisode = false

    // One speculative resolve of the next episode per episode session, see
    // `nextEpisodePreloadPct`.
    var hasPreloadedNextEpisode = false
    // Where in the current episode the next one is resolved ahead of time.
    // Far enough from the end that a cold resolve (search, race, pre-buffer;
    // 2 to 10 s, more on a slow swarm) has landed before auto-next fires at
    // `autoAdvanceRemainingSeconds`, and past the point where most viewers
    // who are going to stop have stopped, so the second download slot is
    // not spent on episodes nobody reaches. On a 24 min episode this is
    // 6 min of headroom.
    static let nextEpisodePreloadPct: Double = 75.0
    // Same 85% line the Tauri build's `commands/playback.rs` uses for
    // "watched" — kept in sync with it, not derived from anything else.
    static let watchedThresholdPct: Double = 85.0
    // How close to the real end counts as "the episode is over" for
    // auto-play-next. `eof-reached`/`playback-restart` are the obvious
    // signals but don't fire reliably against a torrent stream — seeking
    // into the tail of a file whose last pieces aren't downloaded yet leaves
    // mpv sitting in `seeking=true` indefinitely rather than reaching EOF
    // (documented against the other build's mpv integration; same swarm
    // underneath here). Watching position against duration, the same fix
    // used there, works regardless.
    static let autoAdvanceRemainingSeconds: Double = 2.0

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
        /// Where this chapter was left, from the registry. A chapter never
        /// opened starts at 0, which is also what every chapter did before
        /// there was anywhere to record it.
        public var startPage: Int = 0

        public init(
            title: String,
            chapterTitle: String,
            chapterId: String,
            pageURLs: [URL],
            chapterIndex: Int,
            chapters: [MediaDetailView.MangaChapterItem],
            anilistId: Int64?,
            startPage: Int = 0
        ) {
            self.title = title
            self.chapterTitle = chapterTitle
            self.chapterId = chapterId
            self.pageURLs = pageURLs
            self.chapterIndex = chapterIndex
            self.chapters = chapters
            self.anilistId = anilistId
            self.startPage = startPage
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
    /// The planning ids `smartPicks` was last shuffled from; see `loadHome`.
    @ObservationIgnored var smartPicksSeed: Set<Int64> = []
    public var newlyReleasingItems: [MediaCard.Item] = []
    public var seasonalItems: [MediaCard.Item] = []

    // MARK: - Discovery and stats

    /// AniList's own recommendations for the viewer's list, already carrying
    /// the "because you watched X" attribution in each card's
    /// `playlistReason`. Empty signed out — the engine answers with nothing
    /// rather than erroring, so the shelf simply does not draw.
    public var becauseYouWatched: [MediaCard.Item] = []

    /// The month calendar's airing slots, keyed `"YYYY-MM"` of the *visible*
    /// month. Each entry holds that month plus a week either side, so a slot
    /// shown in a leading or trailing pad cell is already there and paging
    /// back and forth does not refetch. In memory only: `FfiAiringSlot` is a
    /// uniffi type with no `Codable` conformance, and the schedule is stale
    /// within the hour anyway.
    public var calendarMonths: [String: [FfiAiringSlot]] = [:]

    /// Month keys with a fetch in flight, so the grid can draw a skeleton
    /// without a second per-month loading flag.
    public var calendarLoadingMonths: Set<String> = []

    /// Which month the calendar is showing. Mirrored out of the view so the
    /// section can hand `CalendarView` the right entry of `calendarMonths` —
    /// the view owns the paging, this is only which key to read.
    public var calendarVisibleMonth: Date = Date()

    /// The Stats page's snapshot, filled on section open. Refreshed there
    /// and nowhere else: `watchStats` reads the local registry synchronously,
    /// so there is nothing to gain from holding it warm.
    public var watchStatsSnapshot: FfiWatchStats?
    /// The last 30 days, for the "most watched" card only. Over a year the
    /// card was a ranking of episode counts, which long-running shows win
    /// by existing; a month says what is actually being watched now.
    public var watchStatsRecentSnapshot: FfiWatchStats?

    /// One configurable home row: which one, its display title, and whether
    /// the user has it shown. Reorder is the array order itself.
    public struct HomeRowConfig: Codable, Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var visible: Bool
    }

    static let defaultHomeRows: [HomeRowConfig] = [
        HomeRowConfig(id: "becauseYouWatched", title: "Because you watched", visible: true),
        HomeRowConfig(id: "planning", title: "Planning", visible: true),
        HomeRowConfig(id: "smartPlaylist", title: "Smart Picks", visible: true),
        HomeRowConfig(id: "trending", title: "Trending Now", visible: true),
        HomeRowConfig(id: "newlyReleasing", title: "Newly Releasing", visible: true),
        HomeRowConfig(id: "seasonal", title: "Seasonal Highlights", visible: true),
    ]

    static let homeRowsDefaultsKey = "anicat_home_rows"

    public var homeRowConfig: [HomeRowConfig] = AppModel.loadHomeRowConfig()

    // MARK: - Cinema
    //
    // Films and series from TMDB, reached by pressing the mark at the foot of
    // the sidebar. The behaviour lives in `AppModel+Cinema.swift`; only the
    // storage is here.

    /// Which of the two worlds the app is showing. Anime and manga come from
    /// AniList, cinema from TMDB, and nothing is mixed between them: the two
    /// catalogs number their titles independently and a blended shelf could
    /// not say which id it was holding.
    public enum AppMode: String, Sendable, CaseIterable {
        case anime
        case cinema
    }

    static let appModeDefaultsKey = "anicat_app_mode"

    public var appMode: AppMode = AppModel.loadAppMode() {
        didSet {
            guard appMode != oldValue else { return }
            UserDefaults.standard.set(appMode.rawValue, forKey: Self.appModeDefaultsKey)
        }
    }

    /// Whether the engine has a TMDB credential to read with. Cinema mode is
    /// hidden entirely without one: every TMDB call fails the same way, and a
    /// page of empty shelves says nothing about why.
    public var cinemaAvailable: Bool = false

    public var cinemaShelves: [CinemaShelf] = []
    public var isCinemaLoading: Bool = false
    /// Why the rows are empty, when they are. A rejected key and a dead
    /// network both leave eight empty shelves behind, and "try again in a
    /// moment" is the wrong thing to tell someone whose key TMDB refused --
    /// the engine names that case `tmdb_unauthorized` precisely so this can
    /// tell them apart.
    public var cinemaError: String?
    public var cinemaSearchResults: [MediaCard.Item] = []

    /// Watch history for TMDB titles, and the names to draw it with.
    ///
    /// The registry records `(catalog, id, episode)` and no title -- it has
    /// no idea what anything is called -- and `knownTitles` is filled from
    /// AniList shelves, so a film would have shown as a bare number. These
    /// are filled from the cinema shelves and the detail snapshots instead.
    public var cinemaActivity: [ActivityRow] = []
    /// TMDB numbers films and series in two independent spaces, so id 550 is
    /// both Fight Club and a television series. Keyed by the bare id, one
    /// evicted the other and `cinemaTitle` returned whichever had been
    /// fetched last while ignoring the catalog it had been handed.
    public struct CinemaTitleKey: Hashable, Sendable {
        public let catalog: MediaCard.CardCatalog
        public let id: Int64
        public init(catalog: MediaCard.CardCatalog, id: Int64) {
            self.catalog = catalog
            self.id = id
        }
    }

    public var cinemaKnownTitles: [CinemaTitleKey: String] = [:]
    public var cinemaKnownCovers: [CinemaTitleKey: URL] = [:]
    /// Films and episodes with a stored position, most recent first.
    public var cinemaContinueWatching: [MediaCard.Item] = []
    /// The Search section's filter row and its paging.
    ///
    /// A keyword search and a filtered browse are two different TMDB
    /// endpoints -- `/search` takes a query and nothing else, `/discover`
    /// takes genre, year and sort and no query -- so which one runs is
    /// decided by whether there is text in the field.
    public struct CinemaFilter: Equatable, Sendable {
        public var isSeries: Bool = false
        public var genreId: Int64?
        public var year: Int?
        public var sort: String = "popularity.desc"
    }

    public var cinemaFilter = CinemaFilter()
    /// The cast member whose page is open, if any. A sheet rather than a
    /// push onto `personPageStack`: that stack is AniList's and keyed by its
    /// character ids, which a TMDB person id is not.
    public var openCinemaPersonId: Int64?
    public var openCinemaPersonName: String = ""

    /// The open cinema page's local list status, and the list itself.
    /// Local because there is nowhere else: AniList has no entry for a TMDB
    /// title, so this is the registry's `local_library` and this device.
    public var cinemaListStatus: String?
    public var cinemaWatchlist: [MediaCard.Item] = []
    public var cinemaWatchlistFilter: String = "PLANNING"
    public var cinemaGenres: [FfiCinemaGenre] = []
    public var cinemaSearchPage: Int32 = 1
    public var cinemaSearchHasMore = false
    public var isLoadingMoreCinema = false

    /// The resume queue at the top of cinema's home, in the same shape the
    /// anime one uses: what to play next, how far in, how long ago.
    public var cinemaUpNext: [UpNextQueueView.QueueEntry] = []

    /// The facts TMDB carries that `MediaDetail` has no field for, for the
    /// open cinema page. Nil on an AniList page, which is what hides the
    /// Details tab there.
    public var cinemaExtras: CinemaExtras?

    /// The catalog the open detail page belongs to.
    ///
    /// Read from the page rather than tracked beside it. As a stored
    /// property this was a second source of truth that every path had to
    /// remember to set, and the ones that forgot are the bugs this became a
    /// computed property to end: a recommendation opening the anime with a
    /// film's number, Back reloading a film through AniList, closing the
    /// player landing on a random title.
    public var currentDetailCatalog: MediaCard.CardCatalog {
        selectedMediaDetails?.mediaCatalog ?? .anilist
    }

    // Library / Manga / Novels / History
    public var libraryItems: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var libraryStatus: String = "CURRENT"
    public var libraryType: String = "ANIME"
    public var mangaTrending: [MediaCard.Item] = []
    public var mangaReading: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var novelTrending: [MediaCard.Item] = []
    public var novelReading: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var mangaPlanning: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var novelPlanning: [MediaCard.Item] = [] { didSet { syncKnownTitles() } }
    public var viewer: ViewerProfile?
    public var activity: [ActivityRow] = []
    /// Which chapters are downloaded, or downloading, for the open title.
    /// Keyed by chapter id -- what the files and the registry are keyed on.
    public var chapterOfflineStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    /// Every downloaded chapter, for the Downloads page.
    public var offlineChapters: [FfiOfflineChapter] = []
    public var offlineBytes: UInt64 = 0
    public var offlineCapBytes: UInt64 = 0
    /// What the offline library may hold, in gigabytes. `0` means no cap.
    /// Settings owns the control; the engine is told at launch and on change.
    static let offlineCapDefaultsKey = "anicat_offline_cap_gb"

    /// Chapters read on this device, for the History log and its day chart.
    public var readingActivity: [HistoryView.ReadingEntry] = []

    /// Titles for ids the History log has rows for, gathered from every list
    /// already loaded. The registry stores a `catalog_id` and nothing else —
    /// it has no idea what a show is called — so the name has to come from
    /// whatever the catalog views have already fetched. Maintained by
    /// `syncKnownTitles()` on write rather than rebuilt from all six source
    /// arrays on every read.
    public internal(set) var knownTitles: [Int64: String] = [:]
    /// Titles looked up on demand for a registry row no shelf has loaded
    /// (`ensureKnownTitle`), folded into `knownTitles` by `syncKnownTitles`
    /// so a shelf refresh does not drop them again.
    var resolvedTitles: [Int64: String] = [:]
    var resolvedCovers: [Int64: URL] = [:]
    var pendingTitleLookups: Set<Int64> = []
    /// Same sourcing as `knownTitles`, for the Now Playing artwork of a
    /// title played without its page open.
    public internal(set) var knownCovers: [Int64: URL] = [:]

    /// Whether AniList answered with a viewer. The four catalog-backed views
    /// have nothing to show without it and say so rather than sitting empty.
    public var isSignedIn = false

    /// Settings' "Discord Rich Presence" switch. Written by `@AppStorage`
    /// in `SettingsView`, read here.
    public nonisolated static let discordPresenceKey = "anicat_discord_presence"

    /// Defaults to on. `UserDefaults.bool(forKey:)` answers `false` for a
    /// key nothing has written yet, and `@AppStorage`'s default lives in the
    /// view, not in the store — so a plain `bool` read would have shipped
    /// presence off for everyone who never opened Settings.
    public static var isDiscordPresenceEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: discordPresenceKey) != nil else { return true }
        return defaults.bool(forKey: discordPresenceKey)
    }

    /// Last value acted on, so the observer below can tell a change to this
    /// key from the many other keys `didChangeNotification` fires for.
    private var lastDiscordPresenceEnabled = AppModel.isDiscordPresenceEnabled
    // `nonisolated(unsafe)`: `deinit` is nonisolated and has to reach it.
    // Written once from `init` on the main actor, read once in deinit.
    @ObservationIgnored private nonisolated(unsafe) var defaultsObserver: NSObjectProtocol?

    public init() {
        setupPlayerCallbacks()
        // `didChangeNotification` carries no key, so the edge check is the
        // only thing separating a presence toggle from every other setting
        // written while the app runs — without it, changing the theme would
        // reconnect Discord.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let enabled = AppModel.isDiscordPresenceEnabled
            guard enabled != self.lastDiscordPresenceEnabled else { return }
            self.lastDiscordPresenceEnabled = enabled
            self.applyDiscordPresenceSetting(enabled)
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    /// Connects or disconnects Discord to match the setting. Turning it off
    /// mid-episode has to clear what is already showing, not just stop
    /// future updates: `discordDisconnect` drops the IPC socket, which is
    /// what makes the activity disappear from the profile.
    func applyDiscordPresenceSetting(_ enabled: Bool) {
        guard let engine else { return }
        engineIOQueue.async {
            if enabled {
                engine.discordConnect()
            } else {
                engine.discordClearPresence()
                engine.discordDisconnect()
            }
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
    public internal(set) var playbackEpisodes: [MediaDetailView.EpisodeItem] = []
    var playbackEpisodesCatalogId: Int64?

    /// Initializes the headless Rust engine and opens the SQLite registry.
    public func initialize(anilistToken: String? = nil, tmdbKey: String? = nil) async {
        guard engine == nil else { return }
        purgeStaleSpotlightIndexOnce()

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
                // Nobody is asked to register with TMDB to watch a film: the
                // build carries a proxy that holds the key, or a key of its
                // own, and Settings can override either with the viewer's.
                // See `TmdbCredential` for the order and why none of it is in
                // the repo.
                tmdbKey: tmdbKey ?? TmdbCredential.key,
                tmdbProxy: TmdbCredential.proxyURL
            )
            self.engine = coreEngine
            self.cinemaAvailable = coreEngine.hasTmdbKey()
            // A mode the viewer left the app in is only restorable while it
            // still exists: a build with no key must not open onto eight
            // shelves that cannot load.
            if !self.cinemaAvailable { self.appMode = .anime }
            if let token, !token.isEmpty {
                self.isSignedIn = true
                // A token already in the Keychain means the first run
                // happened on some earlier build; nothing left to onboard.
                UserDefaults.standard.set(true, forKey: Self.onboardingSeenKey)
            } else if !UserDefaults.standard.bool(forKey: Self.onboardingSeenKey) {
                self.onboardingOpen = true
            }

            // The offline cap the engine holds is in memory, so it has to be
            // told what Settings says on every launch.
            applyOfflineLimit()
            // What is already on disk, from downloads made in earlier
            // sessions -- the engine's own map does not survive a relaunch.
            loadDownloadedEpisodes()

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
            lastDiscordPresenceEnabled = Self.isDiscordPresenceEnabled
            if lastDiscordPresenceEnabled {
                coreEngine.discordConnect()
            }

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
        smartPicksSeed = []
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
    var detailHistory: [DetailStep] = []

    /// One step of detail navigation. The catalog is part of it because an id
    /// alone names three different titles -- an AniList entry, a TMDB film
    /// and a TMDB series -- so a back step that only remembered the number
    /// reloaded it through whichever path happened to run, which is how a
    /// film's Back could land on an anime.
    struct DetailStep {
        let id: Int64
        let isManga: Bool
        let catalog: MediaCard.CardCatalog
        let tab: MediaDetailView.DetailTab?
    }

    /// The mirror image of `detailHistory`: entries popped by `closeDetail()`
    /// land here so a forward swipe/gesture can redo them, browser-style.
    /// Any *fresh* navigation (a new relation click, not a back/forward step)
    /// clears it — once you branch off the path you were on, "forward" no
    /// longer means anything.
    var detailForwardStack: [DetailStep] = []

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
    public internal(set) var restoredDetailTab: MediaDetailView.DetailTab?

    /// Redoes one level in `detailForwardStack` — the swipe-forward gesture's
    /// and the mouse forward button's counterpart to `closeDetail()`. A no-op
    /// when there's nothing to redo (browser back/forward buttons work the
    /// same way: disabled/inert past the end of either stack).
    public var canGoForward: Bool { !detailForwardStack.isEmpty }

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
        /// The catalog is part of the identity, not decoration beside it.
        /// Without it a film and an anime episode sharing a number collapsed
        /// into one row, and `handleDownloadsChanged` — which dedupes
        /// announcements on this string — swallowed the second completion.
        public var id: String { "\(catalog.rawValue)_\(catalogId)_\(episode)" }
        public let catalogId: Int64
        public let episode: Int
        public let title: String
        public let coverURL: URL?
        public var state: MediaDetailView.EpisodeDownloadState
        /// Which catalog the id belongs to. Playing a downloaded film under
        /// AniList's would record the position against whatever anime shares
        /// the number, and ask AniList for its episode list.
        public var catalog: MediaCard.CardCatalog = .anilist
    }

    public var libraryDownloads: [LibraryDownload] = []

    // MARK: - System
    //
    // State for the macOS integration surfaces — URL scheme, App Intents,
    // notifications, dock badge. The behaviour lives in
    // `AppModel+System.swift`; only the storage is here.

    /// The running model, for callers that arrive from outside the view tree
    /// and so have no way to be handed it: an App Intent is constructed by
    /// the Shortcuts/Siri runtime, not by SwiftUI. `nonisolated(unsafe)`
    /// rather than an actor-isolated global because every read is already on
    /// the main actor and isolating it would make `AnicatApp.init` — which is
    /// where it is set — unable to write it.
    public nonisolated(unsafe) static weak var shared: AppModel?

    /// A destination that arrived before `initialize()` had finished. Every
    /// route into the app (`openDetail`, `playFromShelf`) bails on a nil
    /// engine, so a notification tap that launches the app
    /// cold used to open the app and then do nothing at all. Drained once the
    /// engine is up.
    public var pendingDeepLink: DeepLink?

    /// The `<id>:<episode>` keys that had a new episode the last time
    /// `refreshSystemIntegrations` looked. `nil` means "never looked": the
    /// first observation of a session seeds this without notifying, because
    /// every backlogged show on the watching list would otherwise fire a
    /// notification at launch.
    var lastKnownNewEpisodeKeys: Set<String>?

    /// Same seed-then-compare shape as `lastKnownNewEpisodeKeys`, for
    /// downloads that have reached `.done`.
    var lastKnownCompletedDownloadIds: Set<String>?

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
        // Above the detail page, below every modal: a character/staff/thread
        // page renders inside the content column on top of the detail page,
        // so Escape has to pop it before the page it covers. Checked here,
        // inside the one ordered ladder, rather than at the key monitor —
        // a second copy of this order is what drifts.
        // Called from the key monitor on the main thread; the state is
        // main-actor and this method is not.
        let trailerWasOpen = MainActor.assumeIsolated { () -> Bool in
            guard TrailerState.shared.isOpen else { return false }
            TrailerState.shared.isOpen = false
            return true
        }
        if trailerWasOpen { return true }
        if !personPageStack.isEmpty {
            closePersonPage()
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
        // Before `clearDetail()`, and unconditional: the person page draws
        // over the detail page, so a section switch with a character page
        // open left that character floating over the new section.
        clearPersonPages()
        clearDetail()
        currentNavSection = section
    }

}
