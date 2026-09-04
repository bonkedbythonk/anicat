import SwiftUI
#if os(macOS)
import AppKit
#endif

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

    public struct EpisodeItem: Identifiable, Sendable, Codable {
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
    
    public let onPlayEpisode: (EpisodeItem) -> Void
    public let onReadChapter: (MangaChapterItem) -> Void
    public let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    public let onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)?
    public let onExportAppleBooks: () -> Void
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

    @State private var selectedTab: DetailTab = .episodes
    @State private var selectedAudioType: AudioType = .sub
    @State private var selectedViewMode: EpisodeViewMode = .cards
    @State private var isSynopsisExpanded = false
    @State private var isBackHovered = false

    public init(
        details: HeroBanner.Details,
        episodes: [EpisodeItem] = [],
        mangaChapters: [MangaChapterItem] = [],
        characters: [CharacterItem] = [],
        relations: [RelationItem] = [],
        recommendations: [RecommendationItem] = [],
        discussions: [DiscussionItem] = [],
        onPlayEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        onReadChapter: @escaping (MangaChapterItem) -> Void = { _ in },
        onSelectRelation: ((HeroBanner.Details.Relation) -> Void)? = nil,
        onSelectMediaId: ((Int64, String, URL?, Bool) -> Void)? = nil,
        onExportAppleBooks: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {},
        onSetListStatus: @escaping (String) -> Void = { _ in },
        onToggleFavourite: @escaping () -> Void = {},
        onRemoveFromList: @escaping () -> Void = {},
        onSetEpisodeWatched: @escaping (Int, Bool) -> Void = { _, _ in },
        onLoadReleaseCandidates: @escaping (Int) async -> [ReleaseCandidateItem] = { _ in [] },
        onPlayWithRelease: @escaping (EpisodeItem, String) -> Void = { _, _ in },
        onDownloadEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        downloadStates: [Int: EpisodeDownloadState] = [:]
    ) {
        self.details = details
        self.episodes = episodes
        self.mangaChapters = mangaChapters
        self.characters = characters
        self.relations = relations
        self.recommendations = recommendations
        self.discussions = discussions
        self.onPlayEpisode = onPlayEpisode
        self.onReadChapter = onReadChapter
        self.onSelectRelation = onSelectRelation
        self.onSelectMediaId = onSelectMediaId
        self.onExportAppleBooks = onExportAppleBooks
        self.onClose = onClose
        self.onSetListStatus = onSetListStatus
        self.onToggleFavourite = onToggleFavourite
        self.onRemoveFromList = onRemoveFromList
        self.onSetEpisodeWatched = onSetEpisodeWatched
        self.onLoadReleaseCandidates = onLoadReleaseCandidates
        self.onPlayWithRelease = onPlayWithRelease
        self.onDownloadEpisode = onDownloadEpisode
        self.downloadStates = downloadStates

        let initial: DetailTab
        if !episodes.isEmpty {
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


    /// Overlap of the content column onto the banner. Sized to match the Tauri app
    /// where the poster sits lower and does not intrude too high into the banner artwork.
    private let bannerOverlap: CGFloat = 50

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
    }

    // MARK: - Banner

    private var banner: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: "#161310")

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
                // A source banner scaled to fill this frame is usually
                // taller than 288pt once its width matches the column, so
                // centering (the default alignment) crops evenly off both
                // edges — cutting as much off the bottom, where an anime
                // banner's characters actually are, as off the top, which is
                // usually just sky or logo art. Bottom-aligning the overlay
                // keeps the bottom of the source pinned and crops the top
                // instead, so the image reads lower in the frame.
                .overlay(alignment: .bottom) {
                    AsyncImage(url: details.bannerURL ?? details.coverURL) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(SumiTheme.card)
                        }
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

            // Top Left Back Button (positioned cleanly below window traffic lights zone)
            VStack(alignment: .leading) {
                Button(action: onClose) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundColor(isBackHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.8))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(isBackHovered ? SumiTheme.card.opacity(0.9) : Color.black.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(isBackHovered ? SumiTheme.border : Color.white.opacity(0.12), lineWidth: 1)
                    )
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
        }
        .padding(.horizontal, 56)
        .padding(.bottom, 64)
        .frame(maxWidth: 1150, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, -bannerOverlap)
    }

    private var poster: some View {
        Color.clear
            .frame(width: 192, height: 288)
            .overlay {
                AsyncImage(url: details.coverURL) { phase in
                    if let image = phase.image {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(SumiTheme.card)
                    }
                }
            }
            .clipped()
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusXl))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusXl)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 24, y: 10)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 16) {
            metaLine
                .padding(.top, bannerOverlap + 24)

            Text(details.title)
                .font(.system(size: 36, weight: .bold))
                .tracking(-0.8)
                .foregroundColor(SumiTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if !details.genres.isEmpty {
                genrePills
            }

            actionBar

            if let synopsis = details.synopsis, !synopsis.isEmpty {
                synopsisBlock(synopsis)
            }

            seasonChain
        }
    }

    /// Tabs and their content, full-width below the poster/info row. The web
    /// build keeps the episode list out of the poster's column — it spans the
    /// whole content width — and the native port had it squeezed beside the
    /// poster, which is why every episode row looked about 200pt too narrow.
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

    /// The one line of state above the title. Everything is muted mono except
    /// the three things worth colouring: the format, the airing status, and
    /// the counts.
    private var metaLine: some View {
        HStack(spacing: 12) {
            if let format = details.format {
                Text(format).foregroundColor(SumiTheme.foreground).fontWeight(.semibold)
            }
            switch details.status {
            case "RELEASING":
                Text("Airing").foregroundColor(SumiTheme.indigo).fontWeight(.semibold)
            case "FINISHED":
                Text("Finished").foregroundColor(Color(hex: "#34D399")).fontWeight(.semibold)
            default:
                EmptyView()
            }
            if let count = details.episodeCount, count > 0 {
                let unit = (episodes.isEmpty && !mangaChapters.isEmpty) ? "CH" : "EP"
                Text("\(count) \(unit)").foregroundColor(SumiTheme.indigo).fontWeight(.semibold)
            }
            if let year = details.year {
                Text(String(year)).foregroundColor(SumiTheme.muted)
            }
            if let studio = details.studio {
                Text(studio).foregroundColor(SumiTheme.muted)
            }
            if let score = details.averageScore, score > 0 {
                Text("Score \(score)%").foregroundColor(SumiTheme.indigo).fontWeight(.semibold)
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
                        Image(systemName: "play.fill").font(.system(size: 12))
                        Text(primaryActionLabel)
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 4, height: 4)
                    }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .shadow(color: SumiTheme.indigo.opacity(0.2), radius: 8, y: 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(resumeTarget == nil)
                .opacity(resumeTarget == nil ? 0.5 : 1)
            } else if let first = mangaChapters.first {
                Button {
                    onReadChapter(first)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "book.fill").font(.system(size: 12))
                        Text("Read Chapter \(first.number)")
                    }
                    .font(.system(size: 13.5, weight: .bold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .shadow(color: SumiTheme.indigo.opacity(0.2), radius: 8, y: 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Menu {
                ForEach(Self.listStatusOptions, id: \.self) { status in
                    Button(Self.statusLabel(status)) { onSetListStatus(status) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(Self.statusLabel(details.listStatus))
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(SumiTheme.foreground.opacity(0.9))
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(SumiTheme.card.opacity(0.8))
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
                // `Menu`'s built-in hit target is computed from its label's
                // drawn content, not its `.frame()` — the background fill
                // reads as decoration, not a hit-testable shape, so only the
                // text/chevron glyphs themselves were clickable and the
                // pill's visible padding around them was dead space.
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button(action: onToggleFavourite) {
                Image(systemName: details.isFavourite ? "heart.fill" : "heart")
                    .font(.system(size: 14))
                    .foregroundColor(details.isFavourite ? Color(hex: "#EC4899") : SumiTheme.foreground.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(details.isFavourite ? Color(hex: "#EC4899").opacity(0.15) : SumiTheme.card.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(details.isFavourite ? Color(hex: "#EC4899").opacity(0.4) : SumiTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                Button(role: .destructive, action: onRemoveFromList) {
                    Label("Remove from AniList", systemImage: "trash")
                }
                .disabled(details.listEntryId == nil)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14))
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                    .frame(width: 36, height: 36)
                    .background(SumiTheme.card.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    .contentShape(Rectangle())
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

    private var primaryActionLabel: String {
        guard let target = resumeTarget else { return "Nothing to play" }
        if let seconds = details.resumeSeconds, seconds > 0, target.number == details.resumeEpisode {
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
        VStack(alignment: .leading, spacing: 10) {
            Text("SYNOPSIS")
                .sumiTabularMono(size: 11)
                .foregroundColor(SumiTheme.indigo)

            // Body copy, not metadata: it reads at foreground/80 rather than
            // the muted token the labels around it use.
            Text(text)
                .font(.system(size: 13.5))
                .lineSpacing(4)
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
                .lineLimit(isSynopsisExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.snappy) { isSynopsisExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(isSynopsisExpanded ? "Show Less" : "Read Full Synopsis")
                    Image(systemName: isSynopsisExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(SumiTheme.foreground.opacity(0.5))
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var seasonChain: some View {
        if details.prequel != nil || details.sequel != nil {
            HStack(spacing: 12) {
                if let prequel = details.prequel {
                    relationCard(prequel, label: "PREVIOUS SEASON", leading: true)
                }
                if let sequel = details.sequel {
                    relationCard(sequel, label: "NEXT SEASON", leading: false)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relationCard(_ relation: HeroBanner.Details.Relation, label: String, leading: Bool) -> some View {
        RelationCardView(relation: relation, label: label, leading: leading, onSelect: onSelectRelation)
    }

    private struct RelationCardView: View {
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
                        Color.clear
                            .frame(width: 36, height: 48)
                            .overlay {
                                AsyncImage(url: relation.coverURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Rectangle().fill(SumiTheme.card)
                                    }
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
                        Color.clear
                            .frame(width: 36, height: 48)
                            .overlay {
                                AsyncImage(url: relation.coverURL) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Rectangle().fill(SumiTheme.card)
                                    }
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
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
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
        HStack(alignment: .bottom, spacing: 0) {
            HStack(spacing: 24) {
                ForEach(availableTabs) { tab in
                    Button {
                        withAnimation(.smooth) {
                            selectedTab = tab
                        }
                    } label: {
                        VStack(spacing: 8) {
                            Text(tabLabel(tab))
                                .sumiTabularMono(size: 11, weight: activeTab == tab ? .bold : .medium)
                                .foregroundColor(activeTab == tab ? SumiTheme.foreground : SumiTheme.muted)
                            Rectangle()
                                .fill(activeTab == tab ? SumiTheme.indigo : Color.clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 16)

            // Right side: Audio and ViewMode toggles when episodes tab is active
            if activeTab == .episodes && !episodes.isEmpty {
                HStack(spacing: 12) {
                    // Audio toggle
                    HStack(spacing: 6) {
                        Text("AUDIO:")
                            .sumiTabularMono(size: 10.5, weight: .bold)
                            .foregroundColor(SumiTheme.muted)

                        HStack(spacing: 2) {
                            ForEach(AudioType.allCases, id: \.self) { audio in
                                Button {
                                    withAnimation(.snappy) {
                                        selectedAudioType = audio
                                    }
                                } label: {
                                    Text(audio.rawValue)
                                        .sumiTabularMono(size: 10.5, weight: selectedAudioType == audio ? .bold : .regular)
                                        .foregroundColor(selectedAudioType == audio ? SumiTheme.indigo : SumiTheme.muted)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(selectedAudioType == audio ? SumiTheme.indigo.opacity(0.18) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(2)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))
                    }

                    // View Mode toggle: Cards | Compact
                    HStack(spacing: 2) {
                        ForEach(EpisodeViewMode.allCases, id: \.self) { mode in
                            Button {
                                withAnimation(.snappy) {
                                    selectedViewMode = mode
                                }
                            } label: {
                                Text(mode.rawValue)
                                    .font(.system(size: 10.5, weight: selectedViewMode == mode ? .bold : .medium))
                                    .foregroundColor(selectedViewMode == mode ? SumiTheme.foreground : SumiTheme.muted)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 3)
                                    .background(selectedViewMode == mode ? SumiTheme.foreground.opacity(0.12) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(SumiTheme.border, lineWidth: 1))
                }
                .padding(.bottom, 6)
            }
        }
        .overlay(Rectangle().fill(SumiTheme.border).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .episodes:
            if episodes.isEmpty {
                SumiEmptyState(headline: "No episodes found", detail: "Nothing was returned for this title.")
            } else if selectedViewMode == .compact {
                VStack(spacing: 4) {
                    ForEach(episodes) { episode in
                        CompactEpisodeRow(
                            episode: episode,
                            isResumeTarget: episode.id == resumeTarget?.id,
                            resumeSeconds: episode.number == details.resumeEpisode ? details.resumeSeconds : nil,
                            onPlay: { onPlayEpisode(episode) },
                            onToggleWatched: { watched in onSetEpisodeWatched(episode.number, watched) }
                        )
                    }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isResumeTarget: episode.id == resumeTarget?.id,
                            resumeSeconds: episode.number == details.resumeEpisode ? details.resumeSeconds : nil,
                            downloadState: downloadStates[episode.number] ?? .notStarted,
                            onPlay: { onPlayEpisode(episode) },
                            onToggleWatched: { watched in onSetEpisodeWatched(episode.number, watched) },
                            onLoadReleaseCandidates: { await onLoadReleaseCandidates(episode.number) },
                            onPlayWithRelease: { name in onPlayWithRelease(episode, name) },
                            onDownload: { onDownloadEpisode(episode) }
                        )
                    }
                }
            }
        case .manga:
            if mangaChapters.isEmpty {
                if details.format == "NOVEL" {
                    SumiEmptyState(
                        headline: "Light novel reading isn't available yet",
                        detail: "There's no light-novel reader in the native app yet — this section is a placeholder, not a failed search."
                    )
                } else {
                    SumiEmptyState(headline: "No chapters found", detail: "No chapters were found for this title.")
                }
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(mangaChapters) { chapter in
                        ChapterRowView(chapter: chapter) {
                            onReadChapter(chapter)
                        }
                    }
                }
            }
        case .characters:
            if characters.isEmpty {
                SumiEmptyState(headline: "Cast & Staff", detail: "Loading cast & staff details for this title...")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120, maximum: 160), spacing: 14)], spacing: 14) {
                    ForEach(characters) { char in
                        Button {
                            #if os(macOS)
                            // AniList's character page carries the bio and
                            // every other role/show this voice actor has —
                            // there's no reason to rebuild that here.
                            if let url = URL(string: "https://anilist.co/character/\(char.id)") {
                                NSWorkspace.shared.open(url)
                            }
                            #endif
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
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
            }
        case .related:
            if relations.isEmpty && details.prequel == nil && details.sequel == nil {
                SumiEmptyState(headline: "No Related Titles", detail: "No prequel, sequel, manga, light novel, or related adaptations recorded.")
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    let mainRels = relations.filter { ["PREQUEL", "SEQUEL", "ADAPTATION", "PARENT", "SOURCE"].contains($0.relationType) }
                    let otherRels = relations.filter { !["PREQUEL", "SEQUEL", "ADAPTATION", "PARENT", "SOURCE"].contains($0.relationType) }

                    if !mainRels.isEmpty || details.prequel != nil || details.sequel != nil {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SEASONS & ADAPTATIONS")
                                .sumiTabularMono(size: 11)
                                .foregroundColor(SumiTheme.indigo)

                            if !mainRels.isEmpty {
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 240, maximum: 360), spacing: 12)], spacing: 12) {
                                    ForEach(mainRels) { rel in
                                        RelatedMediaCard(relation: rel) {
                                            let isManga = rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                            onSelectMediaId?(rel.id, rel.title, rel.coverURL, isManga)
                                        }
                                    }
                                }
                            } else {
                                seasonChain
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
                                    RelatedMediaCard(relation: rel) {
                                        let isManga = rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                        onSelectMediaId?(rel.id, rel.title, rel.coverURL, isManga)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        case .discussions:
            if discussions.isEmpty {
                SumiEmptyState(headline: "Discussions", detail: "No community discussion threads found for this title.")
            } else {
                VStack(spacing: 8) {
                    ForEach(discussions) { thread in
                        DiscussionRowView(thread: thread)
                    }
                }
            }
        case .more:
            if recommendations.isEmpty {
                SumiEmptyState(headline: "No Additional Content", detail: "No community recommendations found.")
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("RECOMMENDATIONS")
                        .sumiTabularMono(size: 11)
                        .foregroundColor(SumiTheme.indigo)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130, maximum: 165), spacing: 14)], spacing: 14) {
                        ForEach(recommendations) { rec in
                            RecommendationCardView(rec: rec) {
                                let isManga = rec.format == "MANGA" || rec.format == "NOVEL" || rec.format == "ONE_SHOT"
                                onSelectMediaId?(rec.id, rec.title, rec.coverURL, isManga)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct ChapterRowView: View {
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
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
            .animation(.snappy, value: isHovered)
        }
    }

    private struct RelatedMediaCard: View {
        let relation: MediaDetailView.RelationItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    Color.clear
                        .frame(width: 44, height: 60)
                        .overlay {
                            AsyncImage(url: relation.coverURL) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(SumiTheme.card)
                                }
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
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
            .animation(.snappy, value: isHovered)
        }
    }

    private struct DiscussionRowView: View {
        let thread: MediaDetailView.DiscussionItem

        @State private var isHovered = false

        // AniList's numeric thread id round-trips into its own forum URL —
        // there's no in-app thread reader, and there doesn't need to be one
        // just to make this tappable.
        private var threadURL: URL? {
            URL(string: "https://anilist.co/forum/thread/\(thread.id)")
        }

        var body: some View {
            Button {
                #if os(macOS)
                if let threadURL {
                    NSWorkspace.shared.open(threadURL)
                }
                #endif
            } label: {
                rowContent
            }
            .buttonStyle(.plain)
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
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
            .animation(.snappy, value: isHovered)
        }
    }

    private struct RecommendationCardView: View {
        let rec: MediaDetailView.RecommendationItem
        let onSelect: () -> Void

        @State private var isHovered = false

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 6) {
                    Color.clear
                        .aspectRatio(2/3, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: rec.coverURL) { phase in
                                if let image = phase.image {
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Rectangle().fill(SumiTheme.card)
                                }
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
            .buttonStyle(.plain)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
            .animation(.snappy, value: isHovered)
        }
    }
}

/// One episode, as a compact row.
private struct CompactEpisodeRow: View {
    let episode: MediaDetailView.EpisodeItem
    let isResumeTarget: Bool
    let resumeSeconds: Int?
    let onPlay: () -> Void
    let onToggleWatched: (Bool) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                HStack(spacing: 12) {
                    // Episode Number Badge
                    Text("\(episode.number)")
                        .sumiTabularMono(size: 11, weight: .bold)
                        .foregroundColor(isResumeTarget ? .black : (episode.isWatched ? SumiTheme.muted.opacity(0.6) : SumiTheme.muted))
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
            .buttonStyle(.plain)

            Button(action: { onToggleWatched(!episode.isWatched) }) {
                Image(systemName: episode.isWatched ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundColor(episode.isWatched ? SumiTheme.indigo : SumiTheme.muted.opacity(0.3))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
        .animation(.snappy, value: isHovered)
    }
}

/// One episode, as a card: thumbnail with its state drawn on it, then the
/// meta line, title and description.
private struct EpisodeRow: View {
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
    let onLoadReleaseCandidates: () async -> [MediaDetailView.ReleaseCandidateItem]
    let onPlayWithRelease: (String) -> Void
    let onDownload: () -> Void

    @State private var isHovered = false
    @State private var showServerPicker = false
    @State private var isLoadingServers = false
    @State private var serverCandidates: [MediaDetailView.ReleaseCandidateItem] = []

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

    static func formatAirDate(_ raw: String) -> String {
        guard let date = airDateParser.date(from: raw) else { return raw }
        return airDateDisplay.string(from: date)
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
            .buttonStyle(.plain)

            Button {
                showServerPicker = true
                guard serverCandidates.isEmpty else { return }
                isLoadingServers = true
                Task {
                    let found = await onLoadReleaseCandidates()
                    isLoadingServers = false
                    serverCandidates = found
                }
            } label: {
                Image(systemName: "server.rack")
                    .font(.system(size: 14))
                    .foregroundColor(SumiTheme.muted.opacity(0.6))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Stream Servers")
            .padding(.top, 3)
            .popover(isPresented: $showServerPicker, arrowEdge: .top) {
                ServerPickerView(
                    isLoading: isLoadingServers,
                    candidates: serverCandidates,
                    onSelect: { name in
                        showServerPicker = false
                        onPlayWithRelease(name)
                    }
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
            .buttonStyle(.plain)
            .help(episode.isWatched ? "Mark unwatched" : "Mark watched")
            .padding(.top, 2)
        }
        .padding(12)
        .background(isHovered ? SumiTheme.card : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(isHovered ? SumiTheme.border.opacity(0.9) : (isResumeTarget ? SumiTheme.foreground.opacity(0.25) : SumiTheme.border), lineWidth: 1)
        )
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
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
            .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
                    AsyncImage(url: episode.thumbnailURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                // A watched episode's still is dimmed rather
                                // than removed: the list stays scannable by
                                // picture.
                                .opacity(episode.isWatched ? 0.5 : 1)
                        } else {
                            Rectangle().fill(SumiTheme.foreground.opacity(0.05))
                        }
                    }
                }
                .clipped()

            if episode.isWatched {
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .black))
                    .foregroundColor(.black)
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(SumiTheme.foreground.opacity(0.2))
                    Rectangle()
                        .fill(SumiTheme.indigo)
                        .frame(width: geo.size.width * min(max(percent / 100, 0.1), 1))
                }
            }
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
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(candidate.name)
                                            .font(.system(size: 11, weight: .medium))
                                            .foregroundColor(SumiTheme.foreground)
                                            .lineLimit(2)
                                            .fixedSize(horizontal: false, vertical: true)
                                        HStack(spacing: 6) {
                                            if candidate.isDub {
                                                Text("DUB")
                                                    .sumiTabularMono(size: 9, weight: .bold)
                                                    .foregroundColor(SumiTheme.indigo)
                                            }
                                            Text("\(candidate.seeders) seeders")
                                                .sumiTabularMono(size: 9.5)
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
                            .buttonStyle(.plain)

                            if candidate.id != candidates.last?.id {
                                Divider().padding(.leading, 14)
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 340)
        .background(SumiTheme.card)
    }
}
