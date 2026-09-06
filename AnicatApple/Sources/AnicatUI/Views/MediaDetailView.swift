import SwiftUI

public struct MediaDetailView: View {
    public enum DetailTab: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case manga = "Manga"
        case characters = "Cast & Staff"
        case related = "Related"
        case discussions = "Discussions"
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
    public let characters: [CharacterItem]
    public let relations: [RelationItem]
    public let recommendations: [RecommendationItem]
    public let discussions: [DiscussionItem]
    public let isLoading: Bool
    
    public let onPlayEpisode: (EpisodeItem) -> Void
    /// Same episode as `onPlayEpisode`, ignoring the recorded resume
    /// position. Only ever offered next to a "Resume" primary action, so it
    /// is not wired into the episode rows.
    public let onPlayEpisodeFromStart: (EpisodeItem) -> Void
    public let onReadChapter: (MangaChapterItem) -> Void
    public let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    public let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?
    public let onExportAppleBooks: () -> Void
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
    public let downloadStates: [Int: EpisodeDownloadState]
    /// Shared with the `MediaCard` this detail page was opened from, so the
    /// poster grows from that card's actual on-screen frame instead of the
    /// generic offset/opacity swap. `nil` when opened from a context that
    /// isn't wired to a shared namespace (or wasn't opened from a card at
    /// all, e.g. deep-linked).
    public var namespace: Namespace.ID?

    @State private var selectedTab: DetailTab = .episodes
    let onTabChanged: (DetailTab) -> Void
    // Backed by the same defaults key Settings writes and `AppModel` reads
    // when building a `StreamRequest`, rather than view-local state nothing
    // ever looked at — picking Dub here changed nothing about which release
    // was resolved.
    @AppStorage("anicat_sub_dub") private var storedSubDub: String = "Subtitled"
    private var selectedAudioType: AudioType { AudioType(stored: storedSubDub) }
    @State private var selectedViewMode: EpisodeViewMode = .cards
    @State private var isSynopsisExpanded = false
    @State private var isBackHovered = false
    @Namespace private var detailTabNamespace
    @Namespace private var viewModeNamespace
    @Namespace private var audioNamespace

