import SwiftUI
import AnicatCoreKit

public struct MediaDetailView: View {
    /// Four words for every kind of title. Discussions and recommendations
    /// were tabs of their own, and a cinema page grew a fifth "Details" tab:
    /// seven tabs, a different set per kind, and the same fact (the forum,
    /// the studio) a tab away from where the mockups put it.
    public enum DetailTab: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case manga = "Chapters"
        case about = "About"
        case related = "Related"
        case people = "People"

        public var id: String { rawValue }
    }

    public enum AudioType: String, CaseIterable {
        case sub = "Sub (JP)"
        case dub = "Dub (EN)"

        /// The vocabulary `anicat_sub_dub` is stored in — Settings' own
        /// picker writes these strings and `AppModel` compares against
        /// "Dubbed" verbatim. The display raw values above are not the same
        /// words, so storing those would leave the toggle looking wired
        /// while every reader still saw a sub preference.
        var storedValue: String { self == .dub ? "Dubbed" : "Subtitled" }

        init(stored: String) {
            self = stored == "Dubbed" ? .dub : .sub
        }
    }

    public enum EpisodeViewMode: String, CaseIterable {
        case cards = "Cards"
        case compact = "Compact"
    }

    /// One release from the indexers, for the "Stream Servers" picker.
    public struct ReleaseCandidateItem: Identifiable, Sendable, Equatable {
        public let id: String
        public let seeders: Int
        public let isDub: Bool
        /// False where the index reports no swarm and `seeders` is the
        /// engine's stand-in (SubsPlease, SeaDex): shown as "seeders
        /// unknown" rather than as a count nobody measured.
        public let seedersKnown: Bool
        /// Total torrent size, where the index lists it.
        public let sizeBytes: Int64?

        public init(name: String, seeders: Int, isDub: Bool, seedersKnown: Bool = true, sizeBytes: Int64? = nil) {
            self.id = name
            self.seeders = seeders
            self.isDub = isDub
            self.seedersKnown = seedersKnown
            self.sizeBytes = sizeBytes
        }

        public var name: String { id }
    }

    /// Progress of a "Download Episode" — mirrors the engine's
    /// `FfiDownloadStatus` without this view needing to import
    /// AnicatCoreKit for it.
    public enum EpisodeDownloadState: Sendable, Equatable {
        case notStarted
        case downloading(percent: Double)
        case done(path: String)
        case failed(message: String)
    }

    public struct EpisodeItem: Identifiable, Sendable, Codable, Equatable {
        public let id: Int64
        public let number: Int
        public let title: String
        public let thumbnailURL: URL?
        public let isWatched: Bool
        public let progressPercent: Double?
        public let synopsis: String?
        public let airDate: String?
        /// Unix seconds of the broadcast, when AniList has a schedule for it.
        public let airingAt: Int64?
        public let runtimeMinutes: Int?
        /// Whether the episode exists yet. An airing show lists its whole
        /// announced run, so the last few rows are a schedule, not something
        /// that can be played -- see `EpisodeRow.is_aired`.
        ///
        /// Stored optional and read through `isAired` because this is
        /// `Codable` and `DetailCache` is on disk: a synthesized decoder
        /// throws on a key that a snapshot written by an older build does not
        /// have, which would have made every cached page fail to load once.
        private let isAiredRaw: Bool?
        public var isAired: Bool { isAiredRaw ?? true }

        public init(
            id: Int64,
            number: Int,
            title: String,
            thumbnailURL: URL? = nil,
            isWatched: Bool = false,
            progressPercent: Double? = nil,
            synopsis: String? = nil,
            airDate: String? = nil,
            airingAt: Int64? = nil,
            runtimeMinutes: Int? = nil,
            isAired: Bool = true
        ) {
            self.synopsis = synopsis
            self.airDate = airDate
            self.airingAt = airingAt
            self.runtimeMinutes = runtimeMinutes
            self.isAiredRaw = isAired
            self.id = id
            self.number = number
            self.title = title
            self.thumbnailURL = thumbnailURL
            self.isWatched = isWatched
            self.progressPercent = progressPercent
        }
    }

    public struct MangaChapterItem: Identifiable, Sendable, Codable {
        public let id: String
        public let number: String
        public let title: String
        public let scanlationGroup: String?

        public init(id: String, number: String, title: String, scanlationGroup: String? = nil) {
            self.id = id
            self.number = number
            self.title = title
            self.scanlationGroup = scanlationGroup
        }
    }

    public struct CharacterItem: Identifiable, Sendable, Codable {
        public let id: Int64
        public let name: String
        public let imageURL: URL?
        public let role: String
        public let voiceActorName: String?
        public let voiceActorImageURL: URL?

        public init(
            id: Int64,
            name: String,
            imageURL: URL? = nil,
            role: String = "Main",
            voiceActorName: String? = nil,
            voiceActorImageURL: URL? = nil
        ) {
            self.id = id
            self.name = name
            self.imageURL = imageURL
            self.role = role
            self.voiceActorName = voiceActorName
            self.voiceActorImageURL = voiceActorImageURL
        }
    }

    public struct RelationItem: Identifiable, Sendable, Codable {
        public let id: Int64
        public let relationType: String
        public let title: String
        public let format: String?
        public let coverURL: URL?
        public let status: String?
        public let averageScore: Int?

        public init(
            id: Int64,
            relationType: String,
            title: String,
            format: String? = nil,
            coverURL: URL? = nil,
            status: String? = nil,
            averageScore: Int? = nil
        ) {
            self.id = id
            self.relationType = relationType
            self.title = title
            self.format = format
            self.coverURL = coverURL
            self.status = status
            self.averageScore = averageScore
        }
    }

    /// One title on the "More from <studio>" shelf. A view-level shape
    /// rather than the engine's `MediaSummary` so this file keeps needing
    /// nothing from `AnicatCoreKit`.
    public struct StudioWorkItem: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let title: String
        public let coverImage: String
        public let format: String?

        public init(id: Int64, title: String, coverImage: String, format: String? = nil) {
            self.id = id
            self.title = title
            self.coverImage = coverImage
            self.format = format
        }
    }

    public struct RecommendationItem: Identifiable, Sendable, Codable {
        public let id: Int64
        public let title: String
        public let format: String?
        public let coverURL: URL?
        public let averageScore: Int?
        public let rating: Int?

        public init(
            id: Int64,
            title: String,
            format: String? = nil,
            coverURL: URL? = nil,
            averageScore: Int? = nil,
            rating: Int? = nil
        ) {
            self.id = id
            self.title = title
            self.format = format
            self.coverURL = coverURL
            self.averageScore = averageScore
            self.rating = rating
        }
    }

    public struct DiscussionItem: Identifiable, Sendable, Codable {
        public let id: Int64
        public let title: String
        public let replyCount: Int
        public let viewCount: Int
        public let authorName: String?
        public let authorAvatarURL: URL?
        public let repliedAt: Int64?

        public init(
            id: Int64,
            title: String,
            replyCount: Int,
            viewCount: Int,
            authorName: String? = nil,
            authorAvatarURL: URL? = nil,
            repliedAt: Int64? = nil
        ) {
            self.id = id
            self.title = title
            self.replyCount = replyCount
            self.viewCount = viewCount
            self.authorName = authorName
            self.authorAvatarURL = authorAvatarURL
            self.repliedAt = repliedAt
        }
    }

    // Properties
    public let details: HeroBanner.Details
    public let episodes: [EpisodeItem]
    public let mangaChapters: [MangaChapterItem]
    /// The light-novel tab's state, grouped rather than passed as three
    /// separate props: this initializer is already at the point where the
    /// type-checker gives up ("unable to type-check this expression in
    /// reasonable time"), and three more arguments took it over.
    public struct NovelTabState {
        public var volumes: [NovelChapterRef]
        public var isLoading: Bool
        public var sourceMissing: Bool

        public init(volumes: [NovelChapterRef] = [], isLoading: Bool = false, sourceMissing: Bool = false) {
            self.volumes = volumes
            self.isLoading = isLoading
            self.sourceMissing = sourceMissing
        }
    }

    public var novel: NovelTabState = .init()
    public var onReadVolume: ((NovelChapterRef) -> Void)?
    public let characters: [CharacterItem]
    public let relations: [RelationItem]
    public let recommendations: [RecommendationItem]
    public let discussions: [DiscussionItem]
    public let isLoading: Bool
    /// False for a cinema page. AniList is where the list status, the score
    /// and the favourite heart live, and a TMDB id sent to it would land on
    /// whatever anime happens to carry the same number -- so those controls
    /// are absent here rather than disabled. Sub/Dub goes too: it is a
    /// fansub-era distinction that says nothing about a western release.
    public var tracksOnAniList: Bool = true
    /// TMDB's own facts about a film or series: box office, networks, the
    /// season breakdown, the stills. Nil on an AniList page, which is what
    /// keeps the Details tab out of the bar there.
    public var cinemaExtras: CinemaExtras?
    /// Whether `cinemaExtras` is still on its way. See
    /// `AppModel.isCinemaExtrasLoading`.
    public var isCinemaExtrasLoading: Bool = false
    /// The open cinema title's local list status, and how to change it.
    /// Local because AniList has no entry for a TMDB title -- this is the
    /// registry's own list, on this device.
    public var cinemaListStatus: String?
    /// Which chapters are downloaded, keyed by chapter id.
    public var chapterOfflineStates: [String: ChapterOfflineState] = [:]
    public var onDownloadChapter: ((MangaChapterItem) -> Void)?
    public var onDeleteChapterDownload: ((MangaChapterItem) -> Void)?
    /// Keyed by volume URL, which is what the registry stores a downloaded
    /// volume under.
    public var novelVolumeStates: [String: ChapterOfflineState] = [:]
    public var onDownloadVolume: ((NovelChapterRef) -> Void)?
    public var onDeleteVolumeDownload: ((NovelChapterRef) -> Void)?
    public var onExportVolume: ((NovelChapterRef) -> Void)?
    /// The manga tab's language switch changed; the chapters have to be
    /// fetched again from the other source.
    public var onToggleJapaneseManga: (() -> Void)?
    public var onSetCinemaListStatus: (String?) -> Void = { _ in }
    
    public let onPlayEpisode: (EpisodeItem) -> Void
    /// Same episode as `onPlayEpisode`, ignoring the recorded resume
    /// position. Only ever offered next to a "Resume" primary action, so it
    /// is not wired into the episode rows.
    public let onPlayEpisodeFromStart: (EpisodeItem) -> Void
    public let onReadChapter: (MangaChapterItem) -> Void
    public let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    public let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?
    /// A character card in the Cast & Staff tab. Passed as a closure rather
    /// than reaching for `AppModel` inside the private tab sections, which
    /// know nothing about the model and are cheaper to re-evaluate for it.
    public let onSelectCharacter: (Int64) -> Void
    /// A row in the Discussions tab, by AniList forum thread id.
    public let onSelectThread: (Int64) -> Void
    public let onClose: () -> Void
    /// `CURRENT`/`PLANNING`/`COMPLETED`/`PAUSED`/`DROPPED`/`REPEATING`.
    public let onSetListStatus: (String) -> Void
    public let onToggleFavourite: () -> Void
    public let onRemoveFromList: () -> Void
    /// The mark-watched checkbox on an episode row: the episode number and
    /// its new watched state.
    public let onSetEpisodeWatched: (Int, Bool) -> Void
    /// "Stream Servers": loads the release list for one episode number, for
    /// the row's picker popover.
    public let onLoadReleaseCandidates: (Int) async -> [ReleaseCandidateItem]
    /// A release picked from that popover: the episode and the chosen
    /// release's name (passed straight through to the engine as
    /// `chosen_name`).
    public let onPlayWithRelease: (EpisodeItem, String) -> Void
    public let onDownloadEpisode: (EpisodeItem) -> Void
    /// Keyed by episode number. An episode with no entry has never had a
    /// download started — `EpisodeRow` treats that the same as `.notStarted`.
    /// A closure, not the dictionary: read inside `EpisodeListSection.body`
    /// so the 1s download poll invalidates that section alone. Passed as a
    /// value from `RootView`, the read happened in RootView's body and every
    /// tick re-ran the root, the whole detail page and the sidebar.
    public let downloadStates: () -> [Int: EpisodeDownloadState]
    /// Shared with the `MediaCard` this detail page was opened from, so the
    /// poster grows from that card's actual on-screen frame instead of the
    /// generic offset/opacity swap. `nil` when opened from a context that
    /// isn't wired to a shared namespace (or wasn't opened from a card at
    /// all, e.g. deep-linked).
    public var namespace: Namespace.ID?
    /// The second shared namespace, for the episode-still-to-video morph.
    /// Separate from `namespace` above rather than one namespace carrying
    /// both kinds of key: the poster morph's namespace is handed over only
    /// while a card open is in flight, and the episode morph has to work
    /// from a page that was opened without one.
    public var playerNamespace: Namespace.ID?
    /// Which episode row is that morph's source, as
    /// "episode:<catalogId>:<number>" — see
    /// `AppModel.openingPlayerSourceKey`. At most one row is ever tagged.
    public var playerSourceKey: String?

    /// The one place this key is spelled. The play call site sets it and
    /// the row compares against it; the two living in different files is
    /// how a string built by hand in both drifts.
    public nonisolated static func playerMorphKey(catalogId: Int64, episode: Int) -> String {
        "episode:\(catalogId):\(episode)"
    }

    @State private var selectedTab: DetailTab = .episodes
    let onTabChanged: (DetailTab) -> Void
    // Backed by the same defaults key Settings writes and `AppModel` reads
    // when building a `StreamRequest`, rather than view-local state nothing
    // ever looked at — picking Dub here changed nothing about which release
    // was resolved.
    @AppStorage("anicat_sub_dub") private var storedSubDub: String = "Subtitled"
    @State private var selectedViewMode: EpisodeViewMode = .cards
    // `AppModel.isJapaneseManga` owns the reader and the default (off).
    @AppStorage("anicat_manga_japanese") private var japaneseManga: Bool = false
    /// The film's source picker. A film has no Episodes tab, so no row to
    /// right-click; "Choose source…" sits in the More menu and the picker
    /// hangs off the primary button instead.
    @State private var isFilmPickerOpen = false
    @State private var isLoadingFilmCandidates = false
    @State private var filmCandidates: [ReleaseCandidateItem] = []
    /// Which season the episode list is filtered to, once someone picks one.
    /// Nil means "whichever the resume position is in" -- see
    /// `defaultSeason`, and note it must not be resolved at init: the
    /// seasons arrive with the extras, after the page is already on screen.
    @State private var selectedSeason: Int32?
    @State private var isBackHovered = false
    /// Set from the scroll offset, but only ever as this Bool — see
    /// `ScrollPassedThreshold` for why the offset itself never lands in state.
    @State private var isHeaderCompact = false
    /// The trailer plays over the banner, opened only from the Trailer link.
    @State private var isTrailerOpen = false
    @State private var studioWorks: [StudioWorkItem] = []
    /// The confirmation that a download was queued. Nothing else on the page
    /// moved at the tap: the button became a 15pt ring on a row that may be
    /// scrolled anywhere, so the eye had nothing to catch ("no visual
    /// feedback"). `token` tells two taps apart so a second one restarts
    /// the dismiss timer instead of being swallowed as "no change".
    struct DownloadToast: Equatable {
        let episode: Int
        let token: Int
    }
    @State private var downloadToast: DownloadToast?
    @State private var downloadToastCount = 0
    @State private var downloadToastTask: Task<Void, Never>?
    @Environment(\.studioPageActions) private var studioPageActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(ThemeStore.posterAccentKey) private var posterAccentEnabled = true
    /// Observed so the accent task re-runs when the palette flips sides: the
    /// same hue is drawn at 0.87 brightness on Ink and 0.54 on Paper.
    @State private var themeStore = ThemeStore.shared

    public init(
        details: HeroBanner.Details,
        episodes: [EpisodeItem] = [],
        mangaChapters: [MangaChapterItem] = [],
        novel: NovelTabState = .init(),
        onReadVolume: ((NovelChapterRef) -> Void)? = nil,
        characters: [CharacterItem] = [],
        relations: [RelationItem] = [],
        recommendations: [RecommendationItem] = [],
        discussions: [DiscussionItem] = [],
        isLoading: Bool = false,
        tracksOnAniList: Bool = true,
        cinemaExtras: CinemaExtras? = nil,
        isCinemaExtrasLoading: Bool = false,
        cinemaListStatus: String? = nil,
        chapterOfflineStates: [String: ChapterOfflineState] = [:],
        onDownloadChapter: ((MangaChapterItem) -> Void)? = nil,
        onDeleteChapterDownload: ((MangaChapterItem) -> Void)? = nil,
        novelVolumeStates: [String: ChapterOfflineState] = [:],
        onDownloadVolume: ((NovelChapterRef) -> Void)? = nil,
        onDeleteVolumeDownload: ((NovelChapterRef) -> Void)? = nil,
        onExportVolume: ((NovelChapterRef) -> Void)? = nil,
        onToggleJapaneseManga: (() -> Void)? = nil,
        onSetCinemaListStatus: @escaping (String?) -> Void = { _ in },
        onPlayEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        onPlayEpisodeFromStart: @escaping (EpisodeItem) -> Void = { _ in },
        onReadChapter: @escaping (MangaChapterItem) -> Void = { _ in },
        onSelectRelation: ((HeroBanner.Details.Relation) -> Void)? = nil,
        onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)? = nil,
        onSelectCharacter: @escaping (Int64) -> Void = { _ in },
        onSelectThread: @escaping (Int64) -> Void = { _ in },
        onClose: @escaping () -> Void = {},
        onSetListStatus: @escaping (String) -> Void = { _ in },
        onToggleFavourite: @escaping () -> Void = {},
        onRemoveFromList: @escaping () -> Void = {},
        onSetEpisodeWatched: @escaping (Int, Bool) -> Void = { _, _ in },
        onLoadReleaseCandidates: @escaping (Int) async -> [ReleaseCandidateItem] = { _ in [] },
        onPlayWithRelease: @escaping (EpisodeItem, String) -> Void = { _, _ in },
        onDownloadEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        downloadStates: @escaping () -> [Int: EpisodeDownloadState] = { [:] },
        namespace: Namespace.ID? = nil,
        playerNamespace: Namespace.ID? = nil,
        playerSourceKey: String? = nil,
        /// Restores whichever tab was open the last time this title was
        /// visited (threaded through by the caller's back/forward stack).
        /// `nil` falls back to the usual "episodes, unless this is a
        /// manga/novel" default — this view is `.id(details.id)`-keyed, so
        /// its own `@State selectedTab` never survives a title change on its
        /// own.
        restoredTab: DetailTab? = nil,
        onTabChanged: @escaping (DetailTab) -> Void = { _ in }
    ) {
        self.onTabChanged = onTabChanged
        self.details = details
        self.episodes = episodes
        self.mangaChapters = mangaChapters
        self.novel = novel
        self.onReadVolume = onReadVolume
        self.characters = characters
        self.relations = relations
        self.recommendations = recommendations
        self.discussions = discussions
        self.isLoading = isLoading
        self.tracksOnAniList = tracksOnAniList
        self.cinemaExtras = cinemaExtras
        self.isCinemaExtrasLoading = isCinemaExtrasLoading
        self.cinemaListStatus = cinemaListStatus
        self.chapterOfflineStates = chapterOfflineStates
        self.onDownloadChapter = onDownloadChapter
        self.onDeleteChapterDownload = onDeleteChapterDownload
        self.novelVolumeStates = novelVolumeStates
        self.onDownloadVolume = onDownloadVolume
        self.onDeleteVolumeDownload = onDeleteVolumeDownload
        self.onExportVolume = onExportVolume
        self.onToggleJapaneseManga = onToggleJapaneseManga
        self.onSetCinemaListStatus = onSetCinemaListStatus
        self.onPlayEpisode = onPlayEpisode
        self.onPlayEpisodeFromStart = onPlayEpisodeFromStart
        self.onReadChapter = onReadChapter
        self.onSelectRelation = onSelectRelation
        self.onSelectMediaId = onSelectMediaId
        self.onSelectCharacter = onSelectCharacter
        self.onSelectThread = onSelectThread
        self.onClose = onClose
        self.onSetListStatus = onSetListStatus
        self.onToggleFavourite = onToggleFavourite
        self.onRemoveFromList = onRemoveFromList
        self.onSetEpisodeWatched = onSetEpisodeWatched
        self.onLoadReleaseCandidates = onLoadReleaseCandidates
        self.onPlayWithRelease = onPlayWithRelease
        self.onDownloadEpisode = onDownloadEpisode
        self.downloadStates = downloadStates
        self.namespace = namespace
        self.playerNamespace = playerNamespace
        self.playerSourceKey = playerSourceKey

        let initial: DetailTab
        if let restoredTab {
            initial = restoredTab
        } else if !episodes.isEmpty {
            initial = .episodes
        } else if !mangaChapters.isEmpty {
            initial = .manga
        } else if details.format == "MANGA" || details.format == "NOVEL" || details.format == "ONE_SHOT" {
            initial = .manga
        } else {
            initial = .episodes
        }
        self._selectedTab = State(initialValue: initial)
    }


    /// How far the poster row rises into the banner slot: the top half of
    /// the poster sits on the still, the title on its dimmed foot.
    private let bannerOverlap: CGFloat = 120

    /// How far the page has to scroll before the compact header takes over:
    /// far enough that the title in the poster column has left the top of the
    /// viewport, so the two never name the title at once.
    private static let compactHeaderThreshold: CGFloat = 260

    /// How many of a studio's works the shelf offers. AniList returns
    /// hundreds for a prolific studio, and the studio's own page is one tap
    /// away for the rest.
    private static let studioShelfCount = 12

    public var body: some View {
        ZStack(alignment: .top) {
            scrollBody
            compactHeaderLayer
            // The trailer as its own overlay, centred and 16:9, instead of
            // replaced into the banner: there the hero's poster, title and
            // gradient stayed drawn over the embed, and the window's own
            // chrome crossed the picture. It also arrives with a spring
            // instead of a hard swap.
            if isTrailerOpen, let trailerId = details.trailerId {
                trailerOverlay(trailerId: trailerId)
                    .zIndex(50)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if let toast = downloadToast {
                VStack(spacing: 0) {
                    downloadToastView(toast)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .zIndex(55)
                .transition(.opacity)
            }
        }
        .onChange(of: activeTab) { _, _ in closeTrailer() }
        // A season picked on one show must not carry to the next: the page
        // is reused for whatever opens, and season 4 of a four-season show
        // filters a two-season one down to nothing.
        .onChange(of: details.id) { _, _ in selectedSeason = nil }
        // The language switch moved from the chapter list into the tab bar;
        // the refetch moved with it, or the switch would flip and the list
        // stay in the old language.
        // Only while the Chapters tab is open, the scope it had inside the
        // chapter list: the key is shared with Settings, and a page-wide
        // observer refetched chapters for an anime page whenever it changed.
        .onChange(of: japaneseManga) { _, _ in
            if activeTab == .manga { onToggleJapaneseManga?() }
        }
        .onChange(of: TrailerState.shared.isOpen) { _, open in
            if !open { closeTrailer() }
        }
        .onDisappear { TrailerState.shared.isOpen = false }
    }

    private func trailerOverlay(trailerId: String) -> some View {
        GeometryReader { geo in
            let width = min(geo.size.width - 64, 1040)
            let height = width * 9 / 16
            ZStack {
                Color.black.opacity(0.78)
                    .ignoresSafeArea()
                    .onTapGesture { closeTrailer() }
                VStack(spacing: 10) {
                    TrailerPlayer(
                        site: details.trailerSite,
                        videoId: trailerId,
                        thumbnail: details.trailerThumbnail.flatMap(URL.init(string:))
                    )
                        .frame(width: width, height: height)
                        .clipShape(SumiRect(cornerRadius: SumiTheme.radiusXl))
                        .overlay(SumiRect(cornerRadius: SumiTheme.radiusXl).stroke(SumiTheme.border, lineWidth: 1))
                    HStack(spacing: 12) {
                        Text(details.title)
                            .font(.sumiHeading(size: 13, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                        Text("Trailer")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)
                        Spacer(minLength: 0)
                        // Always offered, not only once the embed has
                        // refused: the refusal is read off the player frame
                        // by polling, and a frame that never settles gives
                        // up quietly. This is the way out the viewer can
                        // reach without waiting on that.
                        if let watchURL = TrailerPlayer.watchURL(site: details.trailerSite, videoId: trailerId) {
                            Button {
                                Platform.openExternal(watchURL)
                            } label: {
                                Text("Watch on \(TrailerPlayer.siteName(details.trailerSite))")
                            }
                            .sumiSecondaryButton()
                        }
                        Button {
                            closeTrailer()
                        } label: {
                            Text("Close")
                        }
                        .sumiSecondaryButton()
                        .sumiKeyboardShortcut(.escape, modifiers: [])
                    }
                    .frame(width: width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Trailer

    /// False for a title with no trailer, and for one whose trailer is on a
    /// site `TrailerPlayer` cannot embed — the link would otherwise open a
    /// black rectangle.
    private var hasTrailer: Bool {
        guard let trailerId = details.trailerId else { return false }
        return TrailerPlayer.embedURL(site: details.trailerSite, videoId: trailerId) != nil
    }

    private func openTrailer() {
        withAnimation(.sumi(.pop)) {
            isTrailerOpen = true
        }
        TrailerState.shared.isOpen = true
    }

    private func closeTrailer() {
        guard isTrailerOpen else { return }
        withAnimation(.sumi(.pop)) {
            isTrailerOpen = false
        }
        TrailerState.shared.isOpen = false
    }

    /// Every path that starts a stream goes through here first. The detail
    /// page stays mounted underneath the player, so a trailer left open is a
    /// second soundtrack over the episode.
    private func startingPlayback(_ action: () -> Void) {
        closeTrailer()
        action()
    }

    /// Queues the download and confirms it. Dismissed on a timer rather
    /// than when the row reaches `.downloading`: that happens within a frame
    /// of the tap and would take the toast down before it was read.
    private func downloadEpisode(_ episode: EpisodeItem) {
        onDownloadEpisode(episode)
        downloadToastCount += 1
        withAnimation(.snappy) {
            downloadToast = DownloadToast(episode: episode.number, token: downloadToastCount)
        }
        downloadToastTask?.cancel()
        downloadToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { downloadToast = nil }
        }
    }

    /// A line across the top of the page, the same shape as the window's
    /// error line. It was a capsule with a drop shadow at the foot of the
    /// page, the floating-toast look the error line replaced.
    private func downloadToastView(_ toast: DownloadToast) -> some View {
        HStack {
            Text("Episode \(toast.episode) added to Downloads")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(SumiTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
        .padding(.top, 28)
    }

    private var scrollBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    banner
                    content
                }
                .background(alignment: .top) { heroBackdrop }
                tabsSection
                moreFromStudio
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollPassedThreshold(Self.compactHeaderThreshold, passed: $isHeaderCompact)
        .scrollLagProbe("detail")
        .sumiGround()
        .task(id: AccentKey(cover: details.coverURL, isLight: themeStore.palette.isLight, enabled: posterAccentEnabled)) {
            await followPosterAccent()
        }
        // Keyed on the cover, not the page: a clear that arrives after the
        // next title's set is dropped by the store, see `setAccentOverride`.
        .onDisappear {
            PlayerLog.write("[accent] disappear \(details.id)")
            ThemeStore.shared.releaseAccentOverride(owner: details.coverURL?.absoluteString ?? "")
        }
        #if os(macOS)
        .onAppear {
            _ = ScrollPocketWorkaround.disableScrollPocketsOnce
        }
        #endif
        // Keeps the caller's back/forward stack informed of the tab actually
        // open on this page, so navigating away and back can restore it —
        // `initial: true` because this view mounts fresh (`.id(details.id)`)
        // every time the title changes, and the very first value (whether
        // computed default or a restored one) needs reporting too, not just
        // subsequent taps.
        .onChange(of: selectedTab, initial: true) { _, newTab in
            onTabChanged(newTab)
        }
    }

    // MARK: - Poster accent

    private struct AccentKey: Hashable {
        var cover: URL?
        var isLight: Bool
        var enabled: Bool
    }

    /// Hands the cover's hue to the theme store.
    ///
    /// Reads the cover through the image cache at the poster's own size, so
    /// on the usual path (poster already decoded for the page) this is a
    /// cache hit and a 1536-pixel pass; only a page opened before its card
    /// was ever drawn pays for a decode here.
    private func followPosterAccent() async {
        let owner = details.coverURL?.absoluteString ?? ""
        PlayerLog.write("[accent] follow \(details.id) enabled \(posterAccentEnabled) cover \(owner.suffix(40))")
        guard posterAccentEnabled,
              let cover = details.coverURL,
              let image = await ImageDecodeCache.shared.image(for: cover, maxPixelSize: 600),
              !Task.isCancelled else {
            ThemeStore.shared.setAccentOverride(nil, owner: owner)
            return
        }
        let accent = PosterAccent.accent(for: image, isLight: themeStore.palette.isLight)
        ThemeStore.shared.setAccentOverride(accent, owner: owner)
    }

    // MARK: - Banner

    /// How far down the page the banner still reaches: 64pt past the old
    /// 288pt clip. Not further: the still is drawn `.fill` into this
    /// height, and an AniList banner is about 4.75:1, so every extra point
    /// of height is more zoom and less picture. At 588pt the crop had lost
    /// the title logo off the left edge and the owner called it too much;
    /// at 400pt still too much. 352 keeps the framing within a fifth of
    /// the old one.
    private static let heroHeight: CGFloat = 288 + 64

    /// The banner's layout slot. The still itself is not in here: it is
    /// `heroBackdrop`, drawn behind this slot and the poster row as one
    /// image, so there is no edge at the slot's foot to hide.
    ///
    /// 200 rather than the old 288: the header is now poster, title, one meta
    /// line and the buttons, bottom-aligned, and with the synopsis gone from
    /// it a 288pt slot left the title floating halfway down the window.
    private static let bannerSlotHeight: CGFloat = 200

    private var banner: some View {
        ZStack(alignment: .topLeading) {
            // The slot keeps its height without content so the page's
            // layout (`bannerOverlap`, the compact-header threshold) does not
            // depend on whether the still has loaded.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: Self.bannerSlotHeight)

            // White text over the picture needs its own dark ground: the
            // still can be anything, and the old foreground-coloured label
            // with a drop shadow vanished on a bright banner and went dark on
            // dark under Paper.
            LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: 96)
                .allowsHitTesting(false)

            VStack(alignment: .leading) {
                Button(action: onClose) {
                    HStack(spacing: 6) {
                        Image(anicat: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundColor(.white.opacity(isBackHovered ? 1 : 0.92))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                #if os(macOS)
                .onHover { isBackHovered = $0 }
                #endif
                Spacer()
            }
            .padding(.horizontal, 56)
            // Below the window's transparent title strip, not level with it.
            // With `.fullSizeContentView` that strip takes the click rather
            // than passing it down, and at a 24pt inset the top third of the
            // most-pressed button in the app was dead -- measured: a press at
            // y=17 did nothing, the same button at y=33 went back.
            #if os(macOS)
            .padding(.top, 34)
            #else
            .padding(.top, 24)
            #endif
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: Self.bannerSlotHeight)
    }

    /// The banner still, behind the banner slot and the poster row as one
    /// picture, dissolving into the page ground on the way down.
    ///
    /// It used to be clipped at 288pt with a gradient to the ground on its
    /// last 115pt, and the poster and title sat on flat ground under it, so
    /// the header read as an image with a page stapled below. Two attempts
    /// to hide that edge with a separate wash under the banner left a
    /// visible seam each time, because two layers meeting at a line are a
    /// line however their colours are matched. One image with one mask has
    /// no line to match: the mask holds the picture in the top of the
    /// banner, dims it under the title (the old `.hero-gradient` stops,
    /// which is what kept the title legible), and runs it out to nothing
    /// where the poster row begins.
    ///
    /// The mask is a gradient to clear, not to the ground colour: on Paper
    /// the old gradient's hard-coded near-black darkened the ground the dark
    /// title needed lightened, and letting the page show through instead
    /// is right on every skin.
    ///
    /// The dimming is on the image and never on the frame around it, read
    /// through `visualEffect` without publishing the offset, so none of it
    /// reaches the page body -- no state, no scroll tick. The still used to
    /// scroll at half speed behind the page, a web parallax; it now moves
    /// with the page.
    private var heroBackdrop: some View {
        let mask = LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                // The old gradient's stops: 40% of the picture left under
                // the meta line, 12% at the old clip. At 62% the meta line
                // sat on a bright still and could not be read.
                .init(color: .black.opacity(0.40), location: 173 / Self.heroHeight),
                .init(color: .black.opacity(0.15), location: 288 / Self.heroHeight),
                .init(color: .clear, location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        // The image is overlaid onto an already-sized base rather than
        // framed itself: an AsyncImage given a flexible frame measured a
        // portrait-leaning still as needing ~1150pt of width regardless of
        // the proposal, and as the outermost element of a freshly-`.id()`d
        // view that ideal width won against RootView's HStack -- the page
        // rendered 1150pt wide from the window's left edge, over the sidebar.
        return Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.heroHeight)
            .overlay {
                // 2400, not 1200: the still spans ~1150pt, which is 2300
                // device pixels on a Retina panel, and a 1200px decode was
                // being drawn at twice its size -- soft before any zoom,
                // and visibly low quality once the frame grew. AniList
                // banners are 1900px wide, so this is their native decode.
                CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 2400) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.card)
                }
                .visualEffect { content, proxy in
                    let scrolled = max(0, -proxy.frame(in: .scrollView).minY)
                    return content.brightness(-min(0.18, scrolled / 1600))
                }
            }
            .clipped()
            .mask(mask)
            .allowsHitTesting(false)
    }

    // MARK: - Compact header

    /// The sticky bar that replaces the hero once it has scrolled away.
    ///
    /// An overlay on the scroll view, not a pinned section header: pinned
    /// headers only exist for `List` and `LazyVStack` sections, and this page
    /// is a plain `VStack` whose tabs bar is not a section header.
    private var compactHeaderLayer: some View {
        ZStack(alignment: .top) {
            if isHeaderCompact {
                compactHeader
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .offset(y: -8))
                    )
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .snappy, value: isHeaderCompact)
    }

    /// One line: back, the poster, the title, the tabs and the same primary
    /// button as the hero, so a page scrolled halfway down a long list can
    /// still change tab or play without scrolling back up.
    private var compactHeader: some View {
        HStack(spacing: 12) {
            Button(action: onClose) {
                Image(anicat: "chevron.left")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Back")

            HStack(spacing: 12) {
                Color.clear
                    .frame(width: 24, height: 36)
                    .overlay {
                        CachedAsyncImage(url: details.coverURL, maxPixelSize: 96) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .clipped()
                    .clipShape(SumiRect(cornerRadius: 4))

                Text(details.title)
                    .font(.sumiHeading(size: 13, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
            }
            // The bar sits over the scroll view, and on macOS a view that
            // hit-tests there eats the scroll wheel above it. Only the
            // controls need clicks; everything else stays transparent to the
            // pointer so the page still scrolls under the bar.
            .allowsHitTesting(false)

            Spacer(minLength: 12)

            SumiTabBar(tabs: tabItems, selection: tabSelection)
                .fixedSize()

            if let action = primaryAction {
                Button(action: action.run) {
                    Text(action.title)
                }
                .sumiPrimaryButton()
            }
        }
        .padding(.horizontal, 56)
        // The window's 28pt title strip takes clicks under
        // `.fullSizeContentView`. The bar used to start 9pt down, which left
        // the top of its button dead; with a back button and the tabs in it
        // now, every control in the bar would have had the same dead band.
        #if os(macOS)
        .padding(.top, 28)
        #else
        .padding(.top, 9)
        #endif
        .padding(.bottom, 9)
        .frame(maxWidth: 1150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                SumiTheme.background.opacity(0.82)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(SumiTheme.border).frame(height: 1)
            }
            .allowsHitTesting(false)
        }
    }

    // MARK: - Header

    /// Poster beside title, meta line and buttons, bottom-aligned, the same
    /// for an anime, a manga, a novel, a film and a series. The synopsis and
    /// genres moved to About: with them the header ran to 600pt and the
    /// episode list started below the fold on a laptop.
    private var content: some View {
        HStack(alignment: .bottom, spacing: 24) {
            poster
            headerInfo
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 8)
        .frame(maxWidth: 1150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, -bannerOverlap)
    }

    private var poster: some View {
        Color.clear
            .frame(width: 150, height: 225)
            .overlay {
                CachedAsyncImage(url: details.coverURL, maxPixelSize: 600) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.card)
                }
            }
            .clipped()
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusXl))
            .overlay(
                SumiRect(cornerRadius: SumiTheme.radiusXl)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .ifLet(namespace) { view, namespace in
                // Both halves are sources on purpose, despite what the
                // modifier's documentation implies. `isSource: false` here
                // does not mean "follow the card while the transition runs",
                // it means "take the source's frame for as long as a source
                // exists" -- and the card behind an open page never goes
                // away, so the poster stayed pinned at the card's position
                // and size for the whole time the page was up.
                view.matchedGeometryEffect(id: details.id, in: namespace)
            }
            // Same reasoning as `MediaCard`: matchedGeometryEffect only
            // animates frame, so without this the poster snapped into its
            // final size with no cross-fade while everything around it
            // (via the page's own insertion transition) faded normally.
            .transition(.opacity)
            .compositingGroup()
    }

    private var headerInfo: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(details.title)
                .font(.sumiHeading(size: 28, weight: .bold))
                .tracking(-0.5)
                .foregroundColor(SumiTheme.foreground)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            metaLine

            HeaderActionBar(
                primary: primaryAction,
                restart: restartAction,
                listMenu: listMenuModel,
                isFavourite: tracksOnAniList ? details.isFavourite : nil,
                onToggleFavourite: onToggleFavourite,
                // Not before release: with no primary button there is
                // nothing for the source picker to hang from.
                film: (isSingleSitting && !isAwaitingRelease) ? episodes.first : nil,
                onDownloadFilm: downloadEpisode,
                onChooseFilmSource: openFilmPicker,
                onSetFilmWatched: { film in onSetEpisodeWatched(film.number, !film.isWatched) },
                isCompactList: (!episodes.isEmpty && !isSingleSitting) ? compactListBinding : nil,
                audio: (tracksOnAniList && !episodes.isEmpty) ? $storedSubDub : nil,
                // AniList only. A TMDB title is on no AniList list and never
                // was -- cinema keeps its watchlist in the local registry,
                // and the status menu already offers "Remove from list" for
                // it.
                removeFromAniList: details.mediaCatalog == .anilist ? onRemoveFromList : nil,
                canRemoveFromAniList: details.listEntryId != nil,
                filmPicker: filmPickerModel
            )
            .padding(.top, 6)
        }
        .padding(.bottom, 4)
    }

    private var compactListBinding: Binding<Bool> {
        Binding(
            get: { selectedViewMode == .compact },
            set: { compact in withAnimation(.snappy) { selectedViewMode = compact ? .compact : .cards } }
        )
    }

    // MARK: - Meta line

    private enum MetaPart {
        case text(String, accent: Bool)
        case studio
    }

    /// Only the parts this title has, so the separators fall between present
    /// items: a dot drawn beside an absent year or score left "TV · · 2024".
    private var metaParts: [MetaPart] {
        var parts: [MetaPart] = []
        if let format = details.format {
            parts.append(.text(MediaCard.displayFormat(format), accent: false))
        }
        if let year = details.year {
            parts.append(.text(String(year), accent: false))
        }
        if !mainStudios.isEmpty || details.studio != nil {
            parts.append(.studio)
        }
        if let count = countText {
            parts.append(.text(count, accent: false))
        }
        if let release = releasePart {
            parts.append(release)
        }
        if let score = details.averageScore, score > 0 {
            let value = String(format: "%.1f", Double(score) / 10)
            parts.append(.text(tracksOnAniList ? value : "\(value) on TMDB", accent: false))
        }
        return parts
    }

    private var countText: String? {
        if seasons.count > 1 {
            let total = details.episodeCount ?? episodes.count
            return "\(seasons.count) seasons, \(total) episodes"
        }
        guard let count = details.episodeCount, count > 0, !isSingleSitting else { return nil }
        let unit = isMangaMedia ? "chapter" : "episode"
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    /// The next broadcast when there is one -- the one thing in the line
    /// worth the accent -- else the plain status word.
    private var releasePart: MetaPart? {
        if let next = nextAiring, let airingAt = next.airingAt {
            return .text(Self.airingLabel(episode: next.number, at: airingAt, countdown: isAwaitingRelease), accent: true)
        }
        switch details.status {
        case "RELEASING": return .text(isMangaMedia ? "Releasing" : "Airing", accent: false)
        case "FINISHED": return .text("Finished", accent: false)
        case "NOT_YET_RELEASED": return .text("Not out yet", accent: true)
        default: return nil
        }
    }

    private var nextAiring: EpisodeItem? {
        episodes.first { !$0.isAired && $0.airingAt != nil }
    }

    private static let airingSoonFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE jmm")
        return f
    }()

    private static let airingLaterFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM jmm")
        return f
    }()

    /// "Ep 6 airs Sat 17:30" inside the coming week, the date added past it,
    /// and "in 11 days" on a title with nothing out yet, where the wait is
    /// the news.
    private static func airingLabel(episode: Int, at airingAt: Int64, countdown: Bool) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(airingAt))
        let soon = date.timeIntervalSinceNow < 6 * 24 * 3600
        var label = "Ep \(episode) airs \((soon ? airingSoonFormat : airingLaterFormat).string(from: date))"
        if countdown {
            let relative = RelativeDateTimeFormatter()
            relative.unitsStyle = .full
            label += ", " + relative.localizedString(for: date, relativeTo: Date())
        }
        return label
    }

    private var metaLine: some View {
        HStack(spacing: 0) {
            if details.format == nil && isLoading {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 140, height: 12)
            }
            ForEach(Array(metaParts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text(" · ").foregroundColor(SumiTheme.muted)
                }
                switch part {
                case let .text(label, accent):
                    Text(label)
                        .foregroundColor(accent ? SumiTheme.indigo : SumiTheme.muted)
                case .studio:
                    studioLine
                }
            }
            Spacer(minLength: 0)
        }
        .sumiTabularMono(size: 12.5)
        .lineLimit(1)
    }

    /// The studios, each opening its own page. Falls back to the plain
    /// `studio` string for a snapshot written before `studios` existed and
    /// for any title AniList credits no studio ids for — the name was
    /// always shown here, and losing it to gain a button is not a trade.
    @ViewBuilder
    private var studioLine: some View {
        if !mainStudios.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(mainStudios.enumerated()), id: \.element.id) { index, studio in
                    if index > 0 {
                        Text(", ").foregroundColor(SumiTheme.muted)
                    }
                    StudioButton(name: studio.name) {
                        studioPageActions.open(studio.id)
                    }
                }
            }
        } else if let studio = details.studio {
            Text(studio)
                .foregroundColor(SumiTheme.muted)
        }
    }

    /// The animation studios, or every credited one when AniList marks none
    /// as main — a production committee of six names is still better than
    /// an empty line where the studio used to be.
    private var mainStudios: [HeroBanner.Details.StudioRef] {
        guard let studios = details.studios, !studios.isEmpty else { return [] }
        let main = studios.filter(\.isMain)
        return main.isEmpty ? Array(studios.prefix(3)) : main
    }

    /// The shelf's subject: one studio, so the heading can name it.
    private var shelfStudio: HeroBanner.Details.StudioRef? { mainStudios.first }

    // MARK: - Actions

    /// What the one filled button does, named exactly: "Resume E5 at 12:03",
    /// "Play E1", "Read ch. 211". It said "Rewatch" and "Watch again", which
    /// left the viewer to guess which episode that meant.
    private var primaryAction: HeaderAction? {
        if isAwaitingRelease { return planningAction }
        if !episodes.isEmpty, let target = resumeTarget {
            return HeaderAction(title: playTitle(for: target), icon: "play.fill") {
                startingPlayback { onPlayEpisode(target) }
            }
        }
        if let chapter = resumeChapter {
            return HeaderAction(title: "Read ch. \(chapter.number)", icon: "book.fill") {
                onReadChapter(chapter)
            }
        }
        if let volume = novel.volumes.first, let onReadVolume {
            return HeaderAction(title: "Read first volume", icon: "book.fill") {
                onReadVolume(volume)
            }
        }
        return nil
    }

    /// Nothing out to play, so the useful thing is to remember it. Absent
    /// once the title is on a list: the status menu beside it already says
    /// which, and a primary button reading "Add to Planning" on a planned
    /// title would add nothing.
    private var planningAction: HeaderAction? {
        if tracksOnAniList {
            guard details.listStatus == nil else { return nil }
            return HeaderAction(title: "Add to Planning", icon: nil) { onSetListStatus("PLANNING") }
        }
        guard cinemaListStatus == nil else { return nil }
        return HeaderAction(title: "Add to Planning", icon: nil) { onSetCinemaListStatus("PLANNING") }
    }

    /// Announced, with nothing out: no episode aired, no chapter or volume
    /// to read.
    private var isAwaitingRelease: Bool {
        details.status == "NOT_YET_RELEASED"
            // A film's one "episode" is built as aired whatever its date, so
            // an announced film offered Play next to "Not out yet".
            && (isSingleSitting || !episodes.contains(where: \.isAired))
            && mangaChapters.isEmpty
            && novel.volumes.isEmpty
    }

    /// "Start over" lives in the More menu now, under the same rule it had
    /// beside the button: offered only when the primary action does not
    /// already start from the beginning.
    private var restartAction: HeaderAction? {
        if !episodes.isEmpty {
            guard let episode = resumeTarget, resumeSecondsForTarget != nil else { return nil }
            return HeaderAction(title: "Play from the start", icon: nil) {
                startingPlayback { onPlayEpisodeFromStart(episode) }
            }
        }
        if isContinuingChapters, let first = mangaChapters.first {
            return HeaderAction(title: "Read from ch. \(first.number)", icon: nil) { onReadChapter(first) }
        }
        return nil
    }

    private func playTitle(for target: EpisodeItem) -> String {
        let time = resumeSecondsForTarget.map { PlayerController.formatTimestamp(Double($0), padded: false) }
        if isSingleSitting {
            return time.map { "Resume \($0)" } ?? "Play"
        }
        let code = episodeCode(target.number)
        return time.map { "Resume \(code) at \($0)" } ?? "Play \(code)"
    }

    /// "E5", or "S2 E3" on a TMDB series. The engine numbers a series'
    /// episodes absolutely, so without the season the button said "E13"
    /// about what TMDB, and the viewer, call season 2 episode 3.
    private func episodeCode(_ number: Int) -> String {
        if seasons.count > 1,
           let season = seasons.first(where: { range(ofSeason: $0).contains(number) }) {
            return "S\(season.number) E\(number - range(ofSeason: season).lowerBound + 1)"
        }
        return "E\(number)"
    }

    private var listMenuModel: HeaderListMenu {
        if tracksOnAniList {
            return HeaderListMenu(
                title: Self.statusLabel(details.listStatus, manga: isMangaMedia),
                options: Self.listStatusOptions.map { status in
                    (Self.statusLabel(status, manga: isMangaMedia), { onSetListStatus(status) })
                },
                remove: nil
            )
        }
        return HeaderListMenu(
            // Called, not passed by name: a reference to the function loses
            // its defaulted `manga:` and no longer matches `map`'s
            // single-argument closure.
            title: cinemaListStatus.map { Self.statusLabel($0) } ?? "Add to list",
            options: ["PLANNING", "CURRENT", "COMPLETED", "DROPPED"].map { status in
                (Self.statusLabel(status), { onSetCinemaListStatus(status) })
            },
            remove: cinemaListStatus == nil ? nil : { onSetCinemaListStatus(nil) }
        )
    }

    private var filmPickerModel: HeaderFilmPicker {
        HeaderFilmPicker(
            isPresented: Binding(get: { isFilmPickerOpen }, set: { isFilmPickerOpen = $0 }),
            isLoading: isLoadingFilmCandidates,
            candidates: filmCandidates,
            onSelect: { name in
                isFilmPickerOpen = false
                if let film = episodes.first {
                    startingPlayback { onPlayWithRelease(film, name) }
                }
            }
        )
    }

    private func openFilmPicker(_ film: EpisodeItem) {
        filmCandidates = []
        isLoadingFilmCandidates = true
        isFilmPickerOpen = true
        Task {
            let found = await onLoadReleaseCandidates(film.number)
            isLoadingFilmCandidates = false
            filmCandidates = found
        }
    }

    // MARK: - Tabs bar

    /// Tabs and their content, full-width below the header.
    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            tabBar
            // The two tabs overlap while they cross-fade. Left in the VStack
            // they stacked instead, and the page grew by the whole height of
            // the outgoing tab for the length of every switch.
            ZStack(alignment: .topLeading) {
                tabContent
                    .id(activeTab)
                    .transition(tabTransition)
            }
        }
        .padding(.horizontal, 56)
        .padding(.top, 22)
        .padding(.bottom, 64)
        .frame(maxWidth: 1150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var tabItems: [(key: String, label: String)] {
        availableTabs.map { ($0.rawValue, tabLabel($0)) }
    }

    private var tabSelection: Binding<String> {
        Binding(
            get: { activeTab.rawValue },
            set: { key in
                if let tab = DetailTab(rawValue: key) { selectedTab = tab }
            }
        )
    }

    /// The tabs as words, and on the right the one choice that belongs to
    /// the open tab: the season, or the language chapters are read in.
    private var tabBar: some View {
        HStack(alignment: .center, spacing: 12) {
            SumiTabBar(tabs: tabItems, selection: tabSelection)
                .fixedSize()
            Spacer(minLength: 12)
            tabTrailing
        }
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabTrailing: some View {
        if activeTab == .episodes, seasons.count > 1 {
            seasonPicker
        } else if activeTab == .manga, details.format != "NOVEL" {
            HStack(spacing: 7) {
                Text("Read in")
                    .font(.system(size: 12.5))
                    .foregroundColor(SumiTheme.muted)
                SumiSlashToggle([(false, "English"), (true, "日本語")], selection: japaneseManga) {
                    japaneseManga = $0
                }
            }
            .help("Japanese raws come from Sen Manga, which has fewer titles than the English chapters.")
        } else if isAwaitingRelease, !isMangaMedia {
            Text("Episodes appear here once episode 1 is out")
                .sumiTabularMono(size: 11.5)
                .foregroundColor(SumiTheme.muted)
                .lineLimit(1)
        }
    }

    /// Other titles by the studio that made this one. Fetched when the page
    /// mounts rather than as part of the detail load: it sits below the
    /// tabs, so nothing about the page above it waits on the request, and a
    /// studio already opened this session answers from `AppModel`'s cache
    /// without a round trip at all.
    ///
    /// `.task(id:)` rather than a bare `onAppear`: it cancels with the page,
    /// which a detached fetch left running past a fast back-and-forward
    /// would not, and it re-runs when the id changes.
    @ViewBuilder
    private var moreFromStudio: some View {
        if let studio = shelfStudio {
            // The VStack is unconditional and only its contents are gated:
            // the shelf starts empty, and a `.task` attached to a branch
            // that renders nothing is not reliably installed — the fetch it
            // is waiting on is the one that would have filled it.
            VStack(alignment: .leading, spacing: 12) {
                if !studioWorks.isEmpty {
                    Button {
                        studioPageActions.open(studio.id)
                    } label: {
                        HStack(spacing: 6) {
                            Text("More from \(studio.name)")
                                .sumiTabularMono(size: 11)
                                .foregroundColor(SumiTheme.indigo)
                            Image(anicat: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(SumiTheme.indigo.opacity(0.7))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(studioWorks) { work in
                                PersonMediaPoster(
                                    title: work.title,
                                    coverImage: work.coverImage,
                                    year: nil,
                                    caption: work.format
                                ) {
                                    onSelectMediaId?(
                                        work.id,
                                        work.title,
                                        URL(string: work.coverImage),
                                        AppModel.isMangaFormat(work.format)
                                    )
                                }
                                .frame(width: 140)
                            }
                        }
                        .padding(.bottom, 4)
                    }
                    .backSwipeExempt()
                }
            }
            .padding(.horizontal, 56)
            // Zero while empty: the container has to stay mounted for the
            // `.task` below, and a title whose studio has nothing else to
            // show would otherwise pad the page with a blank band.
            .padding(.bottom, studioWorks.isEmpty ? 0 : 64)
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .task(id: studio.id) {
                let works = await studioPageActions.works(studio.id)
                // The studio's own list includes the title being viewed;
                // dropping it here rather than in the cache keeps that
                // cache shareable with every other title the studio made.
                let others = works.filter { $0.id != details.id }.prefix(Self.studioShelfCount)
                // An empty answer is not necessarily "this studio has
                // nothing": a second title by the same studio opened while
                // the first one's fetch is still running is told the
                // request is already in flight. Writing that emptiness in
                // would leave the shelf blank with nothing left to refire
                // it.
                guard !others.isEmpty else { return }
                withAnimation(.sumi(.page)) {
                    studioWorks = Array(others)
                }
            }
        }
    }

    private static let listStatusOptions = ["CURRENT", "PLANNING", "COMPLETED", "PAUSED", "DROPPED", "REPEATING"]

    /// AniList stores one set of status tokens for both catalogs but names
    /// them differently: `CURRENT` is "Watching" on an anime and "Reading" on
    /// a manga, `REPEATING` "Rewatching" and "Rereading". Without the flag the
    /// Tomodachi Game page offered "Watching" for a book. `manga` defaults to
    /// false for the cinema menu, which has no manga case to get wrong.
    private static func statusLabel(_ status: String?, manga: Bool = false) -> String {
        switch status {
        case "CURRENT": return manga ? "Reading" : "Watching"
        case "PLANNING": return "Planning"
        case "COMPLETED": return "Completed"
        case "PAUSED": return "Paused"
        case "DROPPED": return "Dropped"
        case "REPEATING": return manga ? "Rereading" : "Rewatching"
        default: return "Add to list"
        }
    }

    /// The episode the primary button plays: the resume point if there is one,
    /// else the first unwatched aired episode, else the first.
    private var resumeTarget: EpisodeItem? {
        if let number = details.resumeEpisode,
           let match = episodes.first(where: { $0.number == number }) {
            return match
        }
        // Unfiltered "first unwatched" picked an announced-but-unaired
        // episode as soon as everything aired so far was watched, offering
        // "Play Episode 11" while only 10 existed to stream.
        // A Completed title starts over from the first episode: the button
        // reads "Rewatch" and a last-episode target made that Rewatch Ep 12.
        if details.listStatus == "COMPLETED", let first = episodes.first(where: \.isAired) {
            return first
        }
        return episodes.first(where: { !$0.isWatched && $0.isAired })
            ?? episodes.last(where: \.isAired)
            ?? episodes.first
    }

    /// The recorded position the primary button would resume from, or nil
    /// when it would start the episode anyway. The single source for both
    /// the "Resume mm:ss" label and whether "Start over" is offered, so the
    /// two cannot disagree about whether there is a resume point.
    private var resumeSecondsForTarget: Int? {
        guard let target = resumeTarget,
              let seconds = details.resumeSeconds, seconds > 0,
              target.number == details.resumeEpisode else { return nil }
        return seconds
    }

    /// The chapter the primary button opens: the first one numbered past
    /// AniList's progress count, else the first chapter. Read from
    /// `listProgress` rather than `resumeEpisode`, which a manga never sets —
    /// without it the page offered "Read Chapter 1" to a reader sitting at
    /// 35 of 130 while the Up Next shelf beside it said CH 36.
    ///
    /// The numbers are strings ("36", "36.5", "Oneshot"), so one that does
    /// not parse is skipped rather than guessed at.
    private var resumeChapter: MangaChapterItem? {
        guard let progress = details.listProgress, progress > 0 else { return mangaChapters.first }
        let next = mangaChapters.first { chapter in
            guard let number = Double(chapter.number) else { return false }
            return number > Double(progress)
        }
        return next ?? mangaChapters.first
    }

    /// Whether the manga primary button points past the first chapter, which
    /// is the only case where "Start over" is not a second button doing what
    /// the first one already does.
    private var isContinuingChapters: Bool {
        guard let target = resumeChapter, let first = mangaChapters.first else { return false }
        return target.id != first.id
    }

    /// TMDB's season breakdown for the open title, empty for anything else.
    /// Gated on the catalog, not only on `cinemaExtras`: Back from a series
    /// to an anime paints the anime's snapshot before the load that clears
    /// `cinemaExtras` runs, and for that moment the anime page carried the
    /// series' season picker and filtered its episodes by the series' ranges.
    private var seasons: [CinemaSeason] {
        details.mediaCatalog == .tmdbTv ? (cinemaExtras?.seasons ?? []) : []
    }

    /// The absolute episode numbers one season covers.
    ///
    /// The engine numbers episodes absolutely -- the registry, the resume
    /// position and the remembered release all key on one number -- so a
    /// season is a range in that sequence rather than a field on the row.
    /// Built from the same map the engine resolves against, so what this
    /// shows and what a play fetches cannot disagree.
    private func range(ofSeason season: CinemaSeason) -> ClosedRange<Int> {
        var start = 1
        for entry in seasons {
            if entry.number == season.number { break }
            start += Int(entry.episodeCount)
        }
        return start...(start + Int(season.episodeCount) - 1)
    }

    /// TMDB's per-season breakdown (`cinemaExtras`) loads after the page is
    /// already on screen (`AppModel+Cinema.swift`'s deferred extras task),
    /// so there is a real window where a multi-season show's `seasons` is
    /// still empty. Without this, `episodesForSelectedSeason` fell through
    /// to the full cross-season list during that window and then "snapped"
    /// down to one season's rows the instant `cinemaExtras` arrived --
    /// looking like episodes were disappearing.
    ///
    /// Waits on the fetch, not on `cinemaExtras` itself: a failed fetch
    /// leaves that nil for good, and a proxy error left the Episodes tab
    /// spinning with nothing to play. After a failure the full list shows.
    private var isAwaitingSeasonBreakdown: Bool {
        details.mediaCatalog == .tmdbTv && cinemaExtras == nil && isCinemaExtrasLoading && !isSingleSitting
    }

    private var episodesForSelectedSeason: [EpisodeItem] {
        if isAwaitingSeasonBreakdown { return [] }
        guard seasons.count > 1 else { return episodes }
        let wanted = selectedSeason ?? defaultSeason
        let season = seasons.first { $0.number == wanted } ?? seasons[0]
        let span = range(ofSeason: season)
        return episodes.filter { span.contains($0.number) }
    }

    /// Which season the list is showing. Defaults to the one the resume
    /// position is in, so a show resumed at season 3 opens on season 3
    /// rather than on a first season finished months ago.
    ///
    /// From `resumeTarget`, the episode the Play button names, not from
    /// `details.resumeEpisode`: the engine clears that once an episode
    /// passes 85%, so after a season finale the list opened on the finished
    /// season while the button offered the next season's first episode.
    private var defaultSeason: Int32 {
        guard let resume = resumeTarget?.number else { return seasons.first?.number ?? 1 }
        for season in seasons where range(ofSeason: season).contains(resume) {
            return season.number
        }
        return seasons.first?.number ?? 1
    }

    /// Seasons as words, "Season 1 / Season 2", like every other one-of-a-few
    /// choice in the app. They were filled chips, the selected one inverted.
    ///
    /// Right of the tabs. A scroll view there takes every point the spacer
    /// would have and draws its content from the left, so it is only the
    /// fallback for a run of seasons too long to fit.
    private var seasonPicker: some View {
        let toggle = SumiSlashToggle(
            seasons.map { ($0.number, "Season \($0.number)") },
            selection: selectedSeason ?? defaultSeason
        ) { number in
            withAnimation(.snappy(duration: 0.25)) { selectedSeason = number }
        }
        return ViewThatFits(in: .horizontal) {
            toggle
            ScrollView(.horizontal, showsIndicators: false) {
                toggle.padding(.vertical, 2)
            }
            .backSwipeExempt()
        }
    }

    /// A film: one sitting, numbered 1 only because the registry, the resume
    /// position and the remembered release all key on an episode number.
    /// Nothing on the page should say "Episode 1" about it.
    private var isSingleSitting: Bool {
        details.format?.uppercased() == "MOVIE" && episodes.count <= 1
    }

    // MARK: - Tabs

    private var isMangaMedia: Bool {
        if let f = details.format, ["MANGA", "NOVEL", "ONE_SHOT"].contains(f) {
            return true
        }
        return episodes.isEmpty && !mangaChapters.isEmpty
    }

    /// Episodes, Chapters or Volumes first, then About, Related and People
    /// on every page. A film has no Episodes tab -- the button plays it --
    /// and a title with nothing aired yet has none until episode 1 is out.
    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        let showsEpisodes = !isSingleSitting
            && !(details.status == "NOT_YET_RELEASED" && !episodes.contains(where: \.isAired))
        if isMangaMedia {
            tabs.append(.manga)
            if !episodes.isEmpty { tabs.append(.episodes) }
        } else {
            if showsEpisodes { tabs.append(.episodes) }
            if !mangaChapters.isEmpty { tabs.append(.manga) }
        }
        tabs.append(.about)
        // A TMDB title has no franchise graph; its Related tab is TMDB's
        // recommendations alone, so it is left out until there are some.
        if tracksOnAniList || !recommendations.isEmpty {
            tabs.append(.related)
        }
        tabs.append(.people)
        return tabs
    }

    private func tabLabel(_ tab: DetailTab) -> String {
        switch tab {
        case .episodes: return "Episodes"
        case .manga: return details.format == "NOVEL" ? "Volumes" : "Chapters"
        case .about: return "About"
        case .related: return "Related"
        // TMDB lists actors, not characters with voice actors.
        case .people: return tracksOnAniList ? "People" : "Cast"
        }
    }

    private var activeTab: DetailTab {
        if availableTabs.contains(selectedTab) {
            return selectedTab
        }
        return availableTabs.first ?? .about
    }

    /// A crossfade. Tabs used to slide in 12pt from the side they sat on,
    /// a web carousel habit; a Mac tab view swaps its content in place.
    private var tabTransition: AnyTransition { .opacity }

    /// The first absolute episode number of the season on screen, less one:
    /// what the rows subtract to number a TMDB season from 1.
    private var seasonNumberOffset: Int {
        guard seasons.count > 1 else { return 0 }
        let wanted = selectedSeason ?? defaultSeason
        guard let season = seasons.first(where: { $0.number == wanted }) ?? seasons.first else { return 0 }
        return range(ofSeason: season).lowerBound - 1
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .episodes:
            // Its own View struct, not another computed property here: this
            // is the one section whose backing state (`downloadStates`)
            // mutates on a 1s poll while a download runs. Inlined as a
            // computed property it registered that dependency on the whole
            // detail page `body`, so every tick re-evaluated the entire page
            // to redraw one row's percentage.
            EpisodeListSection(
                episodes: episodesForSelectedSeason,
                resumeEpisode: details.resumeEpisode,
                resumeSeconds: details.resumeSeconds,
                numberOffset: seasonNumberOffset,
                isCompact: selectedViewMode == .compact,
                downloadStates: downloadStates,
                isLoading: isLoading || isAwaitingSeasonBreakdown,
                onPlayEpisode: { episode in startingPlayback { onPlayEpisode(episode) } },
                onPlayEpisodeFromStart: { episode in startingPlayback { onPlayEpisodeFromStart(episode) } },
                onSetEpisodeWatched: onSetEpisodeWatched,
                onLoadReleaseCandidates: onLoadReleaseCandidates,
                onPlayWithRelease: { episode, name in startingPlayback { onPlayWithRelease(episode, name) } },
                onDownloadEpisode: downloadEpisode,
                catalogId: details.id,
                playerNamespace: playerNamespace,
                playerSourceKey: playerSourceKey
            )
        case .manga:
            MangaTabSection(
                chapters: mangaChapters,
                format: details.format,
                readProgress: details.listProgress,
                isLoading: isLoading,
                novelVolumes: novel.volumes,
                isLoadingNovelVolumes: novel.isLoading,
                novelSourceMissing: novel.sourceMissing,
                onReadVolume: onReadVolume,
                novelVolumeStates: novelVolumeStates,
                onDownloadVolume: onDownloadVolume,
                onDeleteVolumeDownload: onDeleteVolumeDownload,
                onExportVolume: onExportVolume,
                offlineStates: chapterOfflineStates,
                onDownloadChapter: onDownloadChapter,
                onDeleteChapterDownload: onDeleteChapterDownload,
                onReadChapter: onReadChapter
            )
        case .about:
            AboutTabSection(
                details: details,
                isLoading: isLoading,
                episodeRuntime: episodes.lazy.compactMap(\.runtimeMinutes).first { $0 > 0 },
                isMangaMedia: isMangaMedia,
                tracksOnAniList: tracksOnAniList,
                hasTrailer: hasTrailer,
                onOpenTrailer: openTrailer,
                discussions: discussions,
                onSelectThread: onSelectThread,
                cinemaExtras: tracksOnAniList ? nil : cinemaExtras
            )
        case .related:
            RelatedTabSection(
                details: details,
                relations: relations,
                recommendations: recommendations,
                showsWatchOrder: tracksOnAniList,
                onSelectMediaId: onSelectMediaId
            )
        case .people:
            CharactersTabSection(
                titleId: details.id,
                characters: characters,
                tracksOnAniList: tracksOnAniList,
                onSelectCharacter: onSelectCharacter
            )
        }
    }

    /// What a chapter's download control is showing.
    public enum ChapterOfflineState: Equatable, Sendable {
        case none
        case downloading
        case stored
        /// Building and writing an EPUB. Distinct from `downloading` because a
        /// volume can be stored and exporting at once, and the two controls
        /// are separate.
        case exporting
        case failed
    }

    /// One chapter: number, title, the scanlation group, and its state as a
    /// coloured word. Download and removal moved to the row's context menu;
    /// a hover-only icon per row was a second column of controls the
    /// mockups dropped.
    struct ChapterRowView: View {
        let chapter: MediaDetailView.MangaChapterItem
        /// At or below the chapter AniList says is read.
        var isRead: Bool = false
        /// The chapter the primary button opens.
        var isNext: Bool = false
        var offline: ChapterOfflineState = .none
        var onDownload: (() -> Void)?
        var onDeleteDownload: (() -> Void)?
        let onRead: () -> Void

        var body: some View {
            Button(action: onRead) {
                HStack(spacing: 12) {
                    Text("Ch. \(chapter.number)")
                        .sumiTabularMono(size: 12.5, weight: isNext ? .semibold : .regular)
                        .foregroundColor(isNext ? SumiTheme.indigo : (isRead ? SumiTheme.muted : SumiTheme.foreground))
                        .lineLimit(1)
                        .frame(width: 70, alignment: .leading)
                    // Sen Manga names a chapter "Chapter 12", which the
                    // number beside it already says.
                    Text(showsTitle ? chapter.title : "")
                        .font(.system(size: 13, weight: isNext ? .semibold : .regular))
                        .foregroundColor(isRead ? SumiTheme.muted : SumiTheme.foreground)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // MangaDex's API rules make crediting the scanlation
                    // group a condition of use.
                    if let group = chapter.scanlationGroup, !group.isEmpty {
                        Text(group)
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)
                            .frame(maxWidth: 200, alignment: .leading)
                    }
                    stateText
                        .frame(minWidth: 110, alignment: .trailing)
                }
                .padding(.vertical, 9)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .contextMenu {
                Button(isRead ? "Read again" : "Read", action: onRead)
                switch offline {
                case .stored:
                    if let onDeleteDownload { Button("Remove download", action: onDeleteDownload) }
                case .failed:
                    if let onDownload { Button("Retry download", action: onDownload) }
                case .none:
                    if let onDownload { Button("Download", action: onDownload) }
                case .downloading, .exporting:
                    EmptyView()
                }
            }
        }

        private var showsTitle: Bool {
            chapter.title.trimmingCharacters(in: .whitespaces).lowercased() != "chapter \(chapter.number)"
        }

        private var stateText: Text {
            var parts: [Text] = []
            if isNext {
                parts.append(Text("Next to read").foregroundColor(SumiTheme.indigo).fontWeight(.semibold))
            } else if isRead {
                parts.append(Text("Read").foregroundColor(SumiTheme.success))
            }
            switch offline {
            case .stored: parts.append(Text("Downloaded").foregroundColor(SumiTheme.success))
            case .downloading: parts.append(Text("Downloading").foregroundColor(SumiTheme.muted))
            case .failed: parts.append(Text("Download failed").foregroundColor(SumiTheme.danger))
            case .none, .exporting: break
            }
            return DetailStateText.join(parts)
                .font(.system(size: 11.5))
        }
    }

    struct RelatedMediaCard: View {
        let relation: MediaDetailView.RelationItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Color.clear
                        .frame(width: 40, height: 60)
                        .overlay {
                            CachedAsyncImage(url: relation.coverURL, maxPixelSize: 120) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(SumiTheme.card)
                            }
                        }
                        .clipped()
                        .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
                        .overlay(SumiRect(cornerRadius: SumiTheme.radiusSm).stroke(SumiTheme.border, lineWidth: 1))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(relation.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                            .lineLimit(1)
                        Text([MediaCard.displayRelation(relation.relationType), relation.format.map(MediaCard.displayFormat)]
                                .compactMap { $0 }.joined(separator: " · "))
                            .sumiTabularMono(size: 11.5)
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }
    }

    /// One forum thread in About: its title, and the replies and the last
    /// reply's age on the right.
    struct DiscussionRowView: View {
        let thread: MediaDetailView.DiscussionItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Text(thread.title)
                        .font(.system(size: 13))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    Text(meta)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                }
                .padding(.vertical, 10)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }

        private var meta: String {
            var parts = ["\(thread.replyCount) \(thread.replyCount == 1 ? "reply" : "replies")"]
            if let repliedAt = thread.repliedAt {
                let relative = RelativeDateTimeFormatter()
                relative.unitsStyle = .short
                parts.append(relative.localizedString(
                    for: Date(timeIntervalSince1970: TimeInterval(repliedAt)),
                    relativeTo: Date()
                ))
            }
            return parts.joined(separator: " · ")
        }
    }

    /// A poster on the "If you like this" shelf.
    struct RecommendationCardView: View {
        let rec: MediaDetailView.RecommendationItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 7) {
                    Color.clear
                        .aspectRatio(2/3, contentMode: .fit)
                        .overlay {
                            CachedAsyncImage(url: rec.coverURL, maxPixelSize: 400) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(SumiTheme.card)
                            }
                        }
                        .clipped()
                        .clipShape(SumiRect(cornerRadius: SumiTheme.radiusMd))
                        .overlay(SumiRect(cornerRadius: SumiTheme.radiusMd).stroke(SumiTheme.border, lineWidth: 1))

                    Text(rec.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(2, reservesSpace: true)

                    Text(meta)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }

        private var meta: String {
            var parts: [String] = []
            if let format = rec.format { parts.append(MediaCard.displayFormat(format)) }
            if let score = rec.averageScore, score > 0 {
                parts.append(String(format: "%.1f", Double(score) / 10))
            }
            return parts.joined(separator: " · ")
        }
    }
}

