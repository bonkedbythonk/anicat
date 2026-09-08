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

        public init(name: String, seeders: Int, isDub: Bool) {
            self.id = name
            self.seeders = seeders
            self.isDub = isDub
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

        public init(
            id: Int64,
            number: Int,
            title: String,
            thumbnailURL: URL? = nil,
            isWatched: Bool = false,
            progressPercent: Double? = nil,
            synopsis: String? = nil,
            airDate: String? = nil,
            runtimeMinutes: Int? = nil
        ) {
            self.synopsis = synopsis
            self.airDate = airDate
            self.runtimeMinutes = runtimeMinutes
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
    /// +1 when the incoming tab sits further along the bar, -1 when it sits
    /// behind: which way `tabTransition` slides.
    @State private var tabSlide: CGFloat = 1
    /// The trailer plays over the banner. `trailerFromHover` separates the
    /// two ways it can be open: one that closes itself when the pointer
    /// leaves, and one the viewer asked for and has to close by hand.
    @State private var isTrailerOpen = false
    @State private var trailerFromHover = false
    @State private var isPosterHovered = false
    @State private var isTrailerHovered = false
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
    @Namespace private var detailTabNamespace
    @Namespace private var viewModeNamespace
    @Namespace private var audioNamespace

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
                VStack {
                    Spacer()
                    downloadToastView(toast)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
                .zIndex(55)
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.right")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Watch on \(TrailerPlayer.siteName(details.trailerSite))")
                                        .sumiTabularMono(size: 11)
                                }
                                .foregroundColor(SumiTheme.foreground)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(SumiTheme.card)
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.sumiPressable)
                        }
                        Button {
                            closeTrailer()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 10, weight: .bold))
                                Text("Close")
                                    .sumiTabularMono(size: 11)
                            }
                            .foregroundColor(SumiTheme.foreground)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(SumiTheme.card)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.sumiPressable)
                        .keyboardShortcut(.escape, modifiers: [])
                    }
                    .frame(width: width)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    // MARK: - Trailer

    /// False for a title with no trailer, and for one whose trailer is on a
    /// site `TrailerPlayer` cannot embed — the pill would otherwise open a
    /// black rectangle.
    private var hasTrailer: Bool {
        guard let trailerId = details.trailerId else { return false }
        return TrailerPlayer.embedURL(site: details.trailerSite, videoId: trailerId) != nil
    }

    /// The poster starts the trailer; the banner only keeps it alive. Both
    /// feed one value so the delay task below has a single id to key on.
    private var isTrailerRegionHovered: Bool { isPosterHovered || isTrailerHovered }

    /// One task per hover edge, cancelled by `task(id:)` the moment the
    /// pointer changes its mind — which is what lets both delays be long
    /// enough to mean something without a timer to invalidate by hand.
    private func followTrailerHover() async {
        guard hasTrailer else { return }
        if isTrailerRegionHovered {
            // Reduced motion leaves the pill and nothing else: video that
            // starts because a pointer came to rest is precisely the
            // movement the setting asks not to be shown.
            guard isPosterHovered, !isTrailerOpen, !MotionPolicy.reduce else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            openTrailer(fromHover: true)
        } else {
            // A trailer the viewer opened from the pill stays until they
            // close it; only the one hover opened closes itself.
            guard isTrailerOpen, trailerFromHover else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            closeTrailer()
        }
    }

    private func openTrailer(fromHover: Bool) {
        withAnimation(.sumi(.pop)) {
            isTrailerOpen = true
            trailerFromHover = fromHover
        }
        TrailerState.shared.isOpen = true
    }

    private func closeTrailer() {
        guard isTrailerOpen else { return }
        withAnimation(.sumi(.pop)) {
            isTrailerOpen = false
            trailerFromHover = false
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

    /// A capsule at the foot of the page: the shape `PlayerController.flashHUD`
    /// gives the same job over the picture.
    private func downloadToastView(_ toast: DownloadToast) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(SumiTheme.indigo)
            Text("Episode \(toast.episode) added to Downloads")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(SumiTheme.card)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(.bottom, 24)
    }

    private var scrollBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                banner
                content
                tabsSection
                moreFromStudio
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollPassedThreshold(Self.compactHeaderThreshold, passed: $isHeaderCompact)
        .background(SumiTheme.background)
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

    // MARK: - Banner

    private var banner: some View {
        ZStack(alignment: .topLeading) {
            SumiTheme.background

            // AsyncImage given a directly-flexible `.frame(maxWidth: .infinity)`
            // measured a specific banner (a portrait-leaning image scaled up
            // via `.fill`) as needing ~1150pt of width regardless of the
            // proposal, and being the outermost element of a freshly-`.id()`d
            // view, that ideal width won the negotiation with RootView's
            // HStack instead of losing to it — the page rendered 1150pt wide
            // starting at the window's left edge, over the sidebar. Every
            // other AsyncImage in this file (poster, episode thumbnails,
            // character portraits) sidesteps this by overlaying the image
            // onto an already-concretely-sized base instead of framing the
            // image itself; matching that pattern here fixed it.
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: 288)
                .overlay { bannerContent }
                .clipped()

            // `.hero-gradient`: the page ground at the bottom, a 60% black at
            // 40% up, clear at the top. Dropped while the trailer plays: it
            // exists to keep the title legible over a still, and over moving
            // video it only dims the thing the viewer asked to watch.
            if !isTrailerOpen {
                LinearGradient(
                    stops: [
                        .init(color: SumiTheme.background, location: 0),
                        .init(color: Color(red: 5/255, green: 5/255, blue: 5/255).opacity(0.6), location: 0.40),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
                .frame(height: 288)
                .allowsHitTesting(false)
            }

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
            .padding(.top, 24)
            .frame(maxWidth: 1150, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(height: 288)
        .clipped()
        // On the whole banner rather than on the web view itself: a
        // `WKWebView` is a child `NSView` with its own tracking areas, and
        // whether SwiftUI still sees the pointer over it is not something to
        // stake the auto-close timer on.
        .stableHover { isTrailerHovered = $0 }
    }

    /// The banner still. The trailer used to replace it here; it now opens
    /// as an overlay from `body`, so the hero never draws over an embed.
    @ViewBuilder
    private var bannerContent: some View {
        bannerImage
    }

    /// The banner still, moving at half the scroll speed and dimming as it
    /// goes.
    ///
    /// The effect is on the image and never on the 288pt container around it:
    /// shifting the container down uncovers the bottom of the banner, while
    /// the gap this leaves at the image's own top is always half the distance
    /// already scrolled off screen and so can never be seen. `visualEffect`
    /// reads the offset without publishing it, so none of this reaches the
    /// page body — no state, no scroll tick.
    private var bannerImage: some View {
        // Read out here because the effect closure is @Sendable and cannot
        // reach back into the view for it.
        let isStill = reduceMotion
        return CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 1200) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(SumiTheme.card)
        }
        .visualEffect { content, proxy in
            let scrolled = max(0, -proxy.frame(in: .scrollView).minY)
            return content
                .offset(y: isStill ? 0 : scrolled * 0.5)
                .brightness(-min(0.18, scrolled / 1600))
        }
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
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        Text(compactActionLabel)
                    }
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundColor(SumiTheme.background)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(SumiTheme.indigo)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.sumiPressable)
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
        if resumeSecondsForTarget != nil { return "Resume EP \(target.number)" }
        return "EP \(target.number)"
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
                view.matchedGeometryEffect(id: details.id, in: namespace)
            }
            // Same reasoning as `MediaCard`: matchedGeometryEffect only
            // animates frame, so without this the poster snapped into its
            // final size with no cross-fade while everything around it
            // (via the page's own insertion transition) faded normally.
            .transition(.opacity)
            .compositingGroup()
            .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
            .stableHover { isPosterHovered = $0 }
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
                genrePills
            } else if isLoading {
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(SumiTheme.foregroundWash)
                            .frame(width: 54, height: 20)
                    }
                }
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
                    relationCard(prequel, label: "PREVIOUS SEASON", leading: true)
                }
                if let sequel = details.sequel {
                    relationCard(sequel, label: "NEXT SEASON", leading: false)
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
                            Text("MORE FROM \(studio.name.uppercased())")
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

    /// The one line of state above the title. Everything is muted mono except
    /// the three things worth colouring: the format, the airing status, and
    /// the counts.
    private var metaLine: some View {
        HStack(spacing: 12) {
            if let format = details.format {
                Text(format)
                    .foregroundColor(SumiTheme.foreground)
                    .fontWeight(.semibold)
            } else if isLoading {
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 44, height: 12)
                RoundedRectangle(cornerRadius: 3)
                    .fill(SumiTheme.foregroundWash)
                    .frame(width: 52, height: 12)
            }

            switch details.status {
            case "RELEASING":
                Text("AIRING")
                    .foregroundColor(SumiTheme.indigo)
                    .fontWeight(.semibold)
            case "FINISHED":
                Text("FINISHED")
                    .foregroundColor(Color(hex: "#34D399"))
                    .fontWeight(.semibold)
            default:
                EmptyView()
            }

            if let count = details.episodeCount, count > 0 {
                let unit = (episodes.isEmpty && !mangaChapters.isEmpty) ? "CH" : "EP"
                Text("\(count) \(unit)")
                    .foregroundColor(SumiTheme.indigo)
                    .fontWeight(.semibold)
            }

            if let year = details.year {
                Text(String(year))
                    .foregroundColor(SumiTheme.muted)
            }

            studioLine

            if let score = details.averageScore, score > 0 {
                Text("SCORE \(score)%")
                    .foregroundColor(SumiTheme.indigo)
                    .fontWeight(.semibold)
            }

            if hasTrailer {
                trailerPill
            }

            Spacer(minLength: 0)
        }
        .sumiTabularMono(size: 10.5)
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

    private var trailerPill: some View {
        Button {
            if isTrailerOpen {
                closeTrailer()
            } else {
                openTrailer(fromHover: false)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isTrailerOpen ? "xmark" : "play.rectangle.fill")
                    .font(.system(size: 9))
                Text("TRAILER")
            }
            .sumiTabularMono(size: 10)
            .foregroundColor(isTrailerOpen ? SumiTheme.background : SumiTheme.indigo)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(isTrailerOpen ? SumiTheme.indigo : SumiTheme.indigo.opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(SumiTheme.indigo.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.sumiPressable)
        .animation(.sumi(.pop), value: isTrailerOpen)
    }

    private var genrePills: some View {
        HStack(spacing: 6) {
            ForEach(details.genres.prefix(6), id: \.self) { genre in
                Text(genre)
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(SumiTheme.foreground.opacity(0.05))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if !episodes.isEmpty {
                Button {
                    if let episode = resumeTarget { startingPlayback { onPlayEpisode(episode) } }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill").font(.system(size: 13))
                        Text(primaryActionLabel)
                    }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(SumiTheme.background)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
                    .shadow(color: SumiTheme.indigo.opacity(0.10), radius: 10, y: 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .disabled(resumeTarget == nil)
                .opacity(resumeTarget == nil ? 0.5 : 1)

                // Only offered when the primary button actually says
                // "Resume": next to "Play Episode 1" there is nothing to
                // start over from and the control would be noise.
                if let episode = resumeTarget, resumeSecondsForTarget != nil {
                    Button {
                        startingPlayback { onPlayEpisodeFromStart(episode) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gobackward").font(.system(size: 12))
                            Text("Start over")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }
            } else if let target = resumeChapter {
                Button {
                    onReadChapter(target)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "book.fill").font(.system(size: 13))
                        // "Continue", not "Resume": a chapter has no saved
                        // page offset to come back to, and the Up Next shelf
                        // already draws the same distinction by unit.
                        Text(isContinuingChapters
                             ? "Continue Chapter \(target.number)"
                             : "Read Chapter \(target.number)")
                    }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(SumiTheme.background)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
                    .shadow(color: SumiTheme.indigo.opacity(0.10), radius: 10, y: 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)

                // Same rule as the episode branch above: offered only when
                // the primary button points somewhere other than chapter 1,
                // where "start over" would be the button next to itself.
                if isContinuingChapters, let first = mangaChapters.first {
                    Button {
                        onReadChapter(first)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "gobackward").font(.system(size: 12))
                            Text("Start over")
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }
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
                    Text(cinemaListStatus.map { Self.statusLabel($0) } ?? "Add to List")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 16)
                        .frame(height: 40)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                        .sumiMenuPressable()
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .animation(.snappy, value: cinemaListStatus)
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
                // No manual chevron here: `.menuStyle(.borderlessButton)` below
                // already draws its own disclosure caret, so this used to show
                // two arrows stacked next to each other.
                Text(Self.statusLabel(details.listStatus, manga: isMangaMedia))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .sumiMenuPressable()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .animation(.snappy, value: details.listStatus)

            Button(action: onToggleFavourite) {
                Image(systemName: details.isFavourite ? "heart.fill" : "heart")
                    .font(.system(size: 15))
                    .foregroundColor(details.isFavourite ? Color(hex: "#EC4899") : SumiTheme.foreground.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(details.isFavourite ? Color(hex: "#EC4899").opacity(0.15) : SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(details.isFavourite ? Color(hex: "#EC4899").opacity(0.3) : SumiTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .animation(.bouncy, value: details.isFavourite)
            }

            Menu {
                Button(role: .destructive, action: onRemoveFromList) {
                    Label("Remove from AniList", systemImage: "trash")
                }
                .disabled(details.listEntryId == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15))
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                    .sumiMenuPressable()
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Spacer(minLength: 0)
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
    /// else the first unwatched, else the first.
    private var resumeTarget: EpisodeItem? {
        if let number = details.resumeEpisode,
           let match = episodes.first(where: { $0.number == number }) {
            return match
        }
        return episodes.first(where: { !$0.isWatched }) ?? episodes.first
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
    private var seasons: [CinemaSeason] { cinemaExtras?.seasons ?? [] }

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

    private var episodesForSelectedSeason: [EpisodeItem] {
        guard seasons.count > 1 else { return episodes }
        let wanted = selectedSeason ?? defaultSeason
        let season = seasons.first { $0.number == wanted } ?? seasons[0]
        let span = range(ofSeason: season)
        return episodes.filter { span.contains($0.number) }
    }

    /// Which season the list is showing. Defaults to the one the resume
    /// position is in, so a show resumed at season 3 opens on season 3
    /// rather than on a first season finished months ago.
    private var defaultSeason: Int32 {
        guard let resume = details.resumeEpisode else { return seasons.first?.number ?? 1 }
        for season in seasons where range(ofSeason: season).contains(resume) {
            return season.number
        }
        return seasons.first?.number ?? 1
    }

    private var seasonPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(seasons, id: \.number) { season in
                    let isSelected = (selectedSeason ?? defaultSeason) == season.number
                    Button {
                        withAnimation(.snappy(duration: 0.25)) { selectedSeason = season.number }
                    } label: {
                        Text("S\(season.number)")
                            .sumiTabularMono(size: 11.5, weight: isSelected ? .bold : .regular)
                            .foregroundColor(isSelected ? SumiTheme.background : SumiTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(isSelected ? SumiTheme.foreground : SumiTheme.card)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(isSelected ? Color.clear : SumiTheme.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
            .padding(.vertical, 2)
        }
    }

    /// A film: one sitting, numbered 1 only because the registry, the resume
    /// position and the remembered release all key on an episode number.
    /// Nothing on the page should say "Episode 1" about it.
    private var isSingleSitting: Bool {
        details.format?.uppercased() == "MOVIE" && episodes.count <= 1
    }

    private var primaryActionLabel: String {
        guard let target = resumeTarget else { return "Nothing to play" }
        if let seconds = resumeSecondsForTarget {
            return isSingleSitting
                ? "Resume · \(Self.clock(seconds))"
                : "Resume Episode \(target.number) · \(Self.clock(seconds))"
        }
        if isSingleSitting {
            return target.isWatched ? "Watch again" : "Play"
        }
        return target.isWatched ? "Rewatch Episode \(target.number)" : "Play Episode \(target.number)"
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
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.snappy) { isSynopsisExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(isSynopsisExpanded ? "Show Less" : "Read Full Synopsis")
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

    fileprivate struct RelationCardView: View {
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
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            if let format = relation.format {
                                Text(format)
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
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            if let format = relation.format {
                                Text(format)
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
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: 290)
                .background(isHovered ? SumiTheme.card : SumiTheme.foreground.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(isHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border, lineWidth: 1)
                )
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
        if cinemaExtras != nil { tabs.append(.details) }
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
            if episodes.isEmpty { return "EPISODES" }
            return isSingleSitting ? "FILM" : "EPISODES (\(episodes.count))"
        case .manga: return mangaChapters.isEmpty ? "CHAPTERS" : "CHAPTERS (\(mangaChapters.count))"
        case .characters: return characters.isEmpty ? "CAST & STAFF" : "CAST & STAFF (\(characters.count))"
        case .related:
            let count = relations.isEmpty ? ((details.prequel != nil ? 1 : 0) + (details.sequel != nil ? 1 : 0)) : relations.count
            return count > 0 ? "RELATED (\(count))" : "RELATED"
        case .discussions: return discussions.isEmpty ? "DISCUSSIONS" : "DISCUSSIONS (\(discussions.count))"
        case .details: return "DETAILS"
        case .more: return recommendations.isEmpty ? "MORE" : "MORE (\(recommendations.count))"
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
                                let current = availableTabs.firstIndex(of: activeTab) ?? 0
                                let target = availableTabs.firstIndex(of: tab) ?? 0
                                withAnimation(.snappy) {
                                    // Written in the same transaction as the
                                    // tab itself: the incoming view is built
                                    // during this update and captures the
                                    // direction then, so a separate write can
                                    // land late and slide the wrong way.
                                    tabSlide = target >= current ? 1 : -1
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
                                    if isSelected {
                                        Rectangle()
                                            .fill(SumiTheme.indigo)
                                            .frame(height: 2)
                                            .matchedGeometryEffect(id: "detailTabUnderline", in: detailTabNamespace)
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

            Spacer(minLength: 12)

            // Right side: Audio and ViewMode toggles. Only the episodes tab
            // can use them, but they stay in the layout on every tab. This
            // row is `.bottom` aligned and, measured, the controls are 30pt
            // against the tab strip's 25 — dropping them took the bar from
            // 30pt to 25 and lifted the labels and the whole page under them
            // on every switch away from Episodes.
            if !episodes.isEmpty {
                let showsEpisodeControls = activeTab == .episodes
                HStack(spacing: 10) {
                    // Audio toggle
                    if tracksOnAniList {
                    HStack(spacing: 6) {
                        Text("AUDIO:")
                            .sumiTabularMono(size: 10.5, weight: .bold)
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)

                        HStack(spacing: 2) {
                            ForEach(AudioType.allCases, id: \.self) { audio in
                                let isSelected = selectedAudioType == audio
                                Button {
                                    if selectedAudioType != audio {
                                        SumiHaptics.selection()
                                        withAnimation(.snappy) {
                                            storedSubDub = audio.storedValue
                                        }
                                    }
                                } label: {
                                    Text(audio.rawValue)
                                        .sumiTabularMono(size: 10.5, weight: isSelected ? .bold : .regular)
                                        .foregroundColor(isSelected ? SumiTheme.indigo : SumiTheme.muted)
                                        .lineLimit(1)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background {
                                            if isSelected {
                                                RoundedRectangle(cornerRadius: 4)
                                                    .fill(SumiTheme.indigo.opacity(0.18))
                                                    .matchedGeometryEffect(id: "audioPill", in: audioNamespace)
                                            }
                                        }
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.sumiPressable)
                            }
                        }
                        .animation(.snappy, value: selectedAudioType)
                        .padding(2)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                    // View Mode toggle: Cards | Compact
                    HStack(spacing: 2) {
                        ForEach(EpisodeViewMode.allCases, id: \.self) { mode in
                            let isSelected = selectedViewMode == mode
                            Button {
                                if selectedViewMode != mode {
                                    SumiHaptics.selection()
                                    withAnimation(.snappy) {
                                        selectedViewMode = mode
                                    }
                                }
                            } label: {
                                Text(mode.rawValue)
                                    .font(.system(size: 10.5, weight: isSelected ? .bold : .medium))
                                    .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                                    .lineLimit(1)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background {
                                        if isSelected {
                                            RoundedRectangle(cornerRadius: 4)
                                                .fill(SumiTheme.foreground.opacity(0.12))
                                                .matchedGeometryEffect(id: "viewModePill", in: viewModeNamespace)
                                        }
                                    }
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                        }
                    }
                    .animation(.snappy, value: selectedViewMode)
                    .padding(2)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))
                    .fixedSize(horizontal: true, vertical: false)
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

    /// Content arrives from the side it is coming from: from the right for a
    /// tab further along the bar, from the left for one behind it.
    ///
    /// Only the arriving side slides. A view's removal transition is recorded
    /// when that view was last built — that is, during the *previous* switch,
    /// carrying the `tabSlide` from then — so a departing panel given a
    /// direction leaves the way the last change went, and reversing direction
    /// sent both panels the same way at once.
    private var tabTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 12 * tabSlide)),
            removal: .opacity
        )
    }

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
                    isLoading: isLoading,
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
            CharactersTabSection(characters: characters, onSelectCharacter: onSelectCharacter)
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

    fileprivate struct ChapterRowView: View {
        let chapter: MediaDetailView.MangaChapterItem
        var offline: ChapterOfflineState = .none
        var onDownload: (() -> Void)?
        var onDeleteDownload: (() -> Void)?
        let onRead: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onRead) {
                HStack(spacing: 12) {
                    Text("CH \(chapter.number)")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.indigo)
                    Text(chapter.title)
                        .font(.sumiHeading(size: 13.5, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Spacer()
                    offlineControl
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(isHovered ? SumiTheme.card : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(isHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border, lineWidth: 1)
                )
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

    fileprivate struct RelatedMediaCard: View {
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
                        Text(relation.relationType.replacingOccurrences(of: "_", with: " "))
                            .sumiTabularMono(size: 9.5)
                            .foregroundColor(SumiTheme.indigo)

                        Text(relation.title)
                            .font(.sumiHeading(size: 13, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if let format = relation.format {
                                Text(format)
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
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundColor(SumiTheme.muted.opacity(0.6))
                }
                .padding(10)
                .background(isHovered ? SumiTheme.card : SumiTheme.foreground.opacity(0.02))
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(isHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }
    }

    fileprivate struct DiscussionRowView: View {
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
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.indigo)
                    Text("\(thread.replyCount)")
                        .sumiTabularMono(size: 11, weight: .bold)
                        .foregroundColor(SumiTheme.foreground)
                }
                .frame(width: 52, alignment: .leading)

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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isHovered ? SumiTheme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(isHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border.opacity(0.3), lineWidth: 1)
            )
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }
    }

    fileprivate struct RecommendationCardView: View {
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
                        .overlay(
                            ZStack(alignment: .topTrailing) {
                                RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1)
                                if let rating = rec.rating, rating > 0 {
                                    Text("\(rating)%")
                                        .font(.system(size: 9, weight: .bold))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(SumiTheme.indigo)
                                        .foregroundColor(.black)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .padding(5)
                                }
                            }
                        )

                    Text(rec.title)
                        .font(.sumiHeading(size: 11.5, weight: .bold))
                        .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let format = rec.format {
                        Text(format)
                            .sumiTabularMono(size: 9.5)
                            .foregroundColor(SumiTheme.muted)
                    }
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

    // Evaluated once per section body, not once per row, so a plain
    // computed property is enough. It was a `@State` cache that nothing
    // ever assigned, so no row was ever the resume target.
    private var resumeTarget: MediaDetailView.EpisodeItem? {
        if let resumeEpisode, let match = episodes.first(where: { $0.number == resumeEpisode }) {
            return match
        }
        return episodes.first(where: { !$0.isWatched }) ?? episodes.first
    }

    private func morphSource(for episode: MediaDetailView.EpisodeItem) -> EpisodeMorphSource? {
        guard let playerNamespace,
              let playerSourceKey,
              playerSourceKey == MediaDetailView.playerMorphKey(catalogId: catalogId, episode: episode.number)
        else { return nil }
        return EpisodeMorphSource(key: playerSourceKey, namespace: playerNamespace)
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
            } else if selectedViewMode == .compact {
                LazyVStack(spacing: 4) {
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
            } else {
                LazyVStack(spacing: 8) {
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
            }
        }
        .animation(.smooth, value: selectedViewMode)
    }
}

/// The `.manga` tab. Split out of `tabContent` alongside the other tabs
/// below so switching tabs, or any one tab's own state changing, only
/// re-evaluates that tab's struct instead of the whole detail page body.
private struct MangaTabSection: View {
    /// Volumes of a light novel, or an honest word about why there are none.
    ///
    /// This tab used to say reading "isn't available yet" for every novel,
    /// because nothing resolved a catalogue entry to a source at all. Most
    /// AniList light novels still have no indexed English translation, so a
    /// miss stays a first-class outcome rather than an error.
    @ViewBuilder
    var novelVolumeList: some View {
        if isLoadingNovelVolumes {
            EpisodeListSkeleton(count: 4, isCompact: true)
        } else if !novelVolumes.isEmpty {
            LazyVStack(spacing: 8) {
                ForEach(novelVolumes, id: \.url) { volume in
                    volumeRow(volume)
                }
            }
        } else if novelSourceMissing {
            SumiEmptyState(
                headline: "No readable copy found",
                detail: "No English translation of this novel is indexed. Titles that are translated open here; the rest can still be read by pasting a Syosetu link into the Light Novels page."
            )
        } else {
            SumiEmptyState(
                headline: "No chapters found",
                detail: "Nothing readable was found for this title."
            )
        }
    }

    @ViewBuilder
    private func volumeRow(_ volume: NovelChapterRef) -> some View {
        let state = novelVolumeStates[volume.url] ?? .none
        HStack(spacing: 12) {
            Button { onReadVolume?(volume) } label: {
                HStack(spacing: 12) {
                    Image(systemName: state == .stored ? "book.closed.fill" : "book.closed")
                        .font(.system(size: 13))
                        .foregroundColor(state == .stored ? SumiTheme.indigo : SumiTheme.muted)
                        .frame(width: 20)
                    Text(volume.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)

            volumeAction(
                systemImage: state == .stored ? "checkmark.circle.fill" : "arrow.down.circle",
                help: state == .stored ? "Downloaded. Click to remove." : "Keep this volume for reading offline",
                busy: state == .downloading,
                tint: state == .stored ? SumiTheme.indigo : SumiTheme.muted
            ) {
                if state == .stored {
                    onDeleteVolumeDownload?(volume)
                } else {
                    onDownloadVolume?(volume)
                }
            }

            // Export is offered whether or not the volume is downloaded: it
            // downloads first when it has to, so sending a book to a reader is
            // one action rather than two in an order the user has to know.
            volumeAction(
                systemImage: "square.and.arrow.up",
                help: "Save as an EPUB for an e-reader",
                busy: state == .exporting,
                tint: SumiTheme.muted
            ) {
                onExportVolume?(volume)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func volumeAction(
        systemImage: String,
        help: String,
        busy: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Group {
                if busy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                        .font(.system(size: 13))
                        .foregroundColor(tint)
                }
            }
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .disabled(busy)
        .help(help)
    }

    let chapters: [MediaDetailView.MangaChapterItem]
    let format: String?
    var isLoading: Bool = false
    var novelVolumes: [NovelChapterRef] = []
    var isLoadingNovelVolumes: Bool = false
    var novelSourceMissing: Bool = false
    var onReadVolume: ((NovelChapterRef) -> Void)?
    var novelVolumeStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    var onDownloadVolume: ((NovelChapterRef) -> Void)?
    var onDeleteVolumeDownload: ((NovelChapterRef) -> Void)?
    var onExportVolume: ((NovelChapterRef) -> Void)?
    /// Which chapters are on disk, or on their way there. Keyed by chapter
    /// id because that is what the registry and the files are keyed on.
    var offlineStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    var onDownloadChapter: ((MediaDetailView.MangaChapterItem) -> Void)?
    var onDeleteChapterDownload: ((MediaDetailView.MangaChapterItem) -> Void)?
    let onReadChapter: (MediaDetailView.MangaChapterItem) -> Void

    var body: some View {
        if chapters.isEmpty {
            if isLoading {
                EpisodeListSkeleton(count: 6, isCompact: true)
            } else if format == "NOVEL" {
                novelVolumeList
            } else {
                SumiEmptyState(headline: "No chapters found", detail: "No chapters were found for this title.")
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(chapters) { chapter in
                    MediaDetailView.ChapterRowView(
                        chapter: chapter,
                        offline: offlineStates[chapter.id] ?? .none,
                        onDownload: onDownloadChapter.map { action in { action(chapter) } },
                        onDeleteDownload: onDeleteChapterDownload.map { action in { action(chapter) } }
                    ) {
                        onReadChapter(chapter)
                    }
                }
            }
        }
    }
}

private struct CharactersTabSection: View {
    let characters: [MediaDetailView.CharacterItem]
    let onSelectCharacter: (Int64) -> Void

    var body: some View {
        if characters.isEmpty {
            SumiEmptyState(headline: "Cast & Staff", detail: "Loading cast & staff details for this title...")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], spacing: 14) {
                ForEach(characters) { char in
                    Button {
                        onSelectCharacter(char.id)
                    } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Color.clear
                            .aspectRatio(2/3, contentMode: .fit)
                            .overlay {
                                CachedAsyncImage(url: char.imageURL, maxPixelSize: 320) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Rectangle().fill(SumiTheme.card)
                                }
                            }
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                ZStack(alignment: .topLeading) {
                                    RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1)
                                    Text(char.role.replacingOccurrences(of: "_", with: " ").capitalized)
                                        .font(.system(size: 8.5, weight: .black))
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 2)
                                        .background(Color.black.opacity(0.75))
                                        .foregroundColor(.white.opacity(0.9))
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .padding(5)
                                }
                            )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(char.name)
                                .font(.sumiHeading(size: 12, weight: .bold))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            if let va = char.voiceActorName, !va.isEmpty {
                                Text(va)
                                    .font(.system(size: 10))
                                    .foregroundColor(SumiTheme.muted)
                                    .lineLimit(1)
                            }
                        }
                    }
                    }
                    .buttonStyle(.sumiPressable)
                    .contentShape(Rectangle())
                }
            }
        }
    }
}

private struct RelatedTabSection: View {
    let details: HeroBanner.Details
    let relations: [MediaDetailView.RelationItem]
    let prequel: HeroBanner.Details.Relation?
    let sequel: HeroBanner.Details.Relation?
    let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    @State private var mode = "grid"

    private static let mainTypes: Set<String> = ["PREQUEL", "SEQUEL", "ADAPTATION", "PARENT", "SOURCE"]

    var body: some View {
        if relations.isEmpty && prequel == nil && sequel == nil {
            SumiEmptyState(headline: "No Related Titles", detail: "No prequel, sequel, manga, light novel, or related adaptations recorded.")
        } else {
            VStack(alignment: .leading, spacing: 20) {
                SumiSegmentedControl(
                    options: [("grid", "Grid"), ("timeline", "Timeline")],
                    selection: $mode
                )
                .fixedSize()

                if mode == "timeline" {
                    WatchOrderTimeline(
                        details: details,
                        relations: relations,
                        onSelectMediaId: onSelectMediaId
                    )
                } else {
                    grid
                }
            }
        }
    }

    private var grid: some View {
        Group {
            VStack(alignment: .leading, spacing: 20) {
                let mainRels = relations.filter { Self.mainTypes.contains($0.relationType) }
                let otherRels = relations.filter { !Self.mainTypes.contains($0.relationType) }

                if !mainRels.isEmpty || prequel != nil || sequel != nil {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SEASONS & ADAPTATIONS")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.indigo)

                        if !mainRels.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)], spacing: 12) {
                                ForEach(mainRels) { rel in
                                    MediaDetailView.RelatedMediaCard(relation: rel) {
                                        let isManga = rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                        onSelectMediaId?(rel.id, rel.title, rel.coverURL, isManga)
                                    }
                                }
                            }
                        } else if prequel != nil || sequel != nil {
                            HStack(spacing: 12) {
                                if let prequel {
                                    MediaDetailView.RelationCardView(relation: prequel, label: "PREVIOUS SEASON", leading: true, onSelect: onSelectRelation)
                                }
                                if let sequel {
                                    MediaDetailView.RelationCardView(relation: sequel, label: "NEXT SEASON", leading: false, onSelect: onSelectRelation)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if !otherRels.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("OTHER RELATIONS")
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)

                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)], spacing: 12) {
                            ForEach(otherRels) { rel in
                                MediaDetailView.RelatedMediaCard(relation: rel) {
                                    let isManga = rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                    onSelectMediaId?(rel.id, rel.title, rel.coverURL, isManga)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/// The Related tab's Timeline: the title and everything around it in the
/// order someone would watch them, grouped by year.
///
/// `FfiRelation` carries no start date, episode count or list entry, so the
/// years and the badges come from whatever detail snapshots are already on
/// disk (see `DetailCache.peekFacts`). A relation the viewer has never
/// opened simply has none, which is why the ordering leans on the relation
/// type and not on dates — see `WatchOrder`.
private struct WatchOrderTimeline: View {
    let details: HeroBanner.Details
    let relations: [MediaDetailView.RelationItem]
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    @State private var groups: [WatchOrder.YearGroup] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 8) {
                    Text(group.label)
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.indigo)

                    VStack(spacing: 6) {
                        ForEach(group.entries) { entry in
                            WatchOrderRow(entry: entry) {
                                guard !entry.isCurrent else { return }
                                onSelectMediaId?(
                                    entry.id,
                                    entry.title,
                                    entry.coverURL,
                                    AppModel.isMangaFormat(entry.format)
                                )
                            }
                        }
                    }
                }
            }
        }
        // Reading a snapshot per relation is file I/O, so it stays off the
        // body and out of the main actor's way; the timeline draws empty
        // for the frame it takes.
        //
        // Keyed on the relation count as well as the title: the page
        // renders from a cached snapshot first and the fresh fetch fills
        // `relations` afterwards. On the id alone the Grid picked those up
        // (it reads the array in its own body) and the timeline kept
        // showing the current title by itself.
        .task(id: "\(details.id)-\(relations.count)") {
            let entries = await Self.entries(details: details, relations: relations)
            groups = WatchOrder.grouped(entries)
        }
    }

    private static func entries(
        details: HeroBanner.Details,
        relations: [MediaDetailView.RelationItem]
    ) async -> [WatchOrder.Entry] {
        await Task.detached(priority: .userInitiated) {
            let current = WatchOrder.Entry(
                id: details.id,
                title: details.title,
                relationType: nil,
                format: details.format,
                coverURL: details.coverURL,
                year: details.year,
                episodeCount: details.episodeCount,
                listStatus: details.listStatus,
                isCurrent: true
            )
            let mapped = relations.map { relation -> WatchOrder.Entry in
                let isManga = AppModel.isMangaFormat(relation.format)
                // A title can be cached under either kind — the detail
                // loader falls back to the opposite one when AniList
                // disagrees with the format — so a miss is retried the
                // other way round before giving up.
                let facts = DetailCache.peekFacts(id: relation.id, isManga: isManga)
                    ?? DetailCache.peekFacts(id: relation.id, isManga: !isManga)
                return WatchOrder.Entry(
                    id: relation.id,
                    title: relation.title,
                    relationType: relation.relationType,
                    format: relation.format,
                    coverURL: relation.coverURL,
                    year: facts?.year,
                    episodeCount: facts?.episodeCount,
                    listStatus: facts?.listStatus
                )
            }
            return WatchOrder.sort(relations: mapped, current: current)
        }.value
    }
}

/// One title on the timeline. The viewed title keeps its left rail so the
/// eye finds "you are here" without reading a single row label.
private struct WatchOrderRow: View {
    let entry: WatchOrder.Entry
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Rectangle()
                    .fill(entry.isCurrent ? SumiTheme.indigo : Color.clear)
                    .frame(width: 2)

                Color.clear
                    .frame(width: 34, height: 48)
                    .overlay {
                        CachedAsyncImage(url: entry.coverURL, maxPixelSize: 120) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: entry.isCurrent ? .bold : .semibold))
                        .foregroundColor(isHovered && !entry.isCurrent ? SumiTheme.indigo : SumiTheme.foreground)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(badgeLabel)
                            .sumiTabularMono(size: 9.5)
                            .foregroundColor(entry.isCurrent ? SumiTheme.indigo : SumiTheme.muted)
                        if let format = entry.format {
                            Text(format)
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                        }
                        if let count = entry.episodeCount, count > 0 {
                            Text("\(count) EP")
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                        }
                        if let status = entry.listStatus {
                            Text(status.replacingOccurrences(of: "_", with: " "))
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.indigo.opacity(0.8))
                        }
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(.trailing, 10)
            .padding(.vertical, 6)
            .background(isHovered && !entry.isCurrent ? SumiTheme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .disabled(entry.isCurrent)
        .stableHover { isHovered = $0 }
        .animation(.sumi(.pop), value: isHovered)
    }

    private var badgeLabel: String {
        if entry.isCurrent { return "YOU ARE HERE" }
        guard let type = entry.relationType else { return "RELATED" }
        return type.replacingOccurrences(of: "_", with: " ")
    }
}

private struct DiscussionsTabSection: View {
    let discussions: [MediaDetailView.DiscussionItem]
    let onSelectThread: (Int64) -> Void

    var body: some View {
        if discussions.isEmpty {
            SumiEmptyState(headline: "Discussions", detail: "No community discussion threads found for this title.")
        } else {
            VStack(spacing: 8) {
                ForEach(discussions) { thread in
                    MediaDetailView.DiscussionRowView(thread: thread) {
                        onSelectThread(thread.id)
                    }
                }
            }
        }
    }
}

private struct RecommendationsTabSection: View {
    let recommendations: [MediaDetailView.RecommendationItem]
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    var body: some View {
        if recommendations.isEmpty {
            SumiEmptyState(headline: "No Additional Content", detail: "No community recommendations found.")
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("RECOMMENDATIONS")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.indigo)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 165), spacing: 14)], spacing: 14) {
                    ForEach(recommendations) { rec in
                        MediaDetailView.RecommendationCardView(rec: rec) {
                            let isManga = rec.format == "MANGA" || rec.format == "NOVEL" || rec.format == "ONE_SHOT"
                            onSelectMediaId?(rec.id, rec.title, rec.coverURL, isManga)
                        }
                    }
                }
            }
        }
    }
}

private struct CompactEpisodeRow: View, Equatable {
    let episode: MediaDetailView.EpisodeItem
    let isResumeTarget: Bool
    let resumeSeconds: Int?
    let onPlay: () -> Void
    let onToggleWatched: (Bool) -> Void

    @State private var isHovered = false

    // See EpisodeRow.== — closures excluded deliberately, not an oversight.
    nonisolated static func == (lhs: CompactEpisodeRow, rhs: CompactEpisodeRow) -> Bool {
        lhs.episode == rhs.episode
            && lhs.isResumeTarget == rhs.isResumeTarget
            && lhs.resumeSeconds == rhs.resumeSeconds
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    // Episode Number Badge
                    Text("\(episode.number)")
                        .sumiTabularMono(size: 11, weight: .bold)
                        .foregroundColor(isResumeTarget ? SumiTheme.background : (episode.isWatched ? SumiTheme.muted.opacity(0.6) : SumiTheme.muted))
                        .frame(width: 28, height: 28)
                        .background(isResumeTarget ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    // Title
                    Text(episode.title)
                        .font(.sumiHeading(size: 13, weight: isResumeTarget ? .bold : .medium))
                        .foregroundColor(episode.isWatched ? SumiTheme.muted.opacity(0.6) : SumiTheme.foreground)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    // Resume pill or runtime
                    if isResumeTarget, let seconds = resumeSeconds, seconds > 0 {
                        Text("Resume \(MediaDetailView.clock(seconds))")
                            .sumiTabularMono(size: 10, weight: .medium)
                            .foregroundColor(SumiTheme.indigo)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(SumiTheme.indigo.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? SumiTheme.card : (isResumeTarget ? SumiTheme.indigo.opacity(0.08) : Color.clear))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(isResumeTarget ? SumiTheme.indigo.opacity(0.4) : (isHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border.opacity(0.3)), lineWidth: 1)
        )
        .stableHover { isHovered = $0 }
        .animation(.snappy, value: isHovered)
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
            .help("Stream Servers")
            .padding(.top, 3)
            .popover(isPresented: Binding(
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

            Button(action: { onToggleWatched(!episode.isWatched) }) {
                WatchedTick(isWatched: episode.isWatched, diameter: 18)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help(episode.isWatched ? "Mark unwatched" : "Mark watched")
            .padding(.top, 2)
        }
        .padding(12)
        .background(
            isResumeTarget
                ? SumiTheme.indigo.opacity(0.10)
                : (isHovered ? SumiTheme.card : SumiTheme.foreground.opacity(0.02))
        )
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(
                    isResumeTarget
                        ? SumiTheme.indigo.opacity(0.40)
                        : (isHovered ? SumiTheme.border.opacity(0.8) : SumiTheme.border),
                    lineWidth: 1
                )
        )
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
            Text("EP \(episode.number)")
                .foregroundColor(SumiTheme.indigo)
                .fontWeight(.semibold)
            if let airDate = episode.airDate {
                Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))
                Text(Self.formatAirDate(airDate)).foregroundColor(SumiTheme.muted)
            }
            if let seconds = resumeSeconds, seconds > 0 {
                Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))
                Text("Resume \(MediaDetailView.clock(seconds))")
                    .foregroundColor(SumiTheme.indigo)
                    .fontWeight(.medium)
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

            if episode.isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(SumiTheme.background)
                    .frame(width: 16, height: 16)
                    .background(SumiTheme.indigo)
                    .clipShape(Circle())
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if let minutes = episode.runtimeMinutes, minutes > 0 {
                Text("\(minutes)m")
                    .sumiTabularMono(size: 9)
                    .foregroundColor(Color(hex: "#CCCCCC"))
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

/// "Stream Servers" popover content: every release the indexers found for
/// this episode, best (highest seeders) first, so a stalled auto-pick can be
/// swapped for a healthier one without leaving the episode list.
private struct ServerPickerView: View {
    let isLoading: Bool
    let candidates: [MediaDetailView.ReleaseCandidateItem]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("STREAM SERVERS")
                .sumiTabularMono(size: 10.5, weight: .semibold)
                .foregroundColor(SumiTheme.muted)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            Divider()

            if isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching indexers…")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                }
                .padding(14)
            } else if candidates.isEmpty {
                Text("No releases found.")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                    .padding(14)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(candidates) { candidate in
                            Button {
                                onSelect(candidate.name)
                            } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        // Real release names routinely run
                                        // 80-100+ characters (group tag,
                                        // full title, resolution, codec,
                                        // audio track) — a 2-line cap at
                                        // 11pt in a 340pt-wide popover
                                        // truncated most of them into
                                        // unreadable mush. Uncapped at a
                                        // wider column reads as an actual
                                        // release name again.
                                        Text(candidate.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundColor(SumiTheme.foreground)
                                            // Uncapped, this let one very
                                            // long release name (fansub
                                            // group + full title + codec
                                            // tags) wrap 3-4 lines and eat
                                            // most of the popover's height
                                            // by itself, so only one row
                                            // fit on screen at a time. The
                                            // wider 460pt column already
                                            // fixed the "unreadably tiny"
                                            // complaint; 2 lines is enough
                                            // to actually read a name at
                                            // that width.
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 6) {
                                            if candidate.isDub {
                                                Text("DUB")
                                                    .sumiTabularMono(size: 10, weight: .bold)
                                                    .foregroundColor(SumiTheme.indigo)
                                            }
                                            Text("\(candidate.seeders) seeders")
                                                .sumiTabularMono(size: 10.5)
                                                .foregroundColor(SumiTheme.muted)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10))
                                        .foregroundColor(SumiTheme.muted.opacity(0.5))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)

                            if candidate.id != candidates.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                // A row is about 62pt (a name on up to two 12pt lines, the
                // seeders line, 9pt of padding either side, a divider), and
                // `list_candidates` does not truncate — a popular episode
                // comes back with dozens. At 380 that was six rows on
                // screen, so picking a healthier release meant scrolling a
                // list whose shape you could not see; 560 shows nine and
                // still leaves room above and below the anchored row on a
                // laptop display.
                .frame(maxHeight: 560)
            }
        }
        .frame(width: 460)
        .background(SumiTheme.card)
    }
}

