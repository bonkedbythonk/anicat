import SwiftUI
import AnicatCoreKit

public struct RootView: View {
    @Bindable public var model: AppModel
    @State private var playerController = PlayerController()

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            SumiTheme.background
                .ignoresSafeArea()

            // Main Application Shell: Fixed 200px Sidebar + Dynamic Content
            HStack(spacing: 0) {
                // Fixed Left Sidebar (exact Tauri layout)
                SidebarView(
                    currentView: $model.currentNavSection,
                    onOpenSearchPalette: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            model.currentNavSection = .search
                        }
                    }
                )

                // Hairline Divider
                Rectangle()
                    .fill(SumiTheme.border)
                    .frame(width: 1)
                    .ignoresSafeArea()

                // Dynamic Main Content Area
                VStack(spacing: 0) {
                    // Titlebar Spacer (38px on macOS to clear traffic lights)
                    Color.clear
                        .frame(height: 38)

                    // Active Section Switcher
                    Group {
                        switch model.currentNavSection {
                        case .upNext:
                            homeView
                        case .schedule:
                            ScheduleView(items: model.scheduleItems) { item in
                                openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL)
                            }
                        case .search:
                            SearchView(
                                searchText: $model.searchQuery,
                                results: model.searchResults,
                                isLoading: model.isLoading,
                                onSearchCommit: { q in
                                    Task { await model.search(query: q) }
                                },
                                onSelectMedia: { item in
                                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL)
                                }
                            )
                        case .settings:
                            SettingsView(
                                onSaveToken: { token in
                                    _ = iCloudSyncService.shared.saveAniListToken(token)
                                    Task { await model.initialize(anilistToken: token) }
                                },
                                onDisconnectAniList: {
                                    iCloudSyncService.shared.deleteAniListToken()
                                }
                            )
                        case .library, .history, .downloads, .manga, .novels:
                            genericListView(title: model.currentNavSection.label)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            // Media Detail Overlay
            if let details = model.selectedMediaDetails {
                MediaDetailView(
                    details: details,
                    episodes: model.selectedEpisodes,
                    mangaChapters: model.selectedMangaChapters,
                    characters: [],
                    onPlayEpisode: { ep in
                        Task {
                            _ = try? await model.resolveAndPlay(
                                catalogId: details.id,
                                episode: Int64(ep.number),
                                title: details.title
                            )
                        }
                    },
                    onReadChapter: { _ in },
                    onExportAppleBooks: {},
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            model.selectedMediaDetails = nil
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(10)
            }

            // In-App Video Player Overlay
            if let streamURL = model.activeStreamURL {
                PlayerView(
                    controller: playerController,
                    streamURL: streamURL,
                    onClose: {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            model.stopPlayback()
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(30)
            }

            // Loading Scrim
            if model.isLoading {
                ZStack {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                    ProgressView()
                        .scaleEffect(1.2)
                        .tint(SumiTheme.indigo)
                }
                .transition(.opacity)
                .zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: model.activeStreamURL != nil)
        .animation(.easeInOut(duration: 0.25), value: model.selectedMediaDetails != nil)
        .animation(.easeInOut(duration: 0.2), value: model.isLoading)
    }

    // MARK: - Home / Up Next View
    private var homeView: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 32) {
                // Up Next Section Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Up Next")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundColor(SumiTheme.foreground)

                            if !model.upNextItems.isEmpty {
                                Text("\(model.upNextItems.count) in progress")
                                    .sumiTabularMono(size: 11, weight: .medium)
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }

                        Spacer()

                        // "Pick for me" Random Episode Selector
                        Button(action: {
                            if let random = model.trendingItems.randomElement() {
                                openDetailFor(id: random.id, title: random.title, coverURL: random.coverImageURL)
                            }
                        }) {
                            Text("Pick for me")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SumiTheme.foreground.opacity(0.75))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(SumiTheme.card)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                        .stroke(SumiTheme.border, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }

                    // Up Next Queue Container
                    if !model.upNextItems.isEmpty {
                        UpNextQueueView(
                            items: model.upNextItems,
                            onSelect: { entry in
                                openDetailFor(id: entry.id, title: entry.title, coverURL: entry.thumbnailURL)
                            },
                            onPlay: { entry in
                                Task {
                                    _ = try? await model.resolveAndPlay(
                                        catalogId: entry.id,
                                        episode: Int64(entry.nextEpisodeOrChapter),
                                        title: entry.title
                                    )
                                }
                            }
                        )
                    }
                }

                // Watching Row
                if !model.watchingItems.isEmpty {
                    mediaRow(title: "Watching", count: model.watchingItems.count, items: model.watchingItems)
                }

                // Trending Row
                if !model.trendingItems.isEmpty {
                    mediaRow(title: "Trending Now", count: model.trendingItems.count, items: model.trendingItems)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
        }
        .background(SumiTheme.background)
    }

    private func mediaRow(title: String, count: Int, items: [MediaCard.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(SumiTheme.foreground)

                Spacer()

                Text("\(count) shows")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(items) { item in
                        MediaCard(item: item) {
                            openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL)
                        }
                        .frame(width: 165)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func genericListView(title: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 36))
                .foregroundColor(SumiTheme.muted.opacity(0.3))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            Text("Content loaded from AniList and local database.")
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(SumiTheme.background)
    }

    private func openDetailFor(id: Int64, title: String, coverURL: URL?) {
        let details = HeroBanner.Details(
            id: id,
            title: title,
            romajiTitle: nil,
            bannerURL: coverURL,
            coverURL: coverURL,
            format: "TV",
            year: 2024,
            studio: nil,
            synopsis: "An extraordinary journey begins.",
            genres: ["Adventure", "Fantasy", "Drama"],
            averageScore: 92,
            nextEpisodeText: "EP 5 / 28"
        )

        let episodes = (1...28).map { ep in
            MediaDetailView.EpisodeItem(
                id: Int64(ep),
                number: ep,
                title: "Episode \(ep)",
                thumbnailURL: coverURL,
                isWatched: ep < 5,
                progressPercent: ep == 5 ? 45 : 0
            )
        }

        withAnimation(.easeInOut(duration: 0.25)) {
            model.selectedMediaDetails = details
            model.selectedEpisodes = episodes
        }
    }
}