/// Several state words on a row as one `Text`, "Watched · Downloaded".
enum DetailStateText {
    static func join(_ parts: [Text]) -> Text {
        guard let first = parts.first else { return Text("") }
        return parts.dropFirst().reduce(first) { line, part in
            line + Text(" · ").foregroundColor(SumiTheme.muted) + part
        }
    }
}

/// The `matchedGeometryEffect` pair for the one episode row a play was just
/// started from. One struct rather than two loose optionals so `EpisodeRow.==`
/// cannot compare the namespace and forget the id.
/// `Sendable` so `EpisodeRow.==`, which is `nonisolated`, can compare it:
/// every stored property of that row is main-actor isolated through `View`,
/// and a non-`Sendable` one cannot be read from the `&&` autoclosure.
public struct EpisodeMorphSource: Equatable, Sendable {
    public let key: String
    public let namespace: Namespace.ID

    public init(key: String, namespace: Namespace.ID) {
        self.key = key
        self.namespace = namespace
    }
}

/// The `.episodes` tab's list, pulled out of `MediaDetailView.tabContent` so
/// `downloadStates` polling only re-evaluates this struct's own body, not
/// the whole detail page.
private struct EpisodeListSection: View {
    let episodes: [MediaDetailView.EpisodeItem]
    let resumeEpisode: Int?
    let resumeSeconds: Int?
    /// Subtracted from each absolute episode number for display, so a TMDB
    /// season reads from 1.
    var numberOffset: Int = 0
    let isCompact: Bool
    let downloadStates: () -> [Int: MediaDetailView.EpisodeDownloadState]
    var isLoading: Bool = false
    let onPlayEpisode: (MediaDetailView.EpisodeItem) -> Void
    let onPlayEpisodeFromStart: (MediaDetailView.EpisodeItem) -> Void
    let onSetEpisodeWatched: (Int, Bool) -> Void
    let onLoadReleaseCandidates: (Int) async -> [MediaDetailView.ReleaseCandidateItem]
    let onPlayWithRelease: (MediaDetailView.EpisodeItem, String) -> Void
    let onDownloadEpisode: (MediaDetailView.EpisodeItem) -> Void
    /// Only to build the morph key below — this section otherwise knows
    /// nothing about which title it is listing.
    let catalogId: Int64
    let playerNamespace: Namespace.ID?
    let playerSourceKey: String?