    public init(
        details: HeroBanner.Details,
        episodes: [EpisodeItem] = [],
        mangaChapters: [MangaChapterItem] = [],
        characters: [CharacterItem] = [],
        relations: [RelationItem] = [],
        recommendations: [RecommendationItem] = [],
        discussions: [DiscussionItem] = [],
        isLoading: Bool = false,
        onPlayEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        onPlayEpisodeFromStart: @escaping (EpisodeItem) -> Void = { _ in },
        onReadChapter: @escaping (MangaChapterItem) -> Void = { _ in },
        onSelectRelation: ((HeroBanner.Details.Relation) -> Void)? = nil,
        onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)? = nil,
        onExportAppleBooks: @escaping () -> Void = {},
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
        downloadStates: [Int: EpisodeDownloadState] = [:],
        namespace: Namespace.ID? = nil,
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
        self.characters = characters
        self.relations = relations
        self.recommendations = recommendations
        self.discussions = discussions
        self.isLoading = isLoading
        self.onPlayEpisode = onPlayEpisode
        self.onPlayEpisodeFromStart = onPlayEpisodeFromStart
        self.onReadChapter = onReadChapter
        self.onSelectRelation = onSelectRelation
        self.onSelectMediaId = onSelectMediaId
        self.onExportAppleBooks = onExportAppleBooks
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

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                banner
                content
                tabsSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
                .overlay {
                    CachedAsyncImage(url: details.bannerURL ?? details.coverURL, maxPixelSize: 1200) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(SumiTheme.card)
                    }
                }
                .clipped()

            // `.hero-gradient`: the page ground at the bottom, a 60% black at
            // 40% up, clear at the top.
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
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 16) {
            metaLine
                .padding(.top, 24)

            Text(details.title)
                .font(.system(size: 36, weight: .bold))
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
            tabContent
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

            if let studio = details.studio {
                Text(studio)
                    .foregroundColor(SumiTheme.muted)
            }

            if let score = details.averageScore, score > 0 {
                Text("SCORE \(score)%")
                    .foregroundColor(SumiTheme.indigo)
                    .fontWeight(.semibold)
            }

            Spacer(minLength: 0)
        }
        .sumiTabularMono(size: 10.5)
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
                    if let episode = resumeTarget { onPlayEpisode(episode) }
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
                        onPlayEpisodeFromStart(episode)
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
            } else if let first = mangaChapters.first {
                Button {
                    onReadChapter(first)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "book.fill").font(.system(size: 13))
                        Text("Read Chapter \(first.number)")
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
            }

            Menu {
                ForEach(Self.listStatusOptions, id: \.self) { status in
                    Button(Self.statusLabel(status)) { onSetListStatus(status) }
                }
            } label: {
                // No manual chevron here: `.menuStyle(.borderlessButton)` below
                // already draws its own disclosure caret, so this used to show
                // two arrows stacked next to each other.
                Text(Self.statusLabel(details.listStatus))
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

    private static func statusLabel(_ status: String?) -> String {
        switch status {
        case "CURRENT": return "Watching"
        case "PLANNING": return "Planning"
        case "COMPLETED": return "Completed"
        case "PAUSED": return "Paused"
        case "DROPPED": return "Dropped"
        case "REPEATING": return "Rewatching"
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

    private var primaryActionLabel: String {
        guard let target = resumeTarget else { return "Nothing to play" }
        if let seconds = resumeSecondsForTarget {
            return "Resume Episode \(target.number) · \(Self.clock(seconds))"
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
                                .font(.system(size: 13, weight: .bold))
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
                                .font(.system(size: 13, weight: .bold))
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
        tabs.append(.related)
        tabs.append(.discussions)
        tabs.append(.more)
        return tabs
    }

    private func tabLabel(_ tab: DetailTab) -> String {
        switch tab {
        case .episodes: return episodes.isEmpty ? "EPISODES" : "EPISODES (\(episodes.count))"
        case .manga: return mangaChapters.isEmpty ? "CHAPTERS" : "CHAPTERS (\(mangaChapters.count))"
        case .characters: return characters.isEmpty ? "CAST & STAFF" : "CAST & STAFF (\(characters.count))"
        case .related:
            let count = relations.isEmpty ? ((details.prequel != nil ? 1 : 0) + (details.sequel != nil ? 1 : 0)) : relations.count
            return count > 0 ? "RELATED (\(count))" : "RELATED"
        case .discussions: return discussions.isEmpty ? "DISCUSSIONS" : "DISCUSSIONS (\(discussions.count))"
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
                                withAnimation(.smooth) {
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

            // Right side: Audio and ViewMode toggles when episodes tab is active
            if activeTab == .episodes && !episodes.isEmpty {
                HStack(spacing: 10) {
                    // Audio toggle
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
            }
        }
        .overlay(Rectangle().fill(SumiTheme.border).frame(height: 1), alignment: .bottom)
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
            EpisodeListSection(
                episodes: episodes,
                resumeEpisode: details.resumeEpisode,
                resumeSeconds: details.resumeSeconds,
                selectedViewMode: selectedViewMode,
                downloadStates: downloadStates,
                isLoading: isLoading,
                onPlayEpisode: onPlayEpisode,
                onSetEpisodeWatched: onSetEpisodeWatched,
                onLoadReleaseCandidates: onLoadReleaseCandidates,
                onPlayWithRelease: onPlayWithRelease,
                onDownloadEpisode: onDownloadEpisode
            )
        case .manga:
            MangaTabSection(chapters: mangaChapters, format: details.format, isLoading: isLoading, onReadChapter: onReadChapter)
        case .characters:
            CharactersTabSection(characters: characters, onSelectCharacter: onSelectCharacter)
        case .related:
            RelatedTabSection(
                relations: relations,
                prequel: details.prequel,
                sequel: details.sequel,
                onSelectRelation: onSelectRelation,
                onSelectMediaId: onSelectMediaId
            )
        case .discussions:
            DiscussionsTabSection(discussions: discussions, onSelectThread: onSelectThread)
        case .more:
            RecommendationsTabSection(recommendations: recommendations, onSelectMediaId: onSelectMediaId)
        }
    }

    fileprivate struct ChapterRowView: View {
        let chapter: MediaDetailView.MangaChapterItem
        let onRead: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onRead) {
                HStack(spacing: 12) {
                    Text("CH \(chapter.number)")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.indigo)
                    Text(chapter.title)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Spacer()
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
                            .font(.system(size: 13, weight: .semibold))
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
                        .font(.system(size: 13, weight: .medium))
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
                        .font(.system(size: 11.5, weight: .bold))
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

/// One episode, as a compact row.
/// The `.episodes` tab's list, pulled out of `MediaDetailView.tabContent` so
/// `downloadStates` polling only re-evaluates this struct's own body, not
/// the whole detail page.
private struct EpisodeListSection: View {
    let episodes: [MediaDetailView.EpisodeItem]
    let resumeEpisode: Int?
    let resumeSeconds: Int?
    let selectedViewMode: MediaDetailView.EpisodeViewMode
    let downloadStates: [Int: MediaDetailView.EpisodeDownloadState]
    var isLoading: Bool = false
    let onPlayEpisode: (MediaDetailView.EpisodeItem) -> Void
    let onSetEpisodeWatched: (Int, Bool) -> Void
    let onLoadReleaseCandidates: (Int) async -> [MediaDetailView.ReleaseCandidateItem]
    let onPlayWithRelease: (MediaDetailView.EpisodeItem, String) -> Void
    let onDownloadEpisode: (MediaDetailView.EpisodeItem) -> Void

    @State private var serverPickerEpisode: MediaDetailView.EpisodeItem?
    @State private var isLoadingServers = false
    @State private var serverCandidates: [MediaDetailView.ReleaseCandidateItem] = []

    // Cached resume target — computing `episodes.first(where:)` on every body
    // call (once per EpisodeRow in the lazy list) adds O(n) work per render.
    // Stored in @State and rebuilt only when the inputs actually change.
    @State private var resumeTarget: MediaDetailView.EpisodeItem? = nil

    private func computeResumeTarget() -> MediaDetailView.EpisodeItem? {
        if let resumeEpisode, let match = episodes.first(where: { $0.number == resumeEpisode }) {
            return match
        }
        return episodes.first(where: { !$0.isWatched }) ?? episodes.first
    }

    var body: some View {
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
                            isLoadingServers: isLoadingServers,
                            serverCandidates: serverCandidates,
                            onCloseServerPicker: { serverPickerEpisode = nil },
                            onSelectServer: { name in
                                serverPickerEpisode = nil
                                onPlayWithRelease(episode, name)
                            }
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
    let chapters: [MediaDetailView.MangaChapterItem]
    let format: String?
    var isLoading: Bool = false
    let onReadChapter: (MediaDetailView.MangaChapterItem) -> Void

    var body: some View {
        if chapters.isEmpty {
            if isLoading {
                EpisodeListSkeleton(count: 6, isCompact: true)
            } else if format == "NOVEL" {
                SumiEmptyState(
                    headline: "Light novel reading isn't available yet",
                    detail: "There's no light-novel reader in the native app yet — this section is a placeholder, not a failed search."
                )
            } else {
                SumiEmptyState(headline: "No chapters found", detail: "No chapters were found for this title.")
            }
        } else {
            LazyVStack(spacing: 8) {
                ForEach(chapters) { chapter in
                    MediaDetailView.ChapterRowView(chapter: chapter) {
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
                                .font(.system(size: 12, weight: .bold))
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
    let relations: [MediaDetailView.RelationItem]
    let prequel: HeroBanner.Details.Relation?
    let sequel: HeroBanner.Details.Relation?
    let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?

    private static let mainTypes: Set<String> = ["PREQUEL", "SEQUEL", "ADAPTATION", "PARENT", "SOURCE"]

    var body: some View {
        if relations.isEmpty && prequel == nil && sequel == nil {
            SumiEmptyState(headline: "No Related Titles", detail: "No prequel, sequel, manga, light novel, or related adaptations recorded.")
        } else {
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
                        .font(.system(size: 13, weight: isResumeTarget ? .bold : .medium))
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
                Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(episode.isWatched ? SumiTheme.indigo : SumiTheme.muted.opacity(0.3))
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
                            .font(.system(size: 13.5, weight: isResumeTarget ? .bold : .semibold))
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
                .padding(.top, 3)

            Button(action: { onToggleWatched(!episode.isWatched) }) {
                Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundColor(episode.isWatched ? SumiTheme.indigo : SumiTheme.muted.opacity(0.4))
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
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.successLight)
                .help("Downloaded")
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
    }

    @ViewBuilder
    private var progressTick: some View {
        if episode.isWatched {
            Rectangle()
                .fill(SumiTheme.indigo)
                .frame(height: 2.5)
                .frame(maxHeight: .infinity, alignment: .bottom)
        } else if let percent = episode.progressPercent, percent > 0 {
            let pct = min(max(CGFloat(percent / 100), 0.1), 1)
            ZStack(alignment: .leading) {
                Rectangle().fill(SumiTheme.foreground.opacity(0.2))
                Rectangle()
                    .fill(SumiTheme.indigo)
                    .scaleEffect(x: pct, y: 1, anchor: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 2.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
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
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 460)
        .background(SumiTheme.card)
    }
}
