import SwiftUI
import AnicatCoreKit

public struct MediaDetailView: View {
    public enum DetailTab: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case manga = "Manga"
        case characters = "Cast & Staff"
        case related = "Related"
        case discussions = "Discussions"
        case details = "Details"
        case more = "More"

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
            runtimeMinutes: Int? = nil,
            isAired: Bool = true
        ) {
            self.synopsis = synopsis
            self.airDate = airDate
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
    private var selectedAudioType: AudioType { AudioType(stored: storedSubDub) }
    @State private var selectedViewMode: EpisodeViewMode = .cards
    /// Which season the episode list is filtered to, once someone picks one.
    /// Nil means "whichever the resume position is in" -- see
    /// `defaultSeason`, and note it must not be resolved at init: the
    /// seasons arrive with the extras, after the page is already on screen.
    @State private var selectedSeason: Int32?
    @State private var isSynopsisExpanded = false
    @State private var isBackHovered = false
    /// Set from the scroll offset, but only ever as this Bool — see
    /// `ScrollPassedThreshold` for why the offset itself never lands in state.
    @State private var isHeaderCompact = false
    /// The trailer plays over the banner, opened only from the Trailer link.
    @State private var isTrailerOpen = false
    @State private var isTrailerLinkHovered = false
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


    /// Overlap of the content column onto the banner. Sized to match the web app
    /// (-mt-28 / 112pt) where the poster and title overlap the bottom hero gradient.
    private let bannerOverlap: CGFloat = 112

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
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
                        .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusXl).stroke(SumiTheme.border, lineWidth: 1))
                        .shadow(color: .black.opacity(0.6), radius: 40, y: 16)
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
        .background(SumiTheme.background)
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

    /// The banner's 288pt layout slot. The still itself is not in here: it
    /// is `heroBackdrop`, drawn behind this slot and the poster row as one
    /// image, so there is no edge at 288pt to hide.
    private var banner: some View {
        ZStack(alignment: .topLeading) {
            // The slot keeps its height without content so the page's
            // layout (`bannerOverlap`, the compact-header threshold) is
            // unchanged from when the still was drawn in it.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 288)

            // Top Left Back Button
            VStack(alignment: .leading) {
                Button(action: onClose) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .foregroundColor(isBackHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.75))
                    .shadow(color: .black.opacity(0.6), radius: 2, y: 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                #if os(macOS)
                .onHover { isBackHovered = $0 }
                #endif
                .animation(.snappy, value: isBackHovered)
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
        .frame(height: 288)
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

    private var compactHeader: some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Color.clear
                    .frame(width: 19, height: 28)
                    .overlay {
                        CachedAsyncImage(url: details.coverURL, maxPixelSize: 96) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 3))

                Text(details.title)
                    .font(.sumiHeading(size: 13, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
            }
            // The bar sits over the scroll view, and on macOS a view that
            // hit-tests there eats the scroll wheel above it. Only the pill
            // needs clicks; everything else stays transparent to the pointer
            // so the page still scrolls under the bar.
            .allowsHitTesting(false)

            Spacer(minLength: 12)

            if let episode = resumeTarget {
                Button {
                    startingPlayback { onPlayEpisode(episode) }
                } label: {
                    Label(compactActionLabel, systemImage: "play.fill")
                        .fontWeight(.semibold)
                }
                .sumiPrimaryButton()
            }
        }
        .padding(.horizontal, 56)
        .padding(.vertical, 9)
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

    /// The compact pill's label. Built from the same `resumeTarget` and
    /// `resumeSecondsForTarget` as the full-size button, so the header and the
    /// hero cannot disagree about whether there is a resume point.
    private var compactActionLabel: String {
        guard let target = resumeTarget else { return "Play" }
        if resumeSecondsForTarget != nil { return "Resume Ep \(target.number)" }
        return "Ep \(target.number)"
    }

    // MARK: - Content

    private var content: some View {
        HStack(alignment: .top, spacing: 32) {
            poster
            info
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 28)
        .frame(maxWidth: 1150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, -bannerOverlap)
    }

    private var poster: some View {
        Color.clear
            .frame(width: 192, height: 288)
            .overlay {
                CachedAsyncImage(url: details.coverURL, maxPixelSize: 600) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.card)
                }
            }
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusXl)
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
            .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 16) {
            metaLine
                .padding(.top, 24)

            Text(details.title)
                .font(.sumiHeading(size: 36, weight: .bold))
                .tracking(-0.8)
                .lineSpacing(3)
                .foregroundColor(SumiTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if !details.genres.isEmpty {
                genreLine
            } else if isLoading {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 180, height: 12)
            }

            actionBar
                .padding(.top, 4)

            if let synopsis = details.synopsis, !synopsis.isEmpty {
                synopsisBlock(synopsis)
            } else if isLoading {
                SynopsisSkeleton()
            }
        }
    }

    /// Tabs and their content, full-width below the poster/info row. The web
    /// build keeps the episode list out of the poster's column — it spans the
    /// whole content width — and the native port had it squeezed beside the
    /// poster, leaving almost no room for episode descriptions or release
    /// names.
    private var tabsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
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
        .padding(.bottom, 64)
        .frame(maxWidth: 1150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    /// Full-width shelf between `content` and `tabsSection` that shows the
    /// previous / next season chain. Living here — outside the poster/info
    /// HStack — means it animates in without pushing the tabs bar down, since
    /// it's measured independently and doesn't share vertical space with the
    /// poster column that stops at 288pt.
    @ViewBuilder
    private var seasonStrip: some View {
        if details.prequel != nil || details.sequel != nil {
            HStack(spacing: 12) {
                if let prequel = details.prequel {
                    relationCard(prequel, label: "Previous season", leading: true)
                }
                if let sequel = details.sequel {
                    relationCard(sequel, label: "Next season", leading: false)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 56)
            .padding(.bottom, 28)
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .transition(.opacity.combined(with: .move(edge: .top)))
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
                            Image(systemName: "chevron.right")
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

    private enum MetaPart {
        case text(String, Color, bold: Bool)
        case studio
        case trailer
    }

    /// Only the parts this title has, so the separators fall between present
    /// items: a dot drawn beside an absent year or score left "TV · · 2024".
    private var metaParts: [MetaPart] {
        var parts: [MetaPart] = []
        if let format = details.format {
            parts.append(.text(MediaCard.displayFormat(format), SumiTheme.foreground, bold: true))
        }
        switch details.status {
        case "RELEASING": parts.append(.text("Airing", SumiTheme.indigo, bold: true))
        case "FINISHED": parts.append(.text("Finished", SumiTheme.success, bold: true))
        default: break
        }
        if let count = details.episodeCount, count > 0 {
            let unit = (episodes.isEmpty && !mangaChapters.isEmpty) ? "chapter" : "episode"
            parts.append(.text("\(count) \(unit)\(count == 1 ? "" : "s")", SumiTheme.indigo, bold: true))
        }
        if let year = details.year {
            parts.append(.text(String(year), SumiTheme.muted, bold: false))
        }
        if !mainStudios.isEmpty || details.studio != nil {
            parts.append(.studio)
        }
        if let score = details.averageScore, score > 0 {
            parts.append(.text("\(score)%", SumiTheme.indigo, bold: true))
        }
        if hasTrailer {
            parts.append(.trailer)
        }
        return parts
    }

    /// The one line of state above the title. Everything is muted except
    /// the things worth colouring: the format, the airing status, the counts.
    private var metaLine: some View {
        HStack(spacing: 0) {
            let parts = metaParts
            if details.format == nil && isLoading {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 44, height: 12)
                    .padding(.trailing, 12)
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 52, height: 12)
            }
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·")
                        .foregroundColor(SumiTheme.muted.opacity(0.6))
                        .padding(.horizontal, 7)
                }
                switch part {
                case let .text(label, color, bold):
                    Text(label)
                        .foregroundColor(color)
                        .fontWeight(bold ? .semibold : .regular)
                case .studio:
                    studioLine
                case .trailer:
                    trailerLink
                }
            }
            Spacer(minLength: 0)
        }
        .sumiTabularMono(size: 12)
    }

    /// The studios, each opening its own page. Falls back to the plain
    /// `studio` string for a snapshot written before `studios` existed and
    /// for any title AniList credits no studio ids for — the name was
    /// always shown here, and losing it to gain a button is not a trade.
    @ViewBuilder
    private var studioLine: some View {
        if !mainStudios.isEmpty {
            HStack(spacing: 6) {
                Text("Studio:")
                    .foregroundColor(SumiTheme.muted.opacity(0.7))
                ForEach(mainStudios) { studio in
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

    private var trailerLink: some View {
        Button {
            if isTrailerOpen {
                closeTrailer()
            } else {
                openTrailer()
            }
        } label: {
            Text(isTrailerOpen ? "Close trailer" : "Trailer")
                .foregroundColor(SumiTheme.indigo)
                .fontWeight(.semibold)
                .underline(isTrailerLinkHovered, color: SumiTheme.indigo.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .stableHover { isTrailerLinkHovered = $0 }
        .animation(.sumi(.pop), value: isTrailerLinkHovered)
    }

    /// Only called with at least one genre.
    private var genreLine: some View {
        let genres = details.genres.prefix(6)
        return genres.dropFirst().reduce(Text(genres.first ?? "")) { line, genre in
            line + Text("  /  ").foregroundColor(SumiTheme.muted.opacity(0.4)) + Text(genre)
        }
        .font(.system(size: 12))
        .foregroundColor(SumiTheme.muted)
    }

    /// One filled button; everything else is a word or a bare icon. Every
    /// action in its own rounded box at one height -- heart included -- read
    /// as a stock web button group, and the two menus drew no box at all
    /// next to their boxed neighbours.
    private var actionBar: some View {
        HStack(spacing: 14) {
            if !episodes.isEmpty {
                Button {
                    if let episode = resumeTarget { startingPlayback { onPlayEpisode(episode) } }
                } label: {
                    Label { primaryActionTitle } icon: { Image(systemName: "play.fill") }
                }
                .sumiPrimaryButton()
                .controlSize(.large)
                .disabled(resumeTarget == nil)

                // Only offered when the primary button actually says
                // "Resume": next to "Play Ep 1" there is nothing to start
                // over from and the control would be noise.
                if let episode = resumeTarget, resumeSecondsForTarget != nil {
                    textAction("Start over") { startingPlayback { onPlayEpisodeFromStart(episode) } }
                }
            } else if let target = resumeChapter {
                Button {
                    onReadChapter(target)
                } label: {
                    // "Continue", not "Resume": a chapter has no saved
                    // page offset to come back to, and the Up Next shelf
                    // already draws the same distinction by unit.
                    Label(isContinuingChapters
                          ? "Continue Ch \(target.number)"
                          : "Read Ch \(target.number)", systemImage: "book.fill")
                }
                .sumiPrimaryButton()
                .controlSize(.large)

                // Same rule as the episode branch above: offered only when
                // the primary button points somewhere other than chapter 1,
                // where "start over" would be the button next to itself.
                if isContinuingChapters, let first = mangaChapters.first {
                    textAction("Start over") { onReadChapter(first) }
                }
            }

            if !episodes.isEmpty || resumeChapter != nil {
                actionDivider
            }

            if !tracksOnAniList {
                Menu {
                    ForEach(["PLANNING", "CURRENT", "COMPLETED", "DROPPED"], id: \.self) { status in
                        Button(Self.statusLabel(status)) { onSetCinemaListStatus(status) }
                    }
                    if cinemaListStatus != nil {
                        Divider()
                        Button("Remove from list") { onSetCinemaListStatus(nil) }
                    }
                } label: {
                    // Called, not passed by name: a reference to the function
                    // loses its defaulted `manga:` and no longer matches
                    // `map`'s single-argument closure.
                    Text(cinemaListStatus.map { Self.statusLabel($0) } ?? "Add to list")
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            // AniList owns the list status, the score and the heart. A cinema
            // page has no entry to write to -- and its id is TMDB's, which
            // AniList would read as whatever anime carries the same number.
            if tracksOnAniList {
                Menu {
                    ForEach(Self.listStatusOptions, id: \.self) { status in
                        Button(Self.statusLabel(status, manga: isMangaMedia)) { onSetListStatus(status) }
                    }
                } label: {
                    // No manual chevron: `.borderlessButton` draws its own
                    // caret, and a second one stacked two arrows side by side.
                    Text(Self.statusLabel(details.listStatus, manga: isMangaMedia))
                        .font(.system(size: 13, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                actionDivider

                Button(action: onToggleFavourite) {
                    Image(systemName: details.isFavourite ? "heart.fill" : "heart")
                        .font(.system(size: 15))
                        .foregroundColor(details.isFavourite ? SumiTheme.favourite : SumiTheme.muted)
                        .frame(width: 28, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(details.isFavourite ? "Remove from favourites" : "Add to favourites")
            }

            // AniList only. A TMDB title is on no AniList list and never was
            // -- cinema keeps its watchlist in the local registry, and the
            // status menu a few lines up already offers "Remove from list"
            // for it. This menu named the wrong service, and its one item was
            // permanently disabled there because a film has no list entry id.
            if details.mediaCatalog == .anilist {
                Menu {
                    Button(role: .destructive, action: onRemoveFromList) {
                        Label("Remove from AniList", systemImage: "trash")
                    }
                    .disabled(details.listEntryId == nil)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }

            Spacer(minLength: 0)
        }
    }

    private var actionDivider: some View {
        Rectangle()
            .fill(SumiTheme.border)
            .frame(width: 1, height: 16)
    }

    private func textAction(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
                .frame(height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
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
        default: return "Add to List"
        }
    }

    private func hairlineControl<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundColor(SumiTheme.foreground.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(SumiTheme.card.opacity(0.8))
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
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
    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SumiSlashToggle(
                seasons.map { ($0.number, "Season \($0.number)") },
                selection: selectedSeason ?? defaultSeason
            ) { number in
                withAnimation(.snappy(duration: 0.25)) { selectedSeason = number }
            }
            .padding(.vertical, 2)
        }
        .backSwipeExempt()
    }

    /// A film: one sitting, numbered 1 only because the registry, the resume
    /// position and the remembered release all key on an episode number.
    /// Nothing on the page should say "Episode 1" about it.
    private var isSingleSitting: Bool {
        details.format?.uppercased() == "MOVIE" && episodes.count <= 1
    }

    /// "Resume Ep 4  1:53", the time a step quieter: as one string,
    /// "Resume Episode 4 · 1:53" was the longest label in the row.
    private var primaryActionTitle: Text {
        guard let target = resumeTarget else { return Text("Nothing to play") }
        let episode = isSingleSitting ? "" : " Ep \(target.number)"
        if let seconds = resumeSecondsForTarget {
            return Text("Resume\(episode)")
                + Text("  \(Self.clock(seconds))")
                    .fontWeight(.medium)
                    .foregroundColor(SumiTheme.background.opacity(0.72))
        }
        if isSingleSitting {
            return Text(target.isWatched ? "Watch again" : "Play")
        }
        return Text(target.isWatched ? "Rewatch\(episode)" : "Play\(episode)")
    }

    static func clock(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

    private func synopsisBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis")
                .sumiTabularMono(size: 11.5, weight: .semibold)
                .foregroundColor(SumiTheme.indigo)

            // Body copy, not metadata: it reads at foreground/80 rather than
            // the muted token the labels around it use.
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4.5)
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
                .lineLimit(isSynopsisExpanded ? nil : 3)
                .sumiTextSelectable()
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.snappy) { isSynopsisExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(isSynopsisExpanded ? "Show less" : "Read more")
                    Image(systemName: isSynopsisExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(SumiTheme.foreground.opacity(0.5))
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
        }
    }

    private func relationCard(_ relation: HeroBanner.Details.Relation, label: String, leading: Bool) -> some View {
        RelationCardView(relation: relation, label: label, leading: leading, onSelect: onSelectRelation)
    }

    struct RelationCardView: View {
        let relation: HeroBanner.Details.Relation
        let label: String
        let leading: Bool
        let onSelect: ((HeroBanner.Details.Relation) -> Void)?

        @State private var isHovered = false

        var body: some View {
            Button {
                onSelect?(relation)
            } label: {
                HStack(spacing: 10) {
                    if leading {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SumiTheme.muted)
                        Rectangle()
                            .fill(SumiTheme.card)
                            .frame(width: 36, height: 48)
                            .overlay {
                                CachedAsyncImage(url: relation.coverURL, maxPixelSize: 96) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(SumiTheme.card)
                                }
                            }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .sumiTabularMono(size: 9.5, weight: .bold)
                                .foregroundColor(SumiTheme.indigo)
                            Text(relation.title)
                                .font(.sumiHeading(size: 13, weight: .bold))
                                .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                                .lineLimit(1)
                            if let format = relation.format {
                                Text(MediaCard.displayFormat(format))
                                    .sumiTabularMono(size: 9.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(label)
                                .sumiTabularMono(size: 9.5, weight: .bold)
                                .foregroundColor(SumiTheme.indigo)
                            Text(relation.title)
                                .font(.sumiHeading(size: 13, weight: .bold))
                                .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                                .lineLimit(1)
                            if let format = relation.format {
                                Text(MediaCard.displayFormat(format))
                                    .sumiTabularMono(size: 9.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        Rectangle()
                            .fill(SumiTheme.card)
                            .frame(width: 36, height: 48)
                            .overlay {
                                CachedAsyncImage(url: relation.coverURL, maxPixelSize: 96) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(SumiTheme.card)
                                }
                            }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SumiTheme.muted)
                    }
                }
                // No box: the poster, the label and the arrow already say it
                // is a link, and the title inks indigo under the pointer.
                .padding(.vertical, 8)
                .frame(maxWidth: 290)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .contentShape(Rectangle())
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }
    }

    // MARK: - Tabs

    private var isMangaMedia: Bool {
        if let f = details.format, ["MANGA", "NOVEL", "ONE_SHOT"].contains(f) {
            return true
        }
        return episodes.isEmpty && !mangaChapters.isEmpty
    }

    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        if isMangaMedia {
            tabs.append(.manga)
            if !episodes.isEmpty {
                tabs.append(.episodes)
            }
        } else {
            tabs.append(.episodes)
            if !mangaChapters.isEmpty {
                tabs.append(.manga)
            }
        }
        tabs.append(.characters)
        // cinemaExtras alone used to gate this: a stale write racing in from
        // a just-left Cinema page's deferred extras task could still land it
        // on an AniList page, and this was the only thing standing between
        // that race and a wrong "N seasons" row on screen. tracksOnAniList
        // is a second, independent check against the same failure mode.
        if cinemaExtras != nil, !tracksOnAniList { tabs.append(.details) }
        // Relations and discussions are AniList's: a TMDB title has neither a
        // franchise graph nor a forum thread, so the two tabs would open on
        // an empty page saying nothing about why.
        if tracksOnAniList {
            tabs.append(.related)
            tabs.append(.discussions)
        }
        tabs.append(.more)
        return tabs
    }

    private func tabLabel(_ tab: DetailTab) -> String {
        switch tab {
        case .episodes:
            if episodes.isEmpty { return "Episodes" }
            if isSingleSitting { return "Film" }
            if isAwaitingSeasonBreakdown { return "Episodes" }
            // The show-wide total read as a lie once the list under it
            // started scoping to one TMDB season: "EPISODES (37)" over six
            // rows for The Grand Tour's season 1. Count what's on screen.
            return "Episodes (\(episodesForSelectedSeason.count))"
        case .manga: return mangaChapters.isEmpty ? "Chapters" : "Chapters (\(mangaChapters.count))"
        case .characters: return characters.isEmpty ? "Cast & staff" : "Cast & staff (\(characters.count))"
        case .related:
            let count = relations.isEmpty ? ((details.prequel != nil ? 1 : 0) + (details.sequel != nil ? 1 : 0)) : relations.count
            return count > 0 ? "Related (\(count))" : "Related"
        case .discussions: return discussions.isEmpty ? "Discussions" : "Discussions (\(discussions.count))"
        case .details: return "Details"
        case .more: return recommendations.isEmpty ? "More" : "More (\(recommendations.count))"
        }
    }

    private var activeTab: DetailTab {
        if availableTabs.contains(selectedTab) {
            return selectedTab
        }
        return availableTabs.first ?? .episodes
    }

    private var tabBar: some View {
        HStack(alignment: .bottom, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 18) {
                    ForEach(availableTabs) { tab in
                        let isSelected = activeTab == tab
                        Button {
                            if activeTab != tab {
                                SumiHaptics.selection()
                                withAnimation(.snappy) {
                                    selectedTab = tab
                                }
                            }
                        } label: {
                            VStack(spacing: 8) {
                                Text(tabLabel(tab))
                                    .sumiTabularMono(size: 12, weight: isSelected ? .semibold : .medium)
                                    .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                                    .lineLimit(1)
                                ZStack {
                                    Rectangle()
                                        .fill(Color.clear)
                                        .frame(height: 2)
                                    // Appears on the chosen tab rather than
                                    // sliding across: the moving underline
                                    // was the same web tab motion taken out of
                                    // the sidebar and Settings.
                                    if isSelected {
                                        Rectangle()
                                            .fill(SumiTheme.indigo)
                                            .frame(height: 2)
                                    }
                                }
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
            }
            .backSwipeExempt()

            Spacer(minLength: 12)

            // Right side: Audio and ViewMode toggles. Only the episodes tab
            // can use them, but they stay in the layout on every tab. This
            // row is `.bottom` aligned and, measured, the controls are 30pt
            // against the tab strip's 25 — dropping them took the bar from
            // 30pt to 25 and lifted the labels and the whole page under them
            // on every switch away from Episodes.
            if !episodes.isEmpty {
                let showsEpisodeControls = activeTab == .episodes
                HStack(spacing: 14) {
                    if tracksOnAniList {
                        SumiSlashToggle(
                            [(AudioType.sub, "Sub"), (AudioType.dub, "Dub")],
                            selection: selectedAudioType
                        ) { storedSubDub = $0.storedValue }
                        .help("Subtitled Japanese audio, or English dub")

                        Rectangle()
                            .fill(SumiTheme.border)
                            .frame(width: 1, height: 14)
                    }

                    SumiSlashToggle(
                        EpisodeViewMode.allCases.map { ($0, $0.rawValue) },
                        selection: selectedViewMode
                    ) { mode in withAnimation(.snappy) { selectedViewMode = mode } }
                }
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
                .padding(.bottom, 6)
                .opacity(showsEpisodeControls ? 1 : 0)
                .allowsHitTesting(showsEpisodeControls)
                .accessibilityHidden(!showsEpisodeControls)
            }
        }
        .overlay(Rectangle().fill(SumiTheme.border).frame(height: 1), alignment: .bottom)
    }

    /// A crossfade. Tabs used to slide in 12pt from the side they sat on,
    /// a web carousel habit; a Mac tab view swaps its content in place.
    private var tabTransition: AnyTransition { .opacity }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .episodes:
            // Its own View struct, not another computed property here: this
            // is the one section whose backing state (`downloadStates`)
            // mutates on a 1s poll while a download runs. Inlined as a
            // computed property it register that dependency on the whole
            // 1854-line `body` above, so every tick re-evaluated the entire
            // detail page — banner, tabs, unrelated sections — to redraw one
            // row's percentage.
            VStack(alignment: .leading, spacing: 12) {
                if seasons.count > 1 {
                    seasonPicker
                }
                EpisodeListSection(
                    episodes: episodesForSelectedSeason,
                    resumeEpisode: details.resumeEpisode,
                    resumeSeconds: details.resumeSeconds,
                    selectedViewMode: selectedViewMode,
                    downloadStates: downloadStates,
                    isLoading: isLoading || isAwaitingSeasonBreakdown,
                    onPlayEpisode: { episode in startingPlayback { onPlayEpisode(episode) } },
                    onSetEpisodeWatched: onSetEpisodeWatched,
                    onLoadReleaseCandidates: onLoadReleaseCandidates,
                    onPlayWithRelease: { episode, name in startingPlayback { onPlayWithRelease(episode, name) } },
                    onDownloadEpisode: downloadEpisode,
                    catalogId: details.id,
                    playerNamespace: playerNamespace,
                    playerSourceKey: playerSourceKey
                )
            }
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
        case .characters:
            CharactersTabSection(titleId: details.id, characters: characters, onSelectCharacter: onSelectCharacter)
        case .related:
            RelatedTabSection(
                details: details,
                relations: relations,
                prequel: details.prequel,
                sequel: details.sequel,
                onSelectRelation: onSelectRelation,
                onSelectMediaId: onSelectMediaId
            )
        case .discussions:
            DiscussionsTabSection(discussions: discussions, onSelectThread: onSelectThread)
        case .details:
            if let cinemaExtras {
                CinemaDetailsTabSection(extras: cinemaExtras, genres: details.genres)
            }
        case .more:
            RecommendationsTabSection(recommendations: recommendations, onSelectMediaId: onSelectMediaId)
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

    struct ChapterRowView: View {
        let chapter: MediaDetailView.MangaChapterItem
        var offline: ChapterOfflineState = .none
        var onDownload: (() -> Void)?
        var onDeleteDownload: (() -> Void)?
        let onRead: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onRead) {
                HStack(spacing: 12) {
                    Text("Ch \(chapter.number)")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.indigo)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.title)
                            .font(.sumiHeading(size: 13.5, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                        // MangaDex's API rules make crediting the scanlation
                        // group a condition of use. The phone row credited
                        // it from the start; this one listed the chapter as
                        // if nobody had translated it.
                        if let group = chapter.scanlationGroup, !group.isEmpty {
                            Text(group)
                                .sumiTabularMono(size: 10.5)
                                .foregroundColor(SumiTheme.muted)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    offlineControl
                }
                // Ruled rows like the episode list, not a box per chapter.
                .padding(.horizontal, 4)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }

        /// Download, or the state of one. Shown on hover while a chapter is
        /// not downloaded, and always once it is: an icon that appears only
        /// under the pointer is fine for an action, and wrong for the fact
        /// that something is already on disk.
        @ViewBuilder
        private var offlineControl: some View {
            switch offline {
            case .stored:
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.indigo)
                    .onTapGesture { onDeleteDownload?() }
                    .help("Downloaded — click to remove")
            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            case .exporting:
                // Not reachable for a chapter -- only a volume exports -- but
                // the state is shared and a switch has to be exhaustive.
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
            case .failed:
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.warning)
                    .onTapGesture { onDownload?() }
                    .help("Download failed — click to retry")
            case .none:
                if isHovered, onDownload != nil {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.muted)
                        .onTapGesture { onDownload?() }
                        .help("Download for offline reading")
                }
            }
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
                        .frame(width: 44, height: 60)
                        .overlay {
                            CachedAsyncImage(url: relation.coverURL, maxPixelSize: 120) { image in
                                image.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(SumiTheme.card)
                            }
                        }
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(MediaCard.displayRelation(relation.relationType))
                            .sumiTabularMono(size: 9.5)
                            .foregroundColor(SumiTheme.indigo)

                        Text(relation.title)
                            .font(.sumiHeading(size: 13, weight: .semibold))
                            .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let format = relation.format {
                                Text(MediaCard.displayFormat(format))
                                    .sumiTabularMono(size: 9.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                            if let score = relation.averageScore, score > 0 {
                                Text("· \(score)%")
                                    .sumiTabularMono(size: 9.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 4)
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
    }

    struct DiscussionRowView: View {
        let thread: MediaDetailView.DiscussionItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                rowContent
            }
            .buttonStyle(.sumiPressable)
            .contentShape(Rectangle())
        }

        private var rowContent: some View {
            HStack(spacing: 12) {
                // The count as a figure, not a speech-bubble icon on every
                // row of the list.
                Text("\(thread.replyCount)")
                    .sumiTabularMono(size: 12, weight: .semibold)
                    .foregroundColor(SumiTheme.indigo)
                    .frame(width: 40, alignment: .leading)
                    .help("\(thread.replyCount) replies")

                VStack(alignment: .leading, spacing: 3) {
                    Text(thread.title)
                        .font(.sumiHeading(size: 13, weight: .medium))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        if let author = thread.authorName {
                            Text(author)
                                .font(.system(size: 10.5))
                                .foregroundColor(SumiTheme.muted)
                        }
                        if thread.viewCount > 0 {
                            Text("· \(thread.viewCount) views")
                                .font(.system(size: 10.5))
                                .foregroundColor(SumiTheme.muted.opacity(0.7))
                        }
                    }
                }

                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SumiTheme.border).frame(height: 1)
            }
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }
    }

    struct RecommendationCardView: View {
        let rec: MediaDetailView.RecommendationItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
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
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))

                    Text(rec.title)
                        .font(.sumiHeading(size: 11.5, weight: .bold))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    // The rating under the poster with the format, not a badge
                    // stamped on the art in hard-coded black.
                    HStack(spacing: 6) {
                        if let format = rec.format {
                            Text(MediaCard.displayFormat(format))
                                .foregroundColor(SumiTheme.muted)
                        }
                        if let rating = rec.rating, rating > 0 {
                            Text("\(rating)%")
                                .foregroundColor(SumiTheme.indigo)
                                .fontWeight(.semibold)
                        }
                    }
                    .sumiTabularMono(size: 10)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
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

/// One episode, as a compact row.
/// The `.episodes` tab's list, pulled out of `MediaDetailView.tabContent` so
/// `downloadStates` polling only re-evaluates this struct's own body, not
/// the whole detail page.
private struct EpisodeListSection: View {
    let episodes: [MediaDetailView.EpisodeItem]
    let resumeEpisode: Int?
    let resumeSeconds: Int?
    let selectedViewMode: MediaDetailView.EpisodeViewMode
    let downloadStates: () -> [Int: MediaDetailView.EpisodeDownloadState]
    var isLoading: Bool = false
    let onPlayEpisode: (MediaDetailView.EpisodeItem) -> Void
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

    // Evaluated once per section body, not once per row, so a plain
    // computed property is enough. It was a `@State` cache that nothing
    // ever assigned, so no row was ever the resume target.
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
    private func compactRows(for episodes: [MediaDetailView.EpisodeItem]) -> some View {
        ForEach(episodes) { episode in
            CompactEpisodeRow(
                episode: episode,
                isResumeTarget: episode.id == resumeTarget?.id,
                resumeSeconds: episode.number == resumeEpisode ? resumeSeconds : nil,
                onPlay: { onPlayEpisode(episode) },
                onToggleWatched: { watched in onSetEpisodeWatched(episode.number, watched) }
            )
            .equatable()
        }
    }

    @ViewBuilder
    private func regularRows(for episodes: [MediaDetailView.EpisodeItem], downloadStates: [Int: MediaDetailView.EpisodeDownloadState]) -> some View {
        ForEach(episodes) { episode in
            EpisodeRow(
                episode: episode,
                isResumeTarget: episode.id == resumeTarget?.id,
                resumeSeconds: episode.number == resumeEpisode ? resumeSeconds : nil,
                downloadState: downloadStates[episode.number] ?? .notStarted,
                onPlay: { onPlayEpisode(episode) },
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
        "Episodes \(firstNumber)-\(firstNumber + count - 1)"
    }

    var body: some View {
        let downloadStates = downloadStates()
        Group {
            if episodes.isEmpty {
                if isLoading {
                    EpisodeListSkeleton(count: 6, isCompact: selectedViewMode == .compact)
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
                            if selectedViewMode == .compact {
                                compactRows(for: group.episodes)
                            } else {
                                regularRows(for: group.episodes, downloadStates: downloadStates)
                            }
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
                .task(id: [episodes.first?.number ?? 0, resumeTarget?.number ?? 0]) {
                    let target = resumeTarget?.number
                    let owning = target.flatMap { number in
                        groups.first { $0.episodes.contains { $0.number == number } }
                    } ?? groups.first
                    if let owning {
                        expandedGroups.insert(owning.firstNumber)
                    }
                }
            } else if selectedViewMode == .compact {
                LazyVStack(spacing: 0) {
                    compactRows(for: episodes)
                }
            } else {
                LazyVStack(spacing: 0) {
                    regularRows(for: episodes, downloadStates: downloadStates)
                }
            }
        }
        .animation(.smooth, value: selectedViewMode)
    }
}

private struct CompactEpisodeRow: View, Equatable {
    let episode: MediaDetailView.EpisodeItem
    let isResumeTarget: Bool
    let resumeSeconds: Int?
    let onPlay: () -> Void
    let onToggleWatched: (Bool) -> Void


    // See EpisodeRow.== — closures excluded deliberately, not an oversight.
    nonisolated static func == (lhs: CompactEpisodeRow, rhs: CompactEpisodeRow) -> Bool {
        lhs.episode == rhs.episode
            && lhs.isResumeTarget == rhs.isResumeTarget
            && lhs.resumeSeconds == rhs.resumeSeconds
    }

    var body: some View {
        row
            #if os(macOS)
            .contextMenu {
                Button(isResumeTarget ? "Resume" : "Play", action: onPlay)
                Button(episode.isWatched ? "Mark as unwatched" : "Mark as watched") {
                    onToggleWatched(!episode.isWatched)
                }
            }
            #endif
    }

    private var row: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    // Fixed width so titles start on one edge whether the
                    // number has one digit or four.
                    Text("Ep \(episode.number)")
                        .sumiTabularMono(size: 11, weight: .semibold)
                        .foregroundColor(isResumeTarget ? SumiTheme.indigo : (episode.isWatched ? SumiTheme.muted.opacity(0.6) : SumiTheme.muted))
                        .frame(width: 52, height: 28, alignment: .leading)

                    // Title
                    Text(episode.title)
                        .font(.sumiHeading(size: 13, weight: isResumeTarget ? .bold : .medium))
                        .foregroundColor(episode.isWatched ? SumiTheme.muted.opacity(0.6) : SumiTheme.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    if isResumeTarget, let seconds = resumeSeconds, seconds > 0 {
                        Text("Resume \(MediaDetailView.clock(seconds))")
                            .sumiTabularMono(size: 10.5, weight: .semibold)
                            .foregroundColor(SumiTheme.indigo)
                    }

                    if let runtime = episode.runtimeMinutes, runtime > 0 {
                        Text("\(runtime)m")
                            .sumiTabularMono(size: 10.5)
                            .foregroundColor(SumiTheme.muted.opacity(0.6))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)

            Button(action: { onToggleWatched(!episode.isWatched) }) {
                WatchedTick(isWatched: episode.isWatched, diameter: 16)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help(episode.isWatched ? "Mark unwatched" : "Mark watched")
        }
        // Ruled like the card rows, not boxed: the resume row is marked by
        // its indigo number and "Resume" time, not by a tinted outline.
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
    }
}

/// One episode, as a card: thumbnail with its state drawn on it, then the
/// meta line, title and description.
private struct EpisodeRow: View, Equatable {
    let episode: MediaDetailView.EpisodeItem
    let isResumeTarget: Bool
    let resumeSeconds: Int?
    let downloadState: MediaDetailView.EpisodeDownloadState
    let onPlay: () -> Void
    /// Mark-watched checkbox. Nested inside a real `Button` here rather than
    /// as a second `Button` inside `onPlay`'s label — two buttons sharing one
    /// hit area is unreliable in SwiftUI; this one lives outside `onPlay`'s
    /// button entirely, alongside it in the row's `HStack`.
    let onToggleWatched: (Bool) -> Void
    let onOpenServerPicker: () -> Void
    let onDownload: () -> Void
    // The popover used to be attached to the whole episode list's container
    // view instead of this row's own button, so SwiftUI anchored it to that
    // container's position, not to wherever the viewer actually clicked —
    // it could open anywhere on screen depending on scroll offset. Owning
    // presentation state per-row (driven by the parent's single
    // `serverPickerEpisode`, so only one row is ever open) anchors it to the
    // real button.
    let isServerPickerOpen: Bool
    let isLoadingServers: Bool
    let serverCandidates: [MediaDetailView.ReleaseCandidateItem]
    let onCloseServerPicker: () -> Void
    let onSelectServer: (String) -> Void
    /// Non-nil on exactly the row whose Play was just pressed, which makes
    /// this row's still the source the player's placeholder flies out of.
    /// Nil everywhere else, so only one view ever carries the id.
    let morphSource: EpisodeMorphSource?

    @State private var isHovered = false

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

    private static let airDateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
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

    var body: some View {
        row
            #if os(macOS)
            // The hover-only buttons on the right are the same actions; a
            // Mac user right-clicks a row before hunting for them.
            .contextMenu {
                Button(isResumeTarget ? "Resume" : "Play", action: onPlay)
                Button(episode.isWatched ? "Mark as unwatched" : "Mark as watched") {
                    onToggleWatched(!episode.isWatched)
                }
                if case .notStarted = downloadState {
                    Button("Download", action: onDownload)
                }
                Button("Choose release…", action: onOpenServerPicker)
            }
            #endif
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 10) {
            Button(action: onPlay) {
                HStack(alignment: .top, spacing: 14) {
                    thumbnail
                    VStack(alignment: .leading, spacing: 3) {
                        metaLine
                        Text(episode.title)
                            .font(.sumiHeading(size: 13.5, weight: isResumeTarget ? .bold : .semibold))
                            .foregroundColor(episode.isWatched ? SumiTheme.muted : SumiTheme.foreground)
                            .lineLimit(1)
                        if let synopsis = episode.synopsis, !synopsis.isEmpty {
                            Text(synopsis)
                                .font(.system(size: 12.5))
                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)

            Button(action: onOpenServerPicker) {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundColor(SumiTheme.muted.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Choose a release")
            .padding(.top, 3)
            // Only under the pointer (and while its picker is open): the
            // same three grey icons on all 26 rows read as a generic actions
            // column. Faded rather than removed, so nothing shifts on hover;
            // both actions are on the row's right-click menu too.
            .opacity(isHovered || isServerPickerOpen ? 1 : 0)
            .allowsHitTesting(isHovered || isServerPickerOpen)
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

            downloadButton
                // One footprint for every state, so the buttons beside it
                // do not shift when the arrow becomes a 15pt ring; and a
                // spring on the swap, because the tap used to change
                // nothing visible until the first progress poll a second
                // later.
                .frame(width: 24, height: 24)
                .animation(.snappy, value: downloadState)
                .padding(.top, 3)
                // A download in progress, done or failed is news and stays;
                // the bare arrow is an action and waits for the pointer.
                .opacity(isHovered || downloadState != .notStarted ? 1 : 0)
                .allowsHitTesting(isHovered || downloadState != .notStarted)

            Button(action: { onToggleWatched(!episode.isWatched) }) {
                WatchedTick(isWatched: episode.isWatched, diameter: 18)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help(episode.isWatched ? "Mark unwatched" : "Mark watched")
            .padding(.top, 2)
        }
        // Rows on the page ground with a hairline under each, not a rounded
        // bordered card per episode: 26 boxes stacked with gaps was the web
        // card-list look, and every other list in the app is ruled now.
        .padding(.vertical, 12)
        .padding(.horizontal, 4)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
        .opacity(episode.isWatched ? (isHovered ? 0.90 : 0.55) : 1.0)
        .stableHover { isHovered = $0 }
        .animation(.snappy, value: isHovered)
    }

    /// How one download state gives way to the next. On every branch below
    /// rather than once on the `switch`: a transition on the conditional as
    /// a whole runs when the button enters or leaves the row, not when the
    /// branch changes.
    private static let downloadStateSwap: AnyTransition = .scale(scale: 0.6).combined(with: .opacity)

    @ViewBuilder
    private var downloadButton: some View {
        switch downloadState {
        case .notStarted:
            Button(action: onDownload) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 15))
                    .foregroundColor(SumiTheme.muted.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Download Episode")
            .transition(Self.downloadStateSwap)
        case .downloading(let percent):
            ZStack {
                Circle()
                    .stroke(SumiTheme.muted.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: max(0.03, percent / 100))
                    .stroke(SumiTheme.indigo, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .help("Downloading… \(Int(percent))%")
            .transition(Self.downloadStateSwap)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.successLight)
                .help("Downloaded")
                .transition(Self.downloadStateSwap)
        case .failed(let message):
            Button(action: onDownload) {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 15))
                    .foregroundColor(SumiTheme.dangerLight)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Download failed: \(message) — click to retry")
            .transition(Self.downloadStateSwap)
        }
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text("Ep \(episode.number)")
                .foregroundColor(SumiTheme.indigo)
                .fontWeight(.semibold)
            if let airDate = episode.airDate {
                Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))
                Text(Self.formatAirDate(airDate)).foregroundColor(SumiTheme.muted)
            }
            if let seconds = resumeSeconds, seconds > 0 {
                Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))
                // A size up and semibold: with no tinted box around the row,
                // this is what marks the episode to resume.
                Text("Resume \(MediaDetailView.clock(seconds))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .monospacedDigit()
                    .foregroundColor(SumiTheme.indigo)
            }
        }
        .sumiTabularMono(size: 10)
    }

    private var thumbnail: some View {
        ZStack(alignment: .bottomTrailing) {
            Color.clear
                .frame(width: 128, height: 72)
                .overlay {
                    CachedAsyncImage(url: episode.thumbnailURL, maxPixelSize: 256) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            // A watched episode's still is dimmed rather
                            // than removed: the list stays scannable by
                            // picture.
                            .opacity(episode.isWatched ? 0.5 : 1)
                    } placeholder: {
                        Rectangle().fill(SumiTheme.foreground.opacity(0.05))
                    }
                }
                .clipped()

            if let minutes = episode.runtimeMinutes, minutes > 0 {
                Text("\(minutes)m")
                    .sumiTabularMono(size: 9)
                    // Over its own black chip, not the page: white at 80%
                    // whatever the skin, like the `23m` badge on a poster.
                    .foregroundColor(Color.white.opacity(0.8))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.black.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    .padding(4)
            }

            progressTick
        }
        .frame(width: 128, height: 72)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                .stroke(SumiTheme.border.opacity(0.4), lineWidth: 1)
        )
        .ifLet(morphSource) { view, source in
            view.matchedGeometryEffect(id: source.key, in: source.namespace)
        }
    }

    private var progressTick: some View {
        EpisodeProgressBar(isWatched: episode.isWatched, percent: episode.progressPercent)
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

/// The tick on an episode row's mark-watched control.
///
/// A stroked path with an animated `trim` rather than
/// `Image(systemName: "checkmark.circle.fill")`: an episode crosses 85% while
/// its own row is on screen, and a symbol can only pop into place there.
private struct WatchedTick: View {
    let isWatched: Bool
    let diameter: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the tick is drawn. Seeded in `init` rather than in
    /// `onAppear`: an already-watched row scrolling in would otherwise render
    /// its first frame with no tick, which flickers all the way down a
    /// finished season.
    @State private var drawn: CGFloat

    init(isWatched: Bool, diameter: CGFloat) {
        self.isWatched = isWatched
        self.diameter = diameter
        _drawn = State(initialValue: isWatched ? 1 : 0)
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(SumiTheme.muted.opacity(0.4), lineWidth: 1.4)
                .opacity(isWatched ? 0 : 1)
            Circle()
                .fill(SumiTheme.indigo)
                .opacity(isWatched ? 1 : 0)
            CheckmarkPath()
                .trim(from: 0, to: drawn)
                .stroke(
                    SumiTheme.background,
                    style: StrokeStyle(lineWidth: diameter * 0.13, lineCap: .round, lineJoin: .round)
                )
                .padding(diameter * 0.3)
        }
        .frame(width: diameter, height: diameter)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .snappy, value: isWatched)
        .onChange(of: isWatched) { _, watched in
            guard !reduceMotion else {
                drawn = watched ? 1 : 0
                return
            }
            // No extra bounce: an overshoot past 1 has no more tick to draw,
            // so the stroke would finish early and then sit there while the
            // spring settled.
            withAnimation(.snappy(duration: 0.35, extraBounce: 0)) {
                drawn = watched ? 1 : 0
            }
        }
    }
}

/// The tick itself, as a path so it can be trimmed. Proportional to its rect,
/// so the one shape serves both the card row and the compact row.
private struct CheckmarkPath: Shape {
    nonisolated func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}