    @State private var serverPickerEpisode: MediaDetailView.EpisodeItem?
    @State private var isLoadingServers = false
    @State private var serverCandidates: [MediaDetailView.ReleaseCandidateItem] = []
    // Which chunk groups are expanded, keyed by the group's first episode
    // number. Seeded (see `.task` below) with the resume target's group --
    // without that, a 366-episode entry like Bleach opened to 366 flat rows
    // and the one the viewer actually wanted was a scroll away at the bottom.
    @State private var expandedGroups: Set<Int> = []

    // A linear scan of the list: `body` reads it once and hands the result
    // to the rows. Read inside the row builders it ran once per row, which
    // is quadratic on a 366-episode entry. It was a `@State` cache that
    // nothing ever assigned, so no row was ever the resume target.
    private var resumeTarget: MediaDetailView.EpisodeItem? {
        if let resumeEpisode, let match = episodes.first(where: { $0.number == resumeEpisode }) {
            return match
        }
        return episodes.first(where: { !$0.isWatched && $0.isAired })
            ?? episodes.last(where: \.isAired)
            ?? episodes.first
    }

    /// AniList carries no arc/season/cour field for a single Media entry's
    /// episode list (a franchise like Bleach models its later parts as
    /// separate, PREQUEL/SEQUEL-linked entries instead), so there is no real
    /// grouping to read -- only a synthetic chunk size to pick. 26 tracks a
    /// two-cour season, which is long enough that a normal one-cour show
    /// (≤13) or two-cour show (≤26) still renders as one flat list exactly
    /// as before.
    private static let groupChunkSize = 26

