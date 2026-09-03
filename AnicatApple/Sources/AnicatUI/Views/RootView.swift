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

            // Main Dashboard View
            DashboardView(
                upNextItems: model.upNextItems,
                watchingItems: model.watchingItems,
                trendingItems: model.trendingItems,
                seasonalItems: model.searchResults.isEmpty ? model.trendingItems : model.searchResults,
                onSelectQueueEntry: { entry in
                    openDetailFor(id: entry.id, title: entry.title, coverURL: entry.thumbnailURL)
                },
                onPlayQueueEntry: { entry in
                    Task {
                        _ = try? await model.resolveAndPlay(
                            catalogId: entry.id,
                            episode: Int64(entry.nextEpisodeOrChapter),
                            title: entry.title
                        )
                    }
                },
                onSelectMedia: { item in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL)
                },
                onPickForMe: {
                    if let random = model.trendingItems.randomElement() {
                        openDetailFor(id: random.id, title: random.title, coverURL: random.coverImageURL)
                    }
                }
            )

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

    private func openDetailFor(id: Int64, title: String, coverURL: URL?) {
        // Build details payload
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

        // Populate sample episodes for this show
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
