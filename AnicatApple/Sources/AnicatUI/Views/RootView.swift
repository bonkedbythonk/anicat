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

            // `.ignoresSafeArea()` is what puts the shell at the true window
            // top. `hiddenTitleBar` makes the title bar transparent but does
            // not remove it, so SwiftUI still insets its content below it —
            // measured against the running Tauri app, every row in the sidebar
            // sat about 32pt low, and the 38pt traffic-light spacer below was
            // clearing a gap that had already been cleared.
            HStack(spacing: 0) {
                // Fixed Left Sidebar (exact Tauri layout)
                SidebarView(
                    currentView: $model.currentNavSection,
                    onOpenSearchPalette: { model.paletteOpen = true }
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
                    // The detail page replaces the section, inside the
                    // content column. It is not a window-wide overlay: the
                    // sidebar stays visible and stays navigable, which is what
                    // the web build does by rendering it inside <main>.
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
                        .transition(.opacity)
                    } else {
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
                                    Task { await model.signIn(token: token) }
                                },
                                onDisconnectAniList: {
                                    model.signOut()
                                }
                            )
                        case .library:
                            LibraryView(
                                items: model.libraryItems,
                                isLoading: model.isLoading,
                                status: Binding(
                                    get: { model.libraryStatus },
                                    set: { next in Task { await model.loadLibrary(status: next) } }
                                ),
                                mediaType: Binding(
                                    get: { model.libraryType },
                                    set: { next in Task { await model.loadLibrary(type: next) } }
                                ),
                                isSignedIn: model.isSignedIn,
                                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL) }
                            )
                        case .manga:
                            ReadingView(
                                config: .manga,
                                reading: model.mangaReading,
                                trending: model.mangaTrending,
                                isSignedIn: model.isSignedIn,
                                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL) },
                                onRead: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL) },
                                onBrowse: { model.currentNavSection = .search }
                            )
                        case .novels:
                            ReadingView(
                                config: .novels,
                                reading: model.novelReading,
                                trending: model.novelTrending,
                                isSignedIn: model.isSignedIn,
                                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL) },
                                onRead: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL) },
                                onBrowse: { model.currentNavSection = .search }
                            )
                        case .history:
                            HistoryView(
                                viewer: model.viewer,
                                activity: model.activity,
                                titles: model.knownTitles
                            )
                        case .downloads:
                            DownloadsView()
                        }
                        }
                    }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .ignoresSafeArea()

            // Command palette. Above the detail page and below the player:
            // it navigates the app, and the player is modal over all of it.
            if model.paletteOpen {
                CommandPalette(commands: paletteCommands) {
                    model.paletteOpen = false
                }
                .zIndex(25)
                .transition(.opacity)
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
            VStack(alignment: .leading, spacing: 40) {
                // Up Next Section Header
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .bottom) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Up Next")
                                .font(.system(size: 19, weight: .semibold))
                                .tracking(-0.3)
                                .foregroundColor(SumiTheme.foreground)

                            if !model.upNextItems.isEmpty {
                                Text(upNextSubtitle)
                                    .sumiTabularMono(size: 11.5)
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
                            // Hairline only, no fill: the web button is
                            // `border border-border` over the page ground. A
                            // filled version reads as a macOS push button and
                            // outweighs the "Resume" control below it, which
                            // is the one thing on this screen meant to be
                            // primary.
                            Text("Pick for me")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SumiTheme.foreground.opacity(0.7))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                                .overlay(
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
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
            // `px-6 lg:px-10 pt-10 pb-8` on the web's scroll container, and
            // `max-w-[1100px]` on the page inside it. Without the cap the
            // shelves stretch the full window and the layout stops matching
            // at any width past ~1280.
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SumiTheme.background)
    }

    /// Every section, as a palette entry. The palette is the only navigation
    /// that reaches a section without the sidebar, so the list has to stay in
    /// step with `NavSection` — driving it off `allCases` is what keeps it
    /// there when a section is added.
    private var paletteCommands: [CommandPalette.Command] {
        SidebarView.NavSection.allCases.map { section in
            let model = self.model
            // `rawValue` rather than the enum case: the case is task-isolated
            // once it crosses into the @MainActor closure, and re-deriving it
            // from the string on the other side keeps the capture Sendable.
            let raw = section.rawValue
            return CommandPalette.Command(id: raw, label: "Go to \(section.label)") {
                Task { @MainActor in
                    guard let target = SidebarView.NavSection(rawValue: raw) else { return }
                    model.selectedMediaDetails = nil
                    model.currentNavSection = target
                }
            }
        }
    }

    /// "3 IN PROGRESS · 2 NEW EPISODES" — the count of new episodes is only
    /// appended when there are any, matching HomeView.tsx.
    private var upNextSubtitle: String {
        let inProgress = model.upNextItems.count
        let new = model.upNextItems.filter(\.hasNewEpisode).count
        var out = "\(inProgress) in progress"
        if new > 0 {
            out += " · \(new) new episode\(new == 1 ? "" : "s")"
        }
        return out
    }

    private func mediaRow(title: String, count: Int, items: [MediaCard.Item]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .bottom) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)

                Spacer()

                Text("\(count) shows")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(items) { item in
                        MediaCard(item: item) {
                            openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL)
                        }
                        .frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @available(*, deprecated, message: "Every section has a real view now.")
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

    /// Opens the detail page. The fabricated 28-episode stand-in this used
    /// to build is gone; the engine answers with the real entry.
    private func openDetailFor(id: Int64, title: String, coverURL: URL?, isManga: Bool = false) {
        Task { await model.openDetail(catalogId: id, isManga: isManga) }
    }

}