    private var episodeGroups: [(firstNumber: Int, episodes: [MediaDetailView.EpisodeItem])]? {
        guard episodes.count > Self.groupChunkSize else { return nil }
        return stride(from: 0, to: episodes.count, by: Self.groupChunkSize).map { start in
            let chunk = Array(episodes[start..<min(start + Self.groupChunkSize, episodes.count)])
            return (chunk.first?.number ?? start, chunk)
        }
    }

    private func morphSource(for episode: MediaDetailView.EpisodeItem) -> EpisodeMorphSource? {
        guard let playerNamespace,
              let playerSourceKey,
              playerSourceKey == MediaDetailView.playerMorphKey(catalogId: catalogId, episode: episode.number)
        else { return nil }
        return EpisodeMorphSource(key: playerSourceKey, namespace: playerNamespace)
    }

    @ViewBuilder
    private func rows(for episodes: [MediaDetailView.EpisodeItem], downloadStates: [Int: MediaDetailView.EpisodeDownloadState], target: MediaDetailView.EpisodeItem?) -> some View {
        ForEach(episodes) { episode in
            EpisodeRow(
                episode: episode,
                displayNumber: episode.number - numberOffset,
                isCompact: isCompact,
                isResumeTarget: episode.id == target?.id,
                resumeSeconds: episode.number == resumeEpisode ? resumeSeconds : nil,
                downloadState: downloadStates[episode.number] ?? .notStarted,
                onPlay: { onPlayEpisode(episode) },
                onPlayFromStart: { onPlayEpisodeFromStart(episode) },
                onToggleWatched: { watched in onSetEpisodeWatched(episode.number, watched) },
                onOpenServerPicker: {
                    serverPickerEpisode = episode
                    serverCandidates = []
                    isLoadingServers = true
                    Task {
                        let found = await onLoadReleaseCandidates(episode.number)
                        isLoadingServers = false
                        serverCandidates = found
                    }
                },
                onDownload: { onDownloadEpisode(episode) },
                isServerPickerOpen: serverPickerEpisode?.id == episode.id,
                // Only the open row sees the picker state:
                // `EpisodeRow.==` compares both, so one picker
                // loading re-rendered every row in the list.
                isLoadingServers: serverPickerEpisode?.id == episode.id && isLoadingServers,
                serverCandidates: serverPickerEpisode?.id == episode.id ? serverCandidates : [],
                onCloseServerPicker: { serverPickerEpisode = nil },
                onSelectServer: { name in
                    serverPickerEpisode = nil
                    onPlayWithRelease(episode, name)
                },
                // A stored property, not a closure: `EpisodeRow.==`
                // excludes closures, so anything that gates the
                // morph has to take part in that comparison or
                // the row never re-renders when the key is set —
                // the source would go untagged and the whole
                // morph would silently do nothing.
                morphSource: morphSource(for: episode)
            )
            .equatable()
        }
    }

