#if os(iOS)
import SwiftUI

/// The iPhone root, in place of `RootView`'s 200pt sidebar rail.
///
/// Not a narrower `RootView`: the rail is a list of ten sections, and a phone
/// reaches for four of them. Anime only, and no Downloads tab — a phone fills
/// up long before a Mac does, so streaming is the whole story here and the
/// engine's cache is the only thing that touches storage.
///
/// The rail's other sections (Manga, Light Novels, Schedule, Stats, History)
/// are not hidden behind a "more" tab; they are absent. Adding one means
/// designing it for touch first.
public struct RootTabView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    enum Tab: Hashable {
        case upNext, library, search
    }

    @State private var tab: Tab = .upNext

    public var body: some View {
        ZStack {
            TabView(selection: $tab) {
                UpNextTab(model: model)
                    .tabItem { Label("Up Next", systemImage: "play.circle") }
                    .tag(Tab.upNext)

                LibraryTab(model: model)
                    .tabItem { Label("Library", systemImage: "rectangle.stack") }
                    .tag(Tab.library)

                SearchTab(model: model)
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)
            }

            // One call site, outside the TabView, and deliberately not inside
            // `if !model.isPlayerMinimized`. `MpvSurface`'s dismantle path
            // stops playback, so a player mounted per-tab would be torn down
            // and the episode killed by switching tabs — the same failure
            // `RootView` records for the minimize branch on macOS.
            if let streamURL = model.activeStreamURL {
                PlayerView(
                    controller: model.playerController,
                    streamURL: streamURL,
                    onClose: {
                        withAnimation(.smooth) { model.stopPlayback() }
                    },
                    onMinimize: { model.isPlayerMinimized = true },
                    isMinimized: model.isPlayerMinimized,
                    onRestore: { model.isPlayerMinimized = false },
                    morphSource: nil,
                    morphThumbnailURL: nil
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(30)
            }
        }
        .tint(SumiTheme.indigo)
    }
}

// MARK: - Up Next

private struct UpNextTab: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !model.upNextItems.isEmpty {
                        ContinueWatchingRow(model: model)
                    }

                    let newEpisodes = model.upNextItems.filter(\.hasNewEpisode)
                    if !newEpisodes.isEmpty {
                        SectionHeader("New Episodes")
                        VStack(spacing: 0) {
                            ForEach(newEpisodes) { entry in
                                NewEpisodeRow(entry: entry) {
                                    open(entry.id, entry.title, entry.thumbnailURL)
                                }
                                Divider().overlay(SumiTheme.border)
                            }
                        }
                    }

                    if model.upNextItems.isEmpty {
                        EmptyHint(
                            title: "Nothing in progress",
                            detail: "Titles you are watching on AniList show up here."
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .background(SumiTheme.background)
            .navigationTitle("Up Next")
            .refreshable { await model.refreshAll() }
        }
    }

    private func open(_ id: Int64, _ title: String, _ cover: URL?) {
        Task { await model.openDetail(id: id, title: title, coverURL: cover) }
    }
}

private struct ContinueWatchingRow: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.upNextItems) { entry in
                        Button {
                            // Chapters have no player to open; the reader
                            // lives on the detail page.
                            if entry.unit == "CH" {
                                Task {
                                    await model.openDetail(
                                        id: entry.id, title: entry.title,
                                        coverURL: entry.thumbnailURL, isManga: true
                                    )
                                }
                            } else {
                                playFromShelf(
                                    model: model,
                                    catalogId: entry.id,
                                    episode: entry.nextEpisodeOrChapter,
                                    title: entry.title,
                                    coverURL: entry.thumbnailURL
                                )
                            }
                        } label: {
                            ContinueWatchingCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

private struct ContinueWatchingCard: View {
    let entry: UpNextQueueView.QueueEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottom) {
                CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 480) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: 172, height: 97)
                .clipped()

                GeometryReader { geo in
                    Rectangle()
                        .fill(SumiTheme.indigo)
                        .frame(width: geo.size.width * entry.progressPercent / 100, height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
                .frame(height: 3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Text(entry.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(SumiTheme.foreground)
                .lineLimit(1)
            Text("\(entry.unit) \(entry.nextEpisodeOrChapter) · \(Int(100 - entry.progressPercent))% LEFT")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(SumiTheme.muted)
                .lineLimit(1)
        }
        .frame(width: 172, alignment: .leading)
    }
}

private struct NewEpisodeRow: View {
    let entry: UpNextQueueView.QueueEntry
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 200) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 15))
                        .foregroundStyle(SumiTheme.foreground)
                        .lineLimit(1)
                    Text("\(entry.unit) \(entry.nextEpisodeOrChapter) OUT\(entry.watchedTimeAgo.map { " · \($0.uppercased())" } ?? "")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SumiTheme.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Library

private struct LibraryTab: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    PosterSection(title: "Watching", items: model.watchingItems, model: model)
                    PosterSection(title: "Planning", items: model.planningItems, model: model)

                    if model.watchingItems.isEmpty && model.planningItems.isEmpty {
                        EmptyHint(
                            title: "No lists yet",
                            detail: "Connect AniList in Settings to see your library."
                        )
                    }
                }
                .padding(.vertical, 8)
            }
            .background(SumiTheme.background)
            .navigationTitle("Library")
            .refreshable { await model.refreshAll() }
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @Bindable var model: AppModel
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.searchResults.isEmpty {
                        PosterSection(title: "Trending", items: model.trendingItems, model: model)
                    } else {
                        PosterGrid(items: model.searchResults, model: model)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(SumiTheme.background)
            .navigationTitle("Search")
            // `.searchable` gives the system field, Cancel button and the
            // scroll-to-reveal behaviour for free. The desktop's command
            // palette has no iOS counterpart and is not reproduced.
            .searchable(text: $query, prompt: "Search anime")
            // Search on submit rather than on every keystroke: AniList is
            // rate-limited per minute and a per-character search burns the
            // budget on prefixes nobody asked for.
            .onSubmit(of: .search) {
                Task { await model.search(query: query) }
            }
            .onChange(of: query) { _, new in
                if new.isEmpty {
                    Task { await model.search(query: "") }
                }
            }
        }
    }
}

// MARK: - Shared pieces

private struct PosterSection: View {
    let title: String
    let items: [MediaCard.Item]
    @Bindable var model: AppModel

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title)
                PosterGrid(items: items, model: model)
            }
        }
    }
}

private struct PosterGrid: View {
    let items: [MediaCard.Item]
    @Bindable var model: AppModel

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                Button {
                    Task {
                        await model.openDetail(
                            id: item.id, title: item.title, coverURL: item.coverImageURL
                        )
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 360) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            SumiTheme.card
                        }
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        Text(item.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SumiTheme.foreground)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
    }
}

private struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(SumiTheme.foreground)
            .padding(.horizontal, 16)
    }
}

private struct EmptyHint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SumiTheme.foreground)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(SumiTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 32)
        .padding(.top, 64)
    }
}
#endif
