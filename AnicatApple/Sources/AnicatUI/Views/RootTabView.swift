#if os(iOS)
import SwiftUI

/// The iPhone root, in place of `RootView`'s 200pt sidebar rail.
///
/// Not a narrower `RootView`: the rail is a list of ten sections, and a phone
/// reaches for three of them. Anime only, and no Downloads tab — a phone fills
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
    /// One flag, not one per tab: a deep link can open a title while any tab
    /// is showing, and three independent flags meant the push landed on
    /// whichever tab happened to own the one that was set.
    @State private var showDetail = false

    public var body: some View {
        ZStack {
            TabView(selection: $tab) {
                UpNextTab(model: model, showDetail: scoped(to: .upNext))
                    .tabItem { Label("Up Next", systemImage: "play.circle") }
                    .tag(Tab.upNext)

                LibraryTab(model: model, showDetail: scoped(to: .library))
                    .tabItem { Label("Library", systemImage: "rectangle.stack") }
                    .tag(Tab.library)

                SearchTab(model: model, showDetail: scoped(to: .search))
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
                // A video is a landscape object on a device that starts
                // portrait. Rotating the window rather than asking the user
                // to turn the phone is what every other player on iOS does.
                .modifier(PlayerOrientation(active: !model.isPlayerMinimized))
            }
        }
        .tint(SumiTheme.indigo)
    }

    /// The shared flag, readable only by the tab currently on screen. Without
    /// the `tab ==` guard all three stacks push the same page, and coming
    /// back to a tab you had left showed a detail page you never opened there.
    private func scoped(to owner: Tab) -> Binding<Bool> {
        Binding(
            get: { tab == owner && showDetail },
            set: { showDetail = $0 }
        )
    }
}

// MARK: - Detail push

/// Pushes `PhoneDetailView` when this tab asks for a title.
///
/// The flag is per tab and set at tap time, not when the fetch lands:
/// `openDetail` is async, so binding the push to `selectedMediaDetails`
/// instead would leave the tap dead for as long as AniList takes to answer.
/// Clearing the model is driven off the flag going false — doing it in the
/// page's `onDisappear` also fired on a tab switch, which emptied the page
/// still pushed on the tab being left.
private struct DetailPush: ViewModifier {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isPresented) {
                PhoneDetailView(model: model)
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { model.closeDetail() }
            }
            // A deep link (`anicat://title/<id>`) and a notification tap both
            // go straight to `openDetail` on the model, with no tap on any
            // row to have set the flag. Without this the page loaded into a
            // model nothing was showing.
            .onChange(of: model.selectedMediaDetails?.id) { _, id in
                if id != nil { isPresented = true }
            }
    }
}

// MARK: - Up Next

private struct UpNextTab: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !model.upNextItems.isEmpty {
                        ContinueWatchingRow(model: model, onOpen: open)
                    }

                    let newEpisodes = model.upNextItems.filter(\.hasNewEpisode)
                    if !newEpisodes.isEmpty {
                        SectionHeader("New Episodes")
                        VStack(spacing: 0) {
                            ForEach(newEpisodes) { entry in
                                NewEpisodeRow(entry: entry) {
                                    open(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH")
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
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    private func open(_ id: Int64, _ title: String, _ cover: URL?, _ isManga: Bool) {
        showDetail = true
        Task { await model.openDetail(id: id, title: title, coverURL: cover, isManga: isManga) }
    }
}

private struct ContinueWatchingRow: View {
    @Bindable var model: AppModel
    let onOpen: (Int64, String, URL?, Bool) -> Void

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
                                onOpen(entry.id, entry.title, entry.thumbnailURL, true)
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

                // See PhoneDetailView.EpisodeRow: `lineLimit` truncates the
                // drawing, not the layout, so an unframed title widens the
                // row and shifts the whole column off screen.
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.title)
                        .font(.system(size: 15))
                        .foregroundStyle(SumiTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text("\(entry.unit) \(entry.nextEpisodeOrChapter) OUT\(entry.watchedTimeAgo.map { " · \($0.uppercased())" } ?? "")")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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
    @Binding var showDetail: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    PosterSection(title: "Watching", items: model.watchingItems, onOpen: open)
                    PosterSection(title: "Planning", items: model.planningItems, onOpen: open)

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
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    private func open(_ item: MediaCard.Item) {
        showDetail = true
        Task {
            await model.openDetail(
                id: item.id, title: item.title,
                coverURL: item.coverImageURL, isManga: item.isManga
            )
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool
    @State private var query = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.searchResults.isEmpty {
                        PosterSection(title: "Trending", items: model.trendingItems, onOpen: open)
                    } else {
                        PosterGrid(items: model.searchResults, onOpen: open)
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
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    private func open(_ item: MediaCard.Item) {
        showDetail = true
        Task {
            await model.openDetail(
                id: item.id, title: item.title,
                coverURL: item.coverImageURL, isManga: item.isManga
            )
        }
    }
}

// MARK: - Player orientation

/// Turns the window to landscape while a video is on screen, and lets it go
/// again when the player closes or minimizes.
///
/// `requestGeometryUpdate` rather than a `supportedInterfaceOrientations`
/// override: the app is one SwiftUI scene with no view controller of its own
/// to override, and the Info.plist has to go on listing portrait for the
/// three tabs. The error handler is required by the API and deliberately
/// empty — iPad multitasking and Stage Manager refuse the request, and the
/// right answer there is the player keeping whatever shape the window has.
private struct PlayerOrientation: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .onAppear { apply(.landscape) }
            .onDisappear { apply(.portrait) }
            .onChange(of: active) { _, playing in
                apply(playing ? .landscape : .portrait)
            }
    }

    private func apply(_ mask: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }
}

// MARK: - Shared pieces

private struct PosterSection: View {
    let title: String
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title)
                PosterGrid(items: items, onOpen: onOpen)
            }
        }
    }
}

private struct PosterGrid: View {
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                Button {
                    onOpen(item)
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