    private func groupLabel(firstNumber: Int, count: Int) -> String {
        "Episodes \(firstNumber - numberOffset)-\(firstNumber - numberOffset + count - 1)"
    }

    var body: some View {
        let downloadStates = downloadStates()
        let target = resumeTarget
        Group {
            if episodes.isEmpty {
                if isLoading {
                    EpisodeListSkeleton(count: 6, isCompact: isCompact)
                } else {
                    SumiEmptyState(headline: "No episodes found", detail: "Nothing was returned for this title.")
                }
            } else if let groups = episodeGroups {
                LazyVStack(spacing: 8) {
                    ForEach(groups, id: \.firstNumber) { group in
                        ExpandableGroup(
                            title: groupLabel(firstNumber: group.firstNumber, count: group.episodes.count),
                            isExpanded: Binding(member: group.firstNumber, of: $expandedGroups)
                        ) {
                            rows(for: group.episodes, downloadStates: downloadStates, target: target)
                        }
                    }
                }
                // Only the group holding the resume target opens by default,
                // so a 366-episode entry doesn't land on 366 rows the viewer
                // has to scroll through to find the one they wanted.
                //
                // Keyed on the list's first episode and the target rather
                // than run once: this section outlives both. A series scoped
                // to season 2 has groups keyed 27 and 53 that a season-1 seed
                // never named, so the season opened fully collapsed; and a
                // target that moved on (an episode finished with the page
                // under the mini-player) sat inside a closed group. The owning
                // group is added, not swapped in, so a group the viewer opened
                // stays open.
                .task(id: [episodes.first?.number ?? 0, target?.number ?? 0]) {
                    let owning = target.map(\.number).flatMap { number in
                        groups.first { $0.episodes.contains { $0.number == number } }
                    } ?? groups.first
                    if let owning {
                        expandedGroups.insert(owning.firstNumber)
                    }
                }
            } else {
                LazyVStack(spacing: 0) {
                    rows(for: episodes, downloadStates: downloadStates, target: target)
                }
            }
        }
        .animation(.smooth, value: isCompact)
    }
}

