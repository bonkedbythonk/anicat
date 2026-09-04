import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

public struct RootView: View {
    @Bindable public var model: AppModel
    @State private var showHomeCustomize = false
    @State private var showPicker = false
    #if os(macOS)
    // Only exit fullscreen on close if we're the one who entered it — if the
    // window was already fullscreen (user did it manually before pressing
    // play), leave it that way when the player closes.
    @State private var enteredFullscreenForPlayback = false
    #endif

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
                    currentView: Binding(
                        get: { model.currentNavSection },
                        set: { section in
                            // Mirror the web `handleNavigate`: closing the
                            // detail page is what lets a sidebar click switch
                            // sections while a title is open. Without it the
                            // detail view keeps rendering because its `if let
                            // details` branch wins over `currentNavSection`.
                            model.clearDetail()
                            model.currentNavSection = section
                        }
                    ),
                    onOpenSearchPalette: { model.paletteOpen = true }
                )
                .frame(width: 200)
                .layoutPriority(1)

                // Hairline Divider
                Rectangle()
                    .fill(SumiTheme.border)
                    .frame(width: 1)
                    .layoutPriority(1)
                    .ignoresSafeArea()

                // Dynamic Main Content Area
                VStack(spacing: 0) {
                    if model.isAniListDown {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(SumiTheme.warning)
                                .font(.system(size: 14))

                            Text("AniList is temporarily down — tracking and library sync are paused.")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(2)

                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                .stroke(SumiTheme.warning.opacity(0.5), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

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
                            characters: model.selectedCharacters,
                            relations: model.selectedRelations,
                            recommendations: model.selectedRecommendations,
                            discussions: model.selectedDiscussions,
                            onPlayEpisode: { ep in
                                Task {
                                    do {
                                        _ = try await model.resolveAndPlay(
                                            catalogId: details.id,
                                            episode: Int64(ep.number),
                                            title: details.title
                                        )
                                    } catch {
                                        model.errorMessage = "Failed to play episode \(ep.number): \(error.localizedDescription)"
                                    }
                                }
                            },
                            onReadChapter: { chapter in
                                Task {
                                    await model.openReader(
                                        title: details.title,
                                        chapter: chapter,
                                        allChapters: model.selectedMangaChapters,
                                        anilistId: details.id
                                    )
                                }
                            },
                            onSelectRelation: { rel in
                                openDetailFor(
                                    id: rel.id,
                                    title: rel.title,
                                    coverURL: rel.coverURL,
                                    isManga: rel.format == "MANGA" || rel.format == "NOVEL" || rel.format == "ONE_SHOT"
                                )
                            },
                            onSelectMediaId: { id, title, coverURL, isManga in
                                openDetailFor(
                                    id: id,
                                    title: title,
                                    coverURL: coverURL,
                                    isManga: isManga
                                )
                            },
                            onExportAppleBooks: {},
                            onClose: {
                                withAnimation(.smooth) {
                                    model.closeDetail()
                                }
                            },
                            onSetListStatus: { status in
                                Task { await model.updateListEntry(status: status) }
                            },
                            onToggleFavourite: {
                                Task { await model.toggleFavourite() }
                            },
                            onRemoveFromList: {
                                Task { await model.removeFromList() }
                            },
                            onSetEpisodeWatched: { episode, watched in
                                Task { await model.setEpisodeWatched(episode, watched: watched) }
                            },
                            onLoadReleaseCandidates: { episode in
                                await model.loadReleaseCandidates(episode: episode)
                            },
                            onPlayWithRelease: { ep, releaseName in
                                Task {
                                    do {
                                        _ = try await model.resolveAndPlay(
                                            catalogId: details.id,
                                            episode: Int64(ep.number),
                                            title: details.title,
                                            chosenName: releaseName
                                        )
                                    } catch {
                                        model.errorMessage = "Failed to play episode \(ep.number): \(error.localizedDescription)"
                                    }
                                }
                            },
                            onDownloadEpisode: { ep in
                                Task { await model.startDownload(episode: ep.number) }
                            },
                            downloadStates: model.downloadStates
                        )
                        .id(details.id)
                        .transition(.opacity)
                    } else {
                        sectionContent
                            .id(model.currentNavSection)
                            .transition(.opacity)
                    }
                    }
                    .animation(.smooth, value: model.currentNavSection)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()

            // Command palette. Above sections, player, and reader so navigation is accessible anywhere.
            if model.paletteOpen {
                CommandPalette(commands: paletteCommands) {
                    withAnimation(.easeIn(duration: 0.18)) {
                        model.paletteOpen = false
                    }
                }
                .zIndex(50)
                .transition(.opacity)
            }

            // Keyboard shortcuts overlay. Above palette and modal views.
            if model.shortcutsOpen {
                KeyboardShortcutsOverlay {
                    withAnimation(.easeIn(duration: 0.2)) {
                        model.shortcutsOpen = false
                    }
                }
                .zIndex(60)
                .transition(.opacity)
            }


            // In-App Video Player Overlay
            if let streamURL = model.activeStreamURL {
                PlayerView(
                    controller: model.playerController,
                    streamURL: streamURL,
                    onClose: {
                        withAnimation(.smooth) {
                            model.stopPlayback()
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(30)
            }

            // In-App Manga Reader Overlay
            if let session = model.activeReadingSession {
                MangaReaderView(
                    title: session.title,
                    chapterTitle: session.chapterTitle,
                    pageURLs: session.pageURLs,
                    onPageChanged: { page in
                        ContinuityManager.shared.advertiseReading(
                            mangaId: session.chapterId,
                            title: session.title,
                            chapter: session.chapterTitle,
                            pageIndex: page
                        )
                    },
                    onNextChapter: {
                        Task { await model.nextChapter() }
                    },
                    onPrevChapter: {
                        Task { await model.prevChapter() }
                    },
                    onClose: {
                        withAnimation(.smooth) {
                            model.closeReader()
                        }
                    }
                )
                .transition(.opacity)
                .zIndex(35)
            }

            // Error Toast
            if let error = model.errorMessage {
                VStack {
                    HStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(SumiTheme.warning)
                            .font(.system(size: 14))

                        Text(error)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)
                            .lineLimit(2)

                        Spacer()

                        Button(action: {
                            withAnimation(.easeIn(duration: 0.2)) {
                                model.errorMessage = nil
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(SumiTheme.muted)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.warning.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 12, y: 4)
                    .padding(.top, 44)
                    .padding(.horizontal, 24)

                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(60)
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
                .zIndex(70)
            }
        }
        .animation(.smooth, value: model.activeStreamURL != nil)
        .animation(.smooth, value: model.activeReadingSession != nil)
        .animation(.smooth, value: model.selectedMediaDetails != nil)
        .animation(.snappy, value: model.errorMessage != nil)
        .animation(.smooth, value: model.isAniListDown)
        .animation(.snappy, value: model.isLoading)
        .animation(.snappy, value: model.paletteOpen)
        .animation(.snappy, value: model.shortcutsOpen)
        .globalKeyboardShortcuts(model: model)
        #if os(macOS)
        // Driven off activeStreamURL's nil<->value edge rather than
        // PlayerView's onAppear/onDisappear: that view can be reused or
        // recreated across the transition (it's SwiftUI's call, not ours),
        // so its own appear/disappear isn't a reliable one-shot signal. This
        // edge is unambiguous and fires exactly once per playback session.
        .onChange(of: model.activeStreamURL != nil) { wasPlaying, isPlaying in
            guard let window = AppWindow.main else { return }
            if isPlaying, !wasPlaying, !window.styleMask.contains(.fullScreen) {
                enteredFullscreenForPlayback = true
                window.toggleFullScreen(nil)
            } else if !isPlaying, wasPlaying, enteredFullscreenForPlayback, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
                enteredFullscreenForPlayback = false
            }
        }
        #endif
    }

    // MARK: - Section Content Switcher
    @ViewBuilder
    private var sectionContent: some View {
        switch model.currentNavSection {
        case .upNext:
            homeView
        case .schedule:
            ScheduleView(items: model.scheduleItems) { item in
                openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: false)
            }
        case .search:
            SearchView(
                searchText: $model.searchQuery,
                results: model.searchResults,
                discoverItems: model.trendingItems,
                isLoading: model.isLoading,
                onSearchCommit: { q, mediaType, filters in
                    Task { await model.search(query: q, mediaType: mediaType, filters: filters) }
                },
                onSelectMedia: { item in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga)
                },
                onLoadDiscover: {
                    Task { await model.loadTrending() }
                },
                onShuffle: {
                    Task { await model.loadTrending() }
                }
            )
        case .settings:
            SettingsView(
                isSignedIn: model.isSignedIn,
                username: model.viewer?.name,
                onSaveToken: { token in
                    Task { await model.signIn(token: token) }
                },
                onDisconnectAniList: {
                    model.signOut()
                },
                onClearRegistry: {
                    await model.clearLocalRegistry()
                },
                onOpenShortcuts: {
                    model.shortcutsOpen = true
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
                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: model.libraryType == "MANGA" || $0.isManga) }
            )
        case .manga:
            ReadingView(
                config: .manga,
                reading: model.mangaReading,
                trending: model.mangaTrending,
                isSignedIn: model.isSignedIn,
                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true) },
                onRead: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true) },
                onBrowse: { model.currentNavSection = .search }
            )
        case .novels:
            ReadingView(
                config: .novels,
                reading: model.novelReading,
                trending: model.novelTrending,
                isSignedIn: model.isSignedIn,
                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true) },
                onRead: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true) },
                onBrowse: { model.currentNavSection = .search }
            )
        case .history:
            HistoryView(
                viewer: model.viewer,
                activity: model.activity,
                titles: model.knownTitles,
                onSelectFavourite: { item in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga)
                }
            )
        case .downloads:
            DownloadsView()
        }
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
                        Button(action: { showPicker = true }) {
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
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        // Reorders/hides the configurable rows below. Shown
                        // even signed-out, same as HomeView.tsx: Trending,
                        // Newly Releasing and Seasonal all work without a
                        // token, only Planning needs one.
                        Button(action: { showHomeCustomize = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "square.grid.2x2")
                                    .font(.system(size: 11))
                                Text("Customize")
                                    .font(.system(size: 12, weight: .medium))
                            }
                            .foregroundColor(SumiTheme.foreground.opacity(0.7))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                            .overlay(
                                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                    .stroke(SumiTheme.border, lineWidth: 1)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Up Next Queue Container
                    if !model.upNextItems.isEmpty {
                        UpNextQueueView(
                            items: model.upNextItems,
                            onSelect: { entry in
                                openDetailFor(id: entry.id, title: entry.title, coverURL: entry.thumbnailURL, isManga: entry.unit == "CH")
                            },
                            onPlay: { entry in
                                if entry.unit == "CH" {
                                    openDetailFor(id: entry.id, title: entry.title, coverURL: entry.thumbnailURL, isManga: true)
                                } else {
                                    Task {
                                        do {
                                            _ = try await model.resolveAndPlay(
                                                catalogId: entry.id,
                                                episode: Int64(entry.nextEpisodeOrChapter),
                                                title: entry.title
                                            )
                                        } catch {
                                            model.errorMessage = "Failed to play episode \(entry.nextEpisodeOrChapter): \(error.localizedDescription)"
                                        }
                                    }
                                }
                            }
                        )
                    } else {
                        // Mirrors HomeView.tsx: an empty queue states the absence
                        // plainly rather than leaving the "Up Next" heading over
                        // nothing. 15pt semibold headline, 13pt muted detail.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Nothing in progress")
                                .font(.system(size: 15, weight: .semibold))
                                .tracking(-0.2)
                                .foregroundColor(SumiTheme.foreground)
                            Text("Pick something from your library and it shows up here.")
                                .font(.system(size: 13))
                                .foregroundColor(SumiTheme.muted)
                        }
                        .padding(.horizontal, 4)
                    }
                }

                if !model.scheduleItems.filter({ $0.isWatching }).isEmpty {
                    WeekStrip(items: model.scheduleItems) { item in
                        openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: false)
                    }
                }

                // Watching is fixed, not configurable — same split as
                // HomeView.tsx (queue + Watching are the front page; the rest
                // are rows the user can reorder or hide).
                if !model.watchingItems.isEmpty {
                    mediaRow(title: "Watching", count: model.watchingItems.count, items: model.watchingItems)
                } else if model.isSignedIn && model.isLoading {
                    MediaRowSkeleton(title: "Watching")
                }

                // Configurable rows, in the user's saved order; hidden ones
                // are skipped entirely rather than shown collapsed.
                ForEach(model.homeRowConfig.filter(\.visible)) { row in
                    homeDiscoverRow(id: row.id, title: row.title)
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
        .sheet(isPresented: $showHomeCustomize) {
            HomeCustomizeSheet(model: model, isPresented: $showHomeCustomize)
        }
        .sheet(isPresented: $showPicker) {
            PickerSheet(
                model: model,
                isPresented: $showPicker,
                onCommit: { item in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga)
                }
            )
        }
    }

    /// One configurable row, by id. Skeletons preserve the shelf layout
    /// while queries are in flight, preventing sudden reflows.
    @ViewBuilder
    private func homeDiscoverRow(id: String, title: String) -> some View {
        switch id {
        case "planning":
            if model.isSignedIn {
                if !model.planningItems.isEmpty {
                    mediaRow(title: title, count: model.planningItems.count, items: model.planningItems)
                } else if model.isLoading {
                    MediaRowSkeleton(title: title)
                }
            }
        case "smartPlaylist":
            if model.isSignedIn {
                if !model.smartPicks.isEmpty {
                    mediaRow(title: title, count: model.smartPicks.count, items: model.smartPicks)
                } else if model.isLoading {
                    MediaRowSkeleton(title: title)
                }
            }
        case "trending":
            if !model.trendingItems.isEmpty {
                mediaRow(title: title, count: model.trendingItems.count, items: model.trendingItems)
            } else if model.isLoading {
                MediaRowSkeleton(title: title)
            }
        case "newlyReleasing":
            if !model.newlyReleasingItems.isEmpty {
                mediaRow(title: title, count: model.newlyReleasingItems.count, items: model.newlyReleasingItems)
            } else if model.isLoading {
                MediaRowSkeleton(title: title)
            }
        case "seasonal":
            if !model.seasonalItems.isEmpty {
                mediaRow(title: title, count: model.seasonalItems.count, items: model.seasonalItems)
            } else if model.isLoading {
                MediaRowSkeleton(title: title)
            }
        default:
            EmptyView()
        }
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
                    model.navigate(to: target)
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
                            openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga)
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

    /// Opens the detail page, querying the Rust core via UniFFI.
    private func openDetailFor(id: Int64, title: String, coverURL: URL?, isManga: Bool = false) {
        Task { await model.openDetail(id: id, isManga: isManga) }
    }

}

