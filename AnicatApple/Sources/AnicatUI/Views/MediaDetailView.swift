import SwiftUI

public struct MediaDetailView: View {
    public enum DetailTab: String, CaseIterable, Identifiable {
        case episodes = "Episodes"
        case manga = "Manga"
        case novels = "Light Novels"
        case characters = "Characters"
        case related = "Related"

        public var id: String { rawValue }
    }

    public struct EpisodeItem: Identifiable, Sendable {
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

    public struct MangaChapterItem: Identifiable, Sendable {
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

    public struct CharacterItem: Identifiable, Sendable {
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

    // Properties
    public let details: HeroBanner.Details
    public let episodes: [EpisodeItem]
    public let mangaChapters: [MangaChapterItem]
    public let characters: [CharacterItem]
    
    public let onPlayEpisode: (EpisodeItem) -> Void
    public let onReadChapter: (MangaChapterItem) -> Void
    public let onSelectRelation: ((HeroBanner.Details.Relation) -> Void)?
    public let onExportAppleBooks: () -> Void
    public let onClose: () -> Void

    @State private var selectedTab: DetailTab = .episodes
    @State private var isSynopsisExpanded = false
    @State private var isBackHovered = false

    public init(
        details: HeroBanner.Details,
        episodes: [EpisodeItem] = [],
        mangaChapters: [MangaChapterItem] = [],
        characters: [CharacterItem] = [],
        onPlayEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        onReadChapter: @escaping (MangaChapterItem) -> Void = { _ in },
        onSelectRelation: ((HeroBanner.Details.Relation) -> Void)? = nil,
        onExportAppleBooks: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.details = details
        self.episodes = episodes
        self.mangaChapters = mangaChapters
        self.characters = characters
        self.onPlayEpisode = onPlayEpisode
        self.onReadChapter = onReadChapter
        self.onSelectRelation = onSelectRelation
        self.onExportAppleBooks = onExportAppleBooks
        self.onClose = onClose

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


    /// Overlap of the content column onto the banner. The poster is meant to
    /// straddle the two, which is what makes the page read as one image with
    /// information laid over it rather than a header stacked above a list.
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
    }

    // MARK: - Banner