/// One episode: number, still, title over its length and date, and its
/// state as a coloured word on the right. Mark watched, download and the
/// source picker are the row's context menu; the hover icons and the tick
/// that did those were a column of controls on every row.
private struct EpisodeRow: View, Equatable {
    let episode: MediaDetailView.EpisodeItem
    let displayNumber: Int
    /// No still: the old Compact view, kept as a More menu toggle.
    let isCompact: Bool
    let isResumeTarget: Bool
    let resumeSeconds: Int?
    let downloadState: MediaDetailView.EpisodeDownloadState
    let onPlay: () -> Void
    let onPlayFromStart: () -> Void
    let onToggleWatched: (Bool) -> Void
    let onOpenServerPicker: () -> Void
    let onDownload: () -> Void
    // Presentation state per row, driven by the parent's single
    // `serverPickerEpisode` so only one row is ever open: attached to the
    // whole list's container the popover anchored to that container and
    // opened anywhere on screen depending on scroll offset.
    let isServerPickerOpen: Bool
    let isLoadingServers: Bool
    let serverCandidates: [MediaDetailView.ReleaseCandidateItem]
    let onCloseServerPicker: () -> Void
    let onSelectServer: (String) -> Void
    /// Non-nil on exactly the row whose Play was just pressed, which makes
    /// this row's still the source the player's placeholder flies out of.
    /// Nil everywhere else, so only one view ever carries the id.
    let morphSource: EpisodeMorphSource?

