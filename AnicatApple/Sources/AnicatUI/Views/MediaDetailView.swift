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

        public init(
            id: Int64,
            number: Int,
            title: String,
            thumbnailURL: URL? = nil,
            isWatched: Bool = false,
            progressPercent: Double? = nil
        ) {
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
    public let onExportAppleBooks: () -> Void
    public let onClose: () -> Void

    @State private var selectedTab: DetailTab = .episodes
    @State private var isSynopsisExpanded = false

    public init(
        details: HeroBanner.Details,
        episodes: [EpisodeItem] = [],
        mangaChapters: [MangaChapterItem] = [],
        characters: [CharacterItem] = [],
        onPlayEpisode: @escaping (EpisodeItem) -> Void = { _ in },
        onReadChapter: @escaping (MangaChapterItem) -> Void = { _ in },
        onExportAppleBooks: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.details = details
        self.episodes = episodes
        self.mangaChapters = mangaChapters
        self.characters = characters
        self.onPlayEpisode = onPlayEpisode
        self.onReadChapter = onReadChapter
        self.onExportAppleBooks = onExportAppleBooks
        self.onClose = onClose
    }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            SumiTheme.background
                .ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    // Hero Banner Header
                    HeroBanner(
                        details: details,
                        onPrimaryAction: {
                            if let first = episodes.first {
                                onPlayEpisode(first)
                            }
                        },
                        onTrailerAction: {}
                    )
                    .padding(.horizontal, SumiTheme.spaceMd)
                    .padding(.top, SumiTheme.spaceMd)

                    // Tab Selector Bar
                    HStack(spacing: 24) {
                        ForEach(DetailTab.allCases) { tab in
                            Button(action: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    selectedTab = tab
                                }
                            }) {
                                VStack(spacing: 8) {
                                    HStack(spacing: 6) {
                                        Text(tab.rawValue.uppercased())
                                            .sumiTabularMono(size: 12, weight: selectedTab == tab ? .semibold : .medium)
                                            .foregroundColor(selectedTab == tab ? SumiTheme.foreground : SumiTheme.muted)
                                        
                                        if tab == .episodes && !episodes.isEmpty {
                                            Text("(\(episodes.count))")
                                                .sumiTabularMono(size: 10.5)
                                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                                        } else if tab == .manga && !mangaChapters.isEmpty {
                                            Text("(\(mangaChapters.count))")
                                                .sumiTabularMono(size: 10.5)
                                                .foregroundColor(SumiTheme.muted.opacity(0.8))
                                        }
                                    }

                                    // Active Tab Underline Indicator
                                    Rectangle()
                                        .fill(selectedTab == tab ? SumiTheme.indigo : Color.clear)
                                        .frame(height: 2)
                                        .clipShape(Capsule())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, SumiTheme.spaceLg)
                    .padding(.top, SumiTheme.spaceLg)
                    .overlay(
                        Divider()
                            .background(SumiTheme.border),
                        alignment: .bottom
                    )

                    // Tab Content Body
                    VStack(alignment: .leading, spacing: SumiTheme.spaceMd) {
                        switch selectedTab {
                        case .episodes:
                            episodesView
                        case .manga:
                            mangaChaptersView
                        case .novels:
                            novelsView
                        case .characters:
                            charactersView
                        case .related:
                            relatedView
                        }
                    }
                    .padding(SumiTheme.spaceLg)
                }
            }

            // Floating Close Button (Top Right)
            HStack {
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .frame(width: 32, height: 32)
                        .background(SumiTheme.card.opacity(0.85))
                        .clipShape(Circle())
                        .overlay(Circle().stroke(SumiTheme.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(SumiTheme.spaceLg)
            }
        }
    }

    // MARK: - Episodes Grid
    private var episodesView: some View {
        LazyVStack(spacing: 8) {
            ForEach(episodes) { ep in
                Button(action: { onPlayEpisode(ep) }) {
                    HStack(spacing: 16) {
                        // Thumbnail with Play Overlay
                        ZStack {
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                .fill(SumiTheme.card)
                                .frame(width: 120, height: 68)

                            AsyncImage(url: ep.thumbnailURL) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 120, height: 68)
                                        .clipped()
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 24))
                                .foregroundColor(SumiTheme.indigo)
                                .background(Circle().fill(Color.black.opacity(0.4)))
                        }

                        // Info
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("Episode \(ep.number)")
                                    .sumiTabularMono(size: 11, weight: .medium)
                                    .foregroundColor(SumiTheme.indigo)

                                if ep.isWatched {
                                    StatusBadge(.neutral("Watched"))
                                }
                            }

                            Text(ep.title.isEmpty ? "Episode \(ep.number)" : ep.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                        }

                        Spacer()

                        Image(systemName: "play.fill")
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.muted)
                            .padding(8)
                            .background(SumiTheme.card)
                            .clipShape(Circle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Manga Chapters (Unified Franchise Universe)
    private var mangaChaptersView: some View {
        LazyVStack(spacing: 8) {
            ForEach(mangaChapters) { ch in
                Button(action: { onReadChapter(ch) }) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Chapter \(ch.number)")
                                .sumiTabularMono(size: 11, weight: .semibold)
                                .foregroundColor(SumiTheme.indigo)
                            Text(ch.title.isEmpty ? "Chapter \(ch.number)" : ch.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                        }

                        Spacer()

                        if let group = ch.scanlationGroup {
                            Text(group)
                                .sumiTabularMono(size: 10)
                                .foregroundColor(SumiTheme.muted)
                        }

                        Text("Read")
                            .sumiTabularMono(size: 11, weight: .semibold)
                            .foregroundColor(SumiTheme.background)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(SumiTheme.indigo)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    }
                    .padding(12)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Light Novels & Apple Books Exporter
    private var novelsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Light Novel Adaptation")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                    Text("Export formatted EPUBs directly into Apple Books with iCloud sync across iPhone and iPad")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.muted)
                }
                Spacer()
                Button(action: onExportAppleBooks) {
                    HStack(spacing: 6) {
                        Image(systemName: "book.and.wrench.fill")
                        Text("Export to Apple Books")
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(SumiTheme.background)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(SumiTheme.indigo)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }
    }

    // MARK: - Characters
    private var charactersView: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
            ForEach(characters) { char in
                HStack(spacing: 12) {
                    AsyncImage(url: char.imageURL) { phase in
                        if let img = phase.image {
                            img.resizable().aspectRatio(contentMode: .fill)
                        } else {
                            Rectangle().fill(SumiTheme.card)
                        }
                    }
                    .frame(width: 50, height: 65)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(char.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(1)
                        Text(char.role)
                            .sumiTabularMono(size: 10)
                            .foregroundColor(SumiTheme.muted)

                        if let va = char.voiceActorName {
                            Text("VA: \(va)")
                                .font(.system(size: 11))
                                .foregroundColor(SumiTheme.indigo)
                                .lineLimit(1)
                                .padding(.top, 2)
                        }
                    }
                    Spacer()
                }
                .padding(8)
                .background(SumiTheme.card)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
            }
        }
    }

    // MARK: - Related
    private var relatedView: some View {
        Text("Relations, Prequels & Sequels")
            .font(.system(size: 14))
            .foregroundColor(SumiTheme.muted)
    }
}