    private var banner: some View {
        ZStack(alignment: .topLeading) {
            // The banner rides in an overlay on a zero-size base. A
            // `.fill`-mode image reports its own intrinsic width no matter
            // what `.frame(maxWidth:)` asks of it, and that width propagated
            // all the way up the hierarchy and pushed the 200pt sidebar off
            // the left edge of the window.
            Color.clear
                .frame(height: 288)
                .frame(maxWidth: .infinity)
                .overlay {
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
            // 40% up, clear at the top. The middle stop is what keeps the
            // title legible over a bright banner without dimming the art.
            LinearGradient(
                stops: [
                    .init(color: SumiTheme.background, location: 0),
                    .init(color: Color(red: 5/255, green: 5/255, blue: 5/255).opacity(0.6), location: 0.6),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .bottom,
                endPoint: .top
            )
            .frame(height: 288)

            // Top Left Back Button (positioned directly above poster card in 1150pt container)
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
        // A negative top padding, not an offset. `.offset` moves the view
        // without changing the height the stack reports, and pairing it with
        // a negative bottom padding to compensate left the ScrollView
        // believing its content fit — the page would not scroll at all and
        // the episode list below the fold was unreachable.
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

    /// The one filled control on the page. Everything beside it is a hairline,
    /// so there is never a question about what the primary action is.
    private var actionBar: some View {
        HStack(spacing: 10) {
            if !episodes.isEmpty {
                Button {
                    if let episode = resumeTarget { onPlayEpisode(episode) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill").font(.system(size: 12))
                        Text(primaryActionLabel)
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
                .buttonStyle(.plain)
                .disabled(resumeTarget == nil)
                .opacity(resumeTarget == nil ? 0.5 : 1)
            } else if let first = mangaChapters.first {
                Button {
                    onReadChapter(first)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "book.fill").font(.system(size: 12))
                        Text("Read Chapter \(first.number)")
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 11)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
                .buttonStyle(.plain)
            }

            hairlineControl { Text("Watching").font(.system(size: 13, weight: .medium)) }
            hairlineControl { Image(systemName: "heart").font(.system(size: 14)) }
            hairlineControl { Image(systemName: "ellipsis").font(.system(size: 14)) }
            Spacer(minLength: 0)
        }
    }

    private func hairlineControl<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundColor(SumiTheme.foreground.opacity(0.8))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
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
            Text("Synopsis")
                .sumiTabularMono(size: 11.5)
                .foregroundColor(SumiTheme.indigo)

            // Body copy, not metadata: it reads at foreground/80 rather than
            // the muted token the labels around it use.
            Text(text)
                .font(.system(size: 14))
                .lineSpacing(4)
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
                .lineLimit(isSynopsisExpanded ? nil : 3)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                withAnimation(.easeInOut(duration: 0.25)) { isSynopsisExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Text(isSynopsisExpanded ? "Show Less" : "Read Full Synopsis")
                    Image(systemName: isSynopsisExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(SumiTheme.foreground.opacity(0.5))
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var seasonChain: some View {
        if details.prequel != nil || details.sequel != nil {
            HStack(spacing: 12) {
                if let prequel = details.prequel {
                    relationCard(prequel, label: "Previous Season", leading: true)
                }
                if let sequel = details.sequel {
                    relationCard(sequel, label: "Next Season", leading: false)
                }
            }
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
                HStack(spacing: 12) {
                    if leading {
                        Image(systemName: "chevron.left").font(.system(size: 14)).foregroundColor(SumiTheme.muted)
                        Color.clear
                            .frame(width: 40, height: 56)
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
                                .sumiTabularMono(size: 11.5)
                                .foregroundColor(SumiTheme.indigo)
                            Text(relation.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            if let format = relation.format {
                                Text(format)
                                    .font(.system(size: 10))
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label)
                                .sumiTabularMono(size: 11.5)
                                .foregroundColor(SumiTheme.indigo)
                            Text(relation.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            if let format = relation.format {
                                Text(format)
                                    .font(.system(size: 10))
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear
                            .frame(width: 40, height: 56)
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
                        Image(systemName: "chevron.right").font(.system(size: 14)).foregroundColor(SumiTheme.muted)
                    }
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
        }
    }

    // MARK: - Tabs

    private var availableTabs: [DetailTab] {
        var tabs: [DetailTab] = []
        if !episodes.isEmpty { tabs.append(.episodes) }
        if !mangaChapters.isEmpty { tabs.append(.manga) }
        if !characters.isEmpty { tabs.append(.characters) }
        return tabs.isEmpty ? [.episodes] : tabs
    }

    private func tabLabel(_ tab: DetailTab) -> String {
        switch tab {
        case .episodes: return episodes.isEmpty ? "Episodes" : "Episodes (\(episodes.count))"
        case .manga: return "Chapters (\(mangaChapters.count))"
        case .characters: return "Cast & Staff"
        case .related: return "Related"
        case .novels: return "Light Novels"
        }
    }

    private var activeTab: DetailTab {
        if availableTabs.contains(selectedTab) {
            return selectedTab
        }
        return availableTabs.first ?? .episodes
    }

    private var tabBar: some View {
        HStack(spacing: 28) {
            ForEach(availableTabs) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 8) {
                        Text(tabLabel(tab))
                            .sumiTabularMono(size: 11.5, weight: activeTab == tab ? .semibold : .regular)
                            .foregroundColor(activeTab == tab ? SumiTheme.foreground : SumiTheme.muted)
                        // The underline is the whole indicator; the tab row has
                        // no pill and no fill, so the bar reads as one rule
                        // with one segment lit.
                        Rectangle()
                            .fill(activeTab == tab ? SumiTheme.indigo : Color.clear)
                            .frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .overlay(Rectangle().fill(SumiTheme.border).frame(height: 1), alignment: .bottom)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch activeTab {
        case .episodes:
            if episodes.isEmpty {
                SumiEmptyState(headline: "No episodes found", detail: "Nothing was returned for this title.")
            } else {
                VStack(spacing: 8) {
                    ForEach(episodes) { episode in
                        EpisodeRow(
                            episode: episode,
                            isResumeTarget: episode.id == resumeTarget?.id,
                            resumeSeconds: episode.number == details.resumeEpisode ? details.resumeSeconds : nil,
                            onPlay: { onPlayEpisode(episode) }
                        )
                    }
                }
            }
        case .manga:
            if mangaChapters.isEmpty {
                SumiEmptyState(headline: "No chapters found", detail: "No chapters were found for this title.")
            } else {
                VStack(spacing: 8) {
                    ForEach(mangaChapters) { chapter in
                        ChapterRowView(chapter: chapter) {
                            onReadChapter(chapter)
                        }
                    }
                }
            }
        default:
            SumiEmptyState(headline: "Not available", detail: "This tab has nothing to show for this title yet.")
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
        }
    }
}

/// One episode, as a card: thumbnail with its state drawn on it, then the
/// meta line, title and description.
private struct EpisodeRow: View {
    let episode: MediaDetailView.EpisodeItem
    let isResumeTarget: Bool
    let resumeSeconds: Int?
    let onPlay: () -> Void

    @State private var isHovered = false

    var body: some View {
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
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(isHovered ? SumiTheme.card : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(isHovered ? SumiTheme.border.opacity(0.9) : (isResumeTarget ? SumiTheme.foreground.opacity(0.25) : SumiTheme.border), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .onHover { isHovered = $0 }
        #endif
    }

    private var metaLine: some View {
        HStack(spacing: 6) {
            Text("EP \(episode.number)")
                .foregroundColor(SumiTheme.indigo)
                .fontWeight(.semibold)
            if let airDate = episode.airDate {
                Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))
                Text(airDate).foregroundColor(SumiTheme.muted)
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