    // The trailing closures are recreated by the caller on every parent body
    // evaluation (they capture `episode`), so they're excluded here rather
    // than making this un-comparable — they always wrap the same instance
    // methods, so two rows with identical data behave identically regardless
    // of closure identity. `.equatable()` at the call site uses this to skip
    // re-diffing rows AttributeGraph would otherwise walk again on every
    // parent update even though nothing about them changed — the dominant
    // main-thread cost `sample` found during scroll (AttributeGraph/SwiftUICore
    // diffing, not any single blocking call).
    nonisolated static func == (lhs: EpisodeRow, rhs: EpisodeRow) -> Bool {
        lhs.episode == rhs.episode
            && lhs.displayNumber == rhs.displayNumber
            && lhs.isCompact == rhs.isCompact
            && lhs.isResumeTarget == rhs.isResumeTarget
            && lhs.resumeSeconds == rhs.resumeSeconds
            && lhs.downloadState == rhs.downloadState
            && lhs.isServerPickerOpen == rhs.isServerPickerOpen
            && lhs.isLoadingServers == rhs.isLoadingServers
            && lhs.serverCandidates == rhs.serverCandidates
            && lhs.morphSource == rhs.morphSource
    }

    /// AniZip's `airdate` is a plain `YYYY-MM-DD`. Parsed as UTC to match how
    /// it was written — treating it as local time would roll the date for
    /// anyone west of Greenwich.
    private static let airDateParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// "4 Oct", in the viewer's own order of day and month. Parsed as UTC
    /// above, so shown as UTC too, or the day rolls back for anyone west of
    /// Greenwich.
    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private static let airedAtDisplay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    /// Local date and time of a broadcast still to come ("Sat 29 Nov,
    /// 17:30"), in the viewer's own zone: AniList gives an instant, and the
    /// Japanese clock time would be wrong for everyone else.
    private static let upcomingDisplay: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEE d MMM jm")
        return f
    }()

    private static var airDateCache: [String: String] = [:]
    private static let airDateLock = NSLock()

    static func formatAirDate(_ raw: String) -> String {
        airDateLock.lock()
        if let cached = airDateCache[raw] {
            airDateLock.unlock()
            return cached
        }
        airDateLock.unlock()

        let formatted: String
        if let date = airDateParser.date(from: raw) {
            formatted = airDateDisplay.string(from: date)
        } else {
            formatted = raw
        }

        airDateLock.lock()
        airDateCache[raw] = formatted
        airDateLock.unlock()
        return formatted
    }

    private var isResuming: Bool {
        isResumeTarget && (resumeSeconds ?? 0) > 0
    }

    var body: some View {
        Button(action: onPlay) {
            row
        }
        .buttonStyle(.sumiPressable)
        .help(episode.synopsis ?? "")
        .contextMenu {
            if isResuming, let seconds = resumeSeconds {
                Button("Resume at \(PlayerController.formatTimestamp(Double(seconds), padded: false))", action: onPlay)
                Button("Play from the start", action: onPlayFromStart)
            } else {
                Button("Play", action: onPlay)
            }
            Divider()
            Button(episode.isWatched ? "Mark unwatched" : "Mark watched") {
                onToggleWatched(!episode.isWatched)
            }
            switch downloadState {
            case .notStarted: Button("Download", action: onDownload)
            case .failed: Button("Retry download", action: onDownload)
            case .downloading, .done: EmptyView()
            }
            Divider()
            Button("Choose source…", action: onOpenServerPicker)
        }
        .sumiPopover(isPresented: Binding(
            get: { isServerPickerOpen },
            set: { if !$0 { onCloseServerPicker() } }
        ), arrowEdge: .top) {
            ServerPickerView(
                isLoading: isLoadingServers,
                candidates: serverCandidates,
                onSelect: onSelectServer
            )
        }
    }

    private var row: some View {
        HStack(spacing: 14) {
            Text("\(displayNumber)")
                .sumiTabularMono(size: 12.5, weight: isResumeTarget ? .semibold : .regular)
                .foregroundColor(isResumeTarget ? SumiTheme.foreground : SumiTheme.muted)
                .frame(minWidth: 22, alignment: .trailing)
            if !isCompact {
                thumbnail
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title)
                    .font(.system(size: 13, weight: isResumeTarget ? .semibold : .regular))
                    .foregroundColor(episode.isAired ? SumiTheme.foreground : SumiTheme.muted)
                    .lineLimit(1)
                if let meta = metaText {
                    Text(meta)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            stateText
                .lineLimit(1)
                .frame(minWidth: 120, alignment: .trailing)
        }
        .padding(.vertical, isCompact ? 7 : 9)
        // The resume row is lifted on a faint wash, inset so its words line
        // up with the rows around it rather than with the wash's edge.
        .padding(.horizontal, 12)
        .background(
            isResumeTarget ? SumiTheme.foreground.opacity(0.04) : Color.clear,
            in: SumiRect(cornerRadius: 8)
        )
        .padding(.horizontal, -12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
        .contentShape(Rectangle())
    }

    /// "24 min · 4 Oct · 12 min left": the length, the date, and on the
    /// resume row what is left of it.
    private var metaText: String? {
        var parts: [String] = []
        if episode.isAired, let minutes = episode.runtimeMinutes, minutes > 0 {
            parts.append("\(minutes) min")
        }
        if let airingAt = episode.airingAt {
            let date = Date(timeIntervalSince1970: TimeInterval(airingAt))
            parts.append((episode.isAired ? Self.airedAtDisplay : Self.upcomingDisplay).string(from: date))
        } else if let airDate = episode.airDate {
            parts.append(Self.formatAirDate(airDate))
        }
        if isResuming, let seconds = resumeSeconds {
            if let minutes = episode.runtimeMinutes, minutes > 0 {
                parts.append("\(max(1, minutes - seconds / 60)) min left")
            } else {
                parts.append("At \(PlayerController.formatTimestamp(Double(seconds), padded: false))")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// The row's state in words, coloured by kind: green for done, the
    /// accent for where to pick up, muted for what cannot be played yet.
    private var stateText: Text {
        var parts: [Text] = []
        if !episode.isAired {
            parts.append(Text("Not out yet").foregroundColor(SumiTheme.muted))
        } else if isResuming {
            parts.append(Text("Resume").foregroundColor(SumiTheme.indigo).fontWeight(.semibold))
        } else if episode.isWatched {
            parts.append(Text("Watched").foregroundColor(SumiTheme.success))
        } else if isResumeTarget {
            parts.append(Text("Up next").foregroundColor(SumiTheme.indigo).fontWeight(.semibold))
        }
        switch downloadState {
        case .notStarted: break
        case .downloading(let percent):
            parts.append(Text("Downloading \(Int(percent))%").foregroundColor(SumiTheme.muted))
        case .done:
            parts.append(Text("Downloaded").foregroundColor(SumiTheme.success))
        case .failed:
            parts.append(Text("Download failed").foregroundColor(SumiTheme.danger))
        }
        return DetailStateText.join(parts)
            .font(.system(size: 11.5))
            .monospacedDigit()
    }

    private var thumbnail: some View {
        Color.clear
            .frame(width: 132, height: 74)
            .overlay {
                CachedAsyncImage(url: episode.thumbnailURL, maxPixelSize: 264) { image in
                    image
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .opacity(episode.isAired ? 1 : 0.5)
                } placeholder: {
                    Rectangle().fill(SumiTheme.foreground.opacity(0.05))
                }
            }
            .clipped()
            .overlay {
                EpisodeProgressBar(isWatched: episode.isWatched, percent: episode.progressPercent)
            }
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
            .overlay(
                SumiRect(cornerRadius: SumiTheme.radiusSm)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .ifLet(morphSource) { view, source in
                view.matchedGeometryEffect(id: source.key, in: source.namespace)
            }
    }
}

/// The fill along the bottom of an episode's thumbnail.
///
/// The bar stays mounted at zero rather than being inserted when there is
/// something to show: an episode that becomes watched while the page is open
/// (85% during playback, or the mark action) has to run out to the end, and a
/// bar that appears already full pops instead.
private struct EpisodeProgressBar: View {
    let isWatched: Bool
    let percent: Double?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Seeded from the props in `init` and animated from `onChange`, not
    /// derived per body call — derived, a row that mounts watched would draw
    /// the fill every time it scrolled back into the list.
    @State private var fill: CGFloat

    init(isWatched: Bool, percent: Double?) {
        self.isWatched = isWatched
        self.percent = percent
        _fill = State(initialValue: Self.target(isWatched: isWatched, percent: percent))
    }

    /// A recorded position under 10% still shows a sliver: a bar too short to
    /// see reads as "never started", which is a different thing.
    private static func target(isWatched: Bool, percent: Double?) -> CGFloat {
        if isWatched { return 1 }
        guard let percent, percent > 0 else { return 0 }
        return min(max(CGFloat(percent / 100), 0.1), 1)
    }

    var body: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(SumiTheme.foreground.opacity(0.2))
            Rectangle()
                .fill(SumiTheme.indigo)
                .scaleEffect(x: fill, y: 1, anchor: .leading)
        }
        // An episode with nothing recorded shows no bar at all, track
        // included — that is what the thumbnail looked like before this was a
        // permanently mounted view.
        .opacity(fill > 0 ? 1 : 0)
        .frame(maxWidth: .infinity)
        .frame(height: 2.5)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onChange(of: Self.target(isWatched: isWatched, percent: percent)) { _, newTarget in
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .smooth(duration: 0.4)) {
                fill = newTarget
            }
        }
    }
}