#if os(macOS)
import AppKit

private struct GlobalKeyboardShortcutsModifier: ViewModifier {
    @Bindable var model: AppModel
    @State private var monitor: Any?
    @State private var scrollMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var accumulatedDeltaX: CGFloat = 0
    @State private var accumulatedDeltaY: CGFloat = 0
    @State private var gestureSampleCount = 0
    @State private var gestureDisqualified = false
    @State private var isCooling = false
    @State private var lastSwipeEventAt: Date = .distantPast

    func body(content: Content) -> some View {
        content
            .onAppear {
                setupMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func setupMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
        // Mirrors App.tsx's trackpad-back handler: horizontal-dominance guard
        // against vertical scroll, and the same cooldown-until-idle (not a
        // fixed timer) so one physical swipe's inertial tail can't re-cross
        // the threshold and pop a second level.
        //
        // Sign is positive, not negative like the web's deltaX: AppKit's
        // `scrollingDeltaX` already reflects the user's Natural Scrolling
        // trackpad setting, so which physical swipe direction lands negative
        // depends on that preference rather than matching the browser's
        // convention. Confirmed against the real gesture — negative fired on
        // the forward swipe and did nothing on back.
        //
        // A pure vertical scroll still tripped this on this input device: the
        // dominance ratio alone isn't enough, because ordinary vertical
        // scrolling here carries a horizontal component large enough to keep
        // clearing a purely relative (dx > 2*dy) check for several samples in
        // a row, not just a one-sample startup blip. `gestureSampleCount`
        // withholds the check for the first couple of samples so a genuine
        // horizontal swipe (which stays horizontal) can still separate from a
        // vertical scroll's noisy opening; `gestureDisqualified` is the harder
        // guard — once a gesture has shown any real vertical travel it can
        // never fire "back" for the rest of that gesture, even if dx spikes
        // later, because a real swipe-back gesture has near-zero vertical
        // travel throughout, not just a favorable ratio at one instant. An
        // idle gap (trackpad momentum doesn't reliably send `.ended`) starts
        // a fresh gesture.
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [self] event in
            guard model.selectedMediaDetails != nil else { return event }
            let now = Date()
            if isCooling {
                if now.timeIntervalSince(lastSwipeEventAt) > 0.12 {
                    isCooling = false
                } else {
                    lastSwipeEventAt = now
                    return event
                }
            }
            if now.timeIntervalSince(lastSwipeEventAt) > 0.15 {
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                gestureSampleCount = 0
                gestureDisqualified = false
            }
            lastSwipeEventAt = now
            accumulatedDeltaX += event.scrollingDeltaX
            accumulatedDeltaY += abs(event.scrollingDeltaY)
            gestureSampleCount += 1
            if accumulatedDeltaY > 15 {
                gestureDisqualified = true
            }
            if !gestureDisqualified && gestureSampleCount >= 3 && accumulatedDeltaX > 60 && abs(accumulatedDeltaX) > accumulatedDeltaY * 2 {
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                gestureSampleCount = 0
                isCooling = true
                withAnimation(.smooth) {
                    model.closeDetail()
                }
                return nil
            }
            if event.phase == .ended {
                accumulatedDeltaX = 0
                accumulatedDeltaY = 0
                gestureSampleCount = 0
                gestureDisqualified = false
            }
            return event
        }
        // Button 3 is the standard back side-button on 5-button mice in AppKit (0=left, 1=right, 2=middle).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [self] event in
            if event.buttonNumber == 3 && model.selectedMediaDetails != nil {
                withAnimation(.smooth) {
                    model.closeDetail()
                }
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if let m = scrollMonitor {
            NSEvent.removeMonitor(m)
            scrollMonitor = nil
        }
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let isCmd = event.modifierFlags.contains(.command)
        let isCtrl = event.modifierFlags.contains(.control)
        let isAlt = event.modifierFlags.contains(.option)
        let isShift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let rawChars = event.characters ?? ""

        // 1. Cmd+K: Toggle Command Palette (even while typing)
        if isCmd && !isCtrl && !isAlt && chars == "k" {
            withAnimation(.snappy) {
                model.paletteOpen.toggle()
            }
            return nil
        }

        // 2. ESC key (keyCode 53):
        // Order of dismissal:
        // 1. KeyboardShortcutsOverlay (topmost help modal)
        // 2. CommandPalette (topmost overlay)
        // 3. PlayerView (modal video overlay)
        // 4. MangaReaderView (modal reader overlay)
        // 5. MediaDetailView (detail page)
        if event.keyCode == 53 {
            var handled = false
            withAnimation(.smooth) {
                handled = model.handleEscapeKey()
            }
            return handled ? nil : event
        }

        // Arrow keys in AppKit automatically include `.numericPad` and `.function`
        // flags, so we exclude explicit modifiers instead of checking a raw flag mask.
        if isAlt && !isCmd && !isCtrl && !isShift && event.keyCode == 123 && model.selectedMediaDetails != nil {
            withAnimation(.smooth) {
                model.closeDetail()
            }
            return nil
        }

        // Guard: Don't intercept single-key navigation when typing in an input field
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField || responder is NSText {
            return event
        }

        // 3. '?': Toggle Keyboard Shortcuts overlay
        if !isCmd && !isCtrl && !isAlt && (rawChars == "?" || chars == "?") {
            withAnimation(.snappy) {
                model.shortcutsOpen.toggle()
            }
            return nil
        }

        // 4. Player-specific shortcuts when PlayerView is active
        if model.activeStreamURL != nil && !isCmd && !isCtrl && !isAlt {
            // Spacebar: play / pause
            if event.keyCode == 49 {
                model.playerController.togglePlayPause()
                return nil
            }
            // Left arrow: seek -10s
            if event.keyCode == 123 {
                model.playerController.seekRelative(by: -10)
                return nil
            }
            // Right arrow: seek +10s
            if event.keyCode == 124 {
                model.playerController.seekRelative(by: 10)
                return nil
            }
        }

        // 5. Navigation shortcuts (only when no modifier keys are held)
        if !isCmd && !isCtrl && !isAlt {
            // '/': Open Command Palette / focus search
            if chars == "/" {
                withAnimation(.snappy) {
                    model.paletteOpen = true
                }
                return nil
            }

            // Numbers 1-9: Switch views
            if let num = Int(chars), let targetSection = SidebarView.NavSection.fromNumberKey(num) {
                withAnimation(.smooth) {
                    model.navigate(to: targetSection)
                }
                return nil
            }

            // Letter shortcuts: H (Home/Up Next), L (Library), M (Manga), N (Novels), D (Downloads)
            if let firstChar = chars.first, let targetSection = SidebarView.NavSection.fromLetterKey(firstChar) {
                withAnimation(.smooth) {
                    model.navigate(to: targetSection)
                }
                return nil
            }
        }

        return event
    }
}
#endif

extension View {
    fileprivate func globalKeyboardShortcuts(model: AppModel) -> some View {
        #if os(macOS)
        self.modifier(GlobalKeyboardShortcutsModifier(model: model))
        #else
        self
        #endif
    }
}

/// Reorder/hide the home page's configurable rows — mirrors the "Customize
/// home" modal in HomeView.tsx: arrows to move, an eye to toggle visibility,
/// order is the list order itself.
private struct HomeCustomizeSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundColor(SumiTheme.indigo)
                    Text("Customize home")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(SumiTheme.foreground)
                }
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            Text("Reorder with the arrows, show or hide with the eye.")
                .font(.system(size: 11))
                .foregroundColor(SumiTheme.muted)
                .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(Array(model.homeRowConfig.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(row.visible ? SumiTheme.foreground : SumiTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(action: { model.moveHomeRow(at: index, by: -1) }) {
                            Image(systemName: "chevron.up")
                                .foregroundColor(index == 0 ? SumiTheme.muted.opacity(0.3) : SumiTheme.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == 0)

                        Button(action: { model.moveHomeRow(at: index, by: 1) }) {
                            Image(systemName: "chevron.down")
                                .foregroundColor(index == model.homeRowConfig.count - 1 ? SumiTheme.muted.opacity(0.3) : SumiTheme.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(index == model.homeRowConfig.count - 1)

                        Button(action: { model.toggleHomeRow(id: row.id) }) {
                            Image(systemName: row.visible ? "eye" : "eye.slash")
                                .foregroundColor(row.visible ? SumiTheme.indigo : SumiTheme.muted.opacity(0.5))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(SumiTheme.card.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(SumiTheme.background)
    }
}