// MARK: - Studio navigation

/// What the detail page can ask of the studio catalog: open a studio's own
/// page, and list its works for the "More from" shelf.
///
/// Handed down the environment rather than added to `MediaDetailView.init`,
/// which already takes two dozen parameters and is built at one call site
/// with no other interest in studios. The default is inert, so a preview or
/// a test that renders the page without an app around it draws the studio
/// names as plain buttons and no shelf, rather than failing on a dependency
/// it never asked for.
public struct StudioPageActions: Sendable {
    public var open: @MainActor @Sendable (Int64) -> Void
    public var works: @MainActor @Sendable (Int64) async -> [MediaDetailView.StudioWorkItem]

    public init(
        open: @escaping @MainActor @Sendable (Int64) -> Void = { _ in },
        works: @escaping @MainActor @Sendable (Int64) async -> [MediaDetailView.StudioWorkItem] = { _ in [] }
    ) {
        self.open = open
        self.works = works
    }
}

private struct StudioPageActionsKey: EnvironmentKey {
    static let defaultValue = StudioPageActions()
}

public extension EnvironmentValues {
    var studioPageActions: StudioPageActions {
        get { self[StudioPageActionsKey.self] }
        set { self[StudioPageActionsKey.self] = newValue }
    }
}

/// One studio name in the meta line, sized to sit inside that mono line
/// rather than break it: no capsule and no padding of its own, just the
/// hover colour and underline that say the name is a destination.
private struct StudioButton: View {
    let name: String
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            Text(name)
                .foregroundColor(isHovered ? SumiTheme.indigo : SumiTheme.muted)
                .underline(isHovered, color: SumiTheme.indigo.opacity(0.6))
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .stableHover { isHovered = $0 }
        .animation(.sumi(.pop), value: isHovered)
    }
}
