#if os(tvOS)
import SwiftUI

/// The Apple TV root, in place of `RootView`'s sidebar rail and the phone's
/// `RootTabView`.
///
/// Neither of those survives the trip. The Mac root assumes a pointer (hover
/// reveals, a 200pt rail of ten sections, a command palette); the phone
/// root assumes a thumb (pull to refresh, a drag-to-scrub player, a remote
/// control sheet for driving a Mac). A television has a Siri Remote and a
/// viewer three metres away: everything is reached by moving focus, text
/// entry is a chore, and the one thing the screen is for is playing video
/// at full size. So this is the phone's shape -- Up Next, Library, Search,
/// Settings -- rebuilt around focus, with posters the size the room needs.
///
/// Anime and cinema only. Manga, light novels, Schedule, Stats and History
/// are absent rather than hidden: a reader on a TV is not a thing anyone
/// asked for, and the rest need a touch or pointer layout first.
public struct TVRootView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    enum Tab: Hashable {
        case upNext, library, search, settings
    }

    @State private var tab: Tab = .upNext
    /// Which tab the open detail page belongs to, if any. See
    /// `RootTabView.detailOwner` for why this is an owner and not a flag:
    /// switching tabs must not read as a dismissal on the tab being left.
    @State private var detailOwner: Tab?

    public var body: some View {
        ZStack {
            TabView(selection: $tab) {
                UpNextTab(model: model, showDetail: scoped(to: .upNext))
                    .tabItem { Text("Up Next") }
                    .tag(Tab.upNext)

                LibraryTab(model: model, showDetail: scoped(to: .library))
                    .tabItem { Text("Library") }
                    .tag(Tab.library)

                SearchTab(model: model, showDetail: scoped(to: .search))
                    .tabItem { Text("Search") }
                    .tag(Tab.search)

                NavigationStack {
                    TVSettingsView(model: model)
                }
                .tabItem { Text("Settings") }
                .tag(Tab.settings)
            }
            // While the player is up, nothing under it may take focus: the
            // tab bar sits at the top of the screen and a stray swipe up
            // would land on it, behind the picture, and start switching
            // tabs under a playing episode.
            .disabled(model.activeStreamURL != nil)
            .opacity(model.activeStreamURL != nil ? 0 : 1)

            // One call site, outside the TabView, and not inside an `if` per
            // tab: `MpvSurface`'s dismantle path stops playback, so a player
            // mounted per tab would be torn down by a tab switch. Same rule
            // as `RootView` and `RootTabView`.
            if let streamURL = model.activeStreamURL {
                TVPlayerView(
                    controller: model.playerController,
                    streamURL: streamURL,
                    onClose: {
                        withAnimation(.smooth) { model.stopPlayback() }
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(30)
            }

            // "Finding a stream", with a Cancel that can take focus. Above
            // the player's zIndex, and only mounted while it has something
            // to say, like the desktop's own card.
            if let startedAt = model.resolveStartedAt {
                VStack {
                    Spacer()
                    TVResolvingCard(startedAt: startedAt, status: model.playerController.resolveStatus) {
                        model.cancelResolve()
                    }
                    .padding(.bottom, 60)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(40)
            }
        }
        .animation(.snappy, value: model.resolveStartedAt)
        .animation(.smooth, value: model.activeStreamURL)
        .background(SumiTheme.background.ignoresSafeArea())
        // A deep link straight to `openDetail` has no tab that claimed it;
        // the visible one takes the page. `detailOwner == nil` so it does
        // not steal a page a press has already opened elsewhere.
        .onChange(of: model.selectedMediaDetails?.id) { _, id in
            if id != nil, detailOwner == nil { detailOwner = tab }
        }
    }

    private func scoped(to owner: Tab) -> Binding<Bool> {
        Binding(
            get: { detailOwner == owner },
            set: { presented in
                if presented {
                    detailOwner = owner
                } else if detailOwner == owner {
                    detailOwner = nil
                }
            }
        )
    }
}

// MARK: - Metrics

/// The sizes the television layout is drawn at. A 1920x1080 point canvas
/// viewed from across a room: posters four times the phone's area, type at
/// least 24pt, and gutters wide enough that the focus lift on one card
/// never covers its neighbour.
enum TVMetrics {
    static let posterWidth: CGFloat = 220
    static let posterHeight: CGFloat = 330
    static let thumbWidth: CGFloat = 320
    static let thumbHeight: CGFloat = 180
    static let gutter: CGFloat = 80
    static let shelfSpacing: CGFloat = 40
    static let rowSpacing: CGFloat = 56
}

// MARK: - Mode toggle

/// Anime or cinema, in the header of the three browsing tabs. Hidden when
/// the engine has no TMDB access, same as on the phone.
private struct ModeToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.cinemaAvailable {
            Picker("", selection: Binding(
                get: { model.appMode },
                set: { model.setAppMode($0) }
            )) {
                Text("Anime").tag(AppModel.AppMode.anime)
                Text("Films & TV").tag(AppModel.AppMode.cinema)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 420)
        }
    }
}

private struct TabHeader: View {
    let title: String
    var model: AppModel?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.sumiHeading(size: 46, weight: .bold))
                .foregroundStyle(SumiTheme.foreground)
            Spacer(minLength: 40)
            if let model {
                ModeToggle(model: model)
            }
        }
        .padding(.horizontal, TVMetrics.gutter)
        .padding(.top, 8)
    }
}

// MARK: - Detail push

/// Pushes `TVDetailView` when this tab asks for a title. The flag is set at
/// press time, not when the fetch lands, so the push is immediate and the
/// page shows its own spinner while AniList answers.
private struct DetailPush: ViewModifier {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isPresented) {
                TVDetailView(model: model)
            }
            .onChange(of: isPresented) { _, presented in
                if !presented { model.closeDetail() }
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
                LazyVStack(alignment: .leading, spacing: TVMetrics.rowSpacing) {
                    TabHeader(title: "Up Next", model: model)

                    if model.appMode == .cinema {
                        cinemaBody
                    } else {
                        if !model.upNextItems.isEmpty {
                            ContinueWatchingShelf(model: model, onOpen: open)
                        }

                        let newEpisodes = model.upNextItems.filter(\.hasNewEpisode)
                        if !newEpisodes.isEmpty {
                            NewEpisodesShelf(entries: newEpisodes) { entry in
                                open(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH")
                            }
                        }

                        TVPosterShelf(title: "Because You Watched", items: model.becauseYouWatched, onOpen: open)
                        TVPosterShelf(title: "This Season", items: model.seasonalItems, onOpen: open)
                        TVPosterShelf(title: "Trending", items: model.trendingItems, onOpen: open)
                        TVPosterShelf(title: "Planning", items: model.planningItems, onOpen: open)

                        if model.upNextItems.isEmpty && model.trendingItems.isEmpty {
                            if model.isLoading {
                                ProgressView()
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 120)
                            } else {
                                TVEmptyHint(
                                    title: "Nothing in progress",
                                    detail: "Titles you are watching on AniList show up here."
                                )
                            }
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .background(SumiTheme.background)
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    @ViewBuilder
    private var cinemaBody: some View {
        if !model.cinemaContinueWatching.isEmpty {
            TVPosterShelf(title: "Continue Watching", items: model.cinemaContinueWatching, onOpen: openCinema)
        }
        ForEach(model.cinemaShelves) { shelf in
            TVPosterShelf(title: shelf.title, items: shelf.items, onOpen: openCinema)
        }
        if let error = model.cinemaError, model.cinemaShelves.isEmpty {
            TVEmptyHint(title: "Films and TV unavailable", detail: TVCinema.message(error))
        } else if model.cinemaShelves.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 120)
        }
    }

    private func openCinema(_ item: MediaCard.Item) {
        showDetail = true
        Task {
            await model.openCinemaDetail(
                catalog: item.catalog ?? model.cinemaCatalog(forId: item.id),
                id: item.id,
                title: item.title,
                coverURL: item.coverImageURL
            )
        }
    }

    private func open(_ id: Int64, _ title: String, _ cover: URL?, _ isManga: Bool) {
        showDetail = true
        Task { await model.openDetail(id: id, title: title, coverURL: cover, isManga: isManga) }
    }

    private func open(_ item: MediaCard.Item) {
        open(item.id, item.title, item.coverImageURL, item.isManga)
    }
}

enum TVCinema {
    /// The engine's errors are Rust enum descriptions; the two a viewer can
    /// act on are worth saying plainly. Same table as the phone's.
    static func message(_ raw: String) -> String {
        if raw.contains("tmdb_unauthorized") {
            return "TMDB rejected the API key. Check it in Settings."
        }
        if raw.contains("tmdb_rate_limited") {
            return "TMDB is rate limiting this key. Try again shortly."
        }
        return raw
    }
}

/// The row a viewer lands on: the episode they are in the middle of, played
/// with one press. Chapters open the detail page instead, since there is no
/// reader on the TV.
private struct ContinueWatchingShelf: View {
    @Bindable var model: AppModel
    let onOpen: (Int64, String, URL?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader("Continue Watching")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                    ForEach(model.upNextItems) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
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
                                ZStack(alignment: .bottom) {
                                    CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 800) { image in
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } placeholder: {
                                        SumiTheme.card
                                    }
                                    .frame(width: TVMetrics.thumbWidth, height: TVMetrics.thumbHeight)
                                    .clipped()

                                    GeometryReader { geo in
                                        Rectangle()
                                            .fill(SumiTheme.indigo)
                                            .frame(width: geo.size.width * entry.progressPercent / 100, height: 6)
                                            .frame(maxHeight: .infinity, alignment: .bottom)
                                    }
                                    .frame(height: 6)
                                }
                                .frame(width: TVMetrics.thumbWidth, height: TVMetrics.thumbHeight)
                            }
                            .buttonStyle(.card)

                            Text(entry.title)
                                .font(.sumiHeading(size: 24, weight: .medium))
                                .foregroundStyle(SumiTheme.foreground)
                                .lineLimit(1)
                            Text("\(entry.unit) \(entry.nextEpisodeOrChapter) · \(Int(100 - entry.progressPercent))% LEFT")
                                .font(.system(size: 18, design: .monospaced))
                                .foregroundStyle(SumiTheme.muted)
                                .lineLimit(1)
                        }
                        .frame(width: TVMetrics.thumbWidth, alignment: .leading)
                    }
                }
                .padding(.horizontal, TVMetrics.gutter)
                // Room for the focus lift, which grows the card past its
                // frame and would otherwise be clipped by the scroll view.
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

private struct NewEpisodesShelf: View {
    let entries: [UpNextQueueView.QueueEntry]
    let onOpen: (UpNextQueueView.QueueEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TVSectionHeader("New Episodes")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 12) {
                            Button { onOpen(entry) } label: {
                                CachedAsyncImage(url: entry.thumbnailURL, maxPixelSize: 600) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    SumiTheme.card
                                }
                                .frame(width: TVMetrics.posterWidth, height: TVMetrics.posterHeight)
                                .clipped()
                            }
                            .buttonStyle(.card)

                            Text(entry.title)
                                .font(.system(size: 22))
                                .foregroundStyle(SumiTheme.foreground)
                                .lineLimit(2, reservesSpace: true)
                            Text("\(entry.unit) \(entry.nextEpisodeOrChapter) OUT")
                                .font(.system(size: 18, design: .monospaced))
                                .foregroundStyle(SumiTheme.indigo)
                        }
                        .frame(width: TVMetrics.posterWidth, alignment: .leading)
                    }
                }
                .padding(.horizontal, TVMetrics.gutter)
                .padding(.vertical, 30)
            }
            .scrollClipDisabled()
        }
        .focusSection()
    }
}

// MARK: - Shelves and grids

/// A horizontal row of posters, each a `.card` button so the focus engine
/// lifts and tilts it the way every other tvOS app's do. The title sits
/// under the card rather than in it: text inside a parallax card blurs at
/// the tilt's edges.
struct TVPosterShelf: View {
    let title: String
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                TVSectionHeader(title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: TVMetrics.shelfSpacing) {
                        ForEach(items) { item in
                            TVPosterCard(item: item, onOpen: onOpen)
                        }
                    }
                    .padding(.horizontal, TVMetrics.gutter)
                    .padding(.vertical, 30)
                }
                .scrollClipDisabled()
            }
            .focusSection()
        }
    }
}

struct TVPosterCard: View {
    let item: MediaCard.Item
    let onOpen: (MediaCard.Item) -> Void

    /// AniList scores are 0-100; the sheet shows them out of ten.
    static func meta(for item: MediaCard.Item) -> String? {
        var parts: [String] = []
        if let score = item.score, score > 0 {
            parts.append(String(format: "%.1f", Double(score) / 10))
        }
        if let total = item.totalEpisodesOrChapters, total > 0 {
            parts.append("\(total) \(item.isManga ? "CH" : "EPS")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { onOpen(item) } label: {
                CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 600) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: TVMetrics.posterWidth, height: TVMetrics.posterHeight)
                .clipped()
            }
            .buttonStyle(.card)

            Text(item.title)
                .font(.system(size: 22))
                .foregroundStyle(SumiTheme.foreground)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
            if let meta = Self.meta(for: item) {
                Text(meta)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
                    .lineLimit(1)
            }
        }
        .frame(width: TVMetrics.posterWidth, alignment: .leading)
    }
}

struct TVPosterGrid: View {
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    private let columns = [GridItem(.adaptive(minimum: TVMetrics.posterWidth), spacing: TVMetrics.shelfSpacing)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: TVMetrics.rowSpacing) {
            ForEach(items) { item in
                TVPosterCard(item: item, onOpen: onOpen)
            }
        }
        .padding(.horizontal, TVMetrics.gutter)
        .padding(.vertical, 30)
    }
}

struct TVSectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(SumiTheme.foreground)
            .padding(.horizontal, TVMetrics.gutter)
    }
}

struct TVEmptyHint: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(SumiTheme.foreground)
            Text(detail)
                .font(.system(size: 24))
                .foregroundStyle(SumiTheme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 120)
        .padding(.top, 120)
    }
}

// MARK: - Library

private struct LibraryTab: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool
    /// Survives relaunches; `AppModel.libraryStatus` resets every launch.
    @AppStorage("anicat_library_status") private var storedStatus = "CURRENT"

    private static let statuses: [(raw: String, label: String)] = [
        ("CURRENT", "Watching"),
        ("PLANNING", "Planning"),
        ("COMPLETED", "Completed"),
        ("REPEATING", "Rewatching"),
        ("PAUSED", "Paused"),
        ("DROPPED", "Dropped")
    ]

    private var currentLabel: String {
        Self.statuses.first { $0.raw == storedStatus }?.label ?? "Watching"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    TabHeader(title: "Library", model: model)

                    if model.appMode == .cinema {
                        if model.cinemaWatchlist.isEmpty {
                            TVEmptyHint(
                                title: "Nothing saved",
                                detail: "Films and series you add to your watchlist show up here."
                            )
                        } else {
                            countLine(model.cinemaWatchlist.count)
                            TVPosterGrid(items: model.cinemaWatchlist, onOpen: openCinema)
                        }
                    } else if !model.isSignedIn {
                        TVEmptyHint(
                            title: "No lists yet",
                            detail: "Connect AniList in Settings to see your library."
                        )
                    } else {
                        statusRow
                        if model.isLoading && model.libraryItems.isEmpty {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.top, 120)
                        } else if model.libraryItems.isEmpty {
                            TVEmptyHint(
                                title: "Nothing in \(currentLabel)",
                                detail: "Titles you move to this list on AniList show up here."
                            )
                        } else {
                            countLine(model.libraryItems.count)
                            TVPosterGrid(items: model.libraryItems, onOpen: open)
                        }
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .background(SumiTheme.background)
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
        .task {
            guard model.isSignedIn else { return }
            if model.libraryStatus != storedStatus || model.libraryItems.isEmpty {
                await model.loadLibrary(status: storedStatus)
            }
        }
    }

    @ViewBuilder
    private func countLine(_ count: Int) -> some View {
        Text("\(count) TITLES")
            .font(.system(size: 18, weight: .semibold, design: .monospaced))
            .foregroundStyle(SumiTheme.muted)
            .padding(.horizontal, TVMetrics.gutter)
    }

    /// The six statuses as a row of buttons rather than a menu: a menu on
    /// tvOS is a modal list that steals the screen, and six words fit the
    /// width with room to spare.
    @ViewBuilder
    private var statusRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 20) {
                ForEach(Self.statuses, id: \.raw) { status in
                    Button {
                        storedStatus = status.raw
                        Task { await model.loadLibrary(status: status.raw) }
                    } label: {
                        Text(status.label)
                            .font(.system(size: 24, weight: storedStatus == status.raw ? .semibold : .regular))
                    }
                    .tint(storedStatus == status.raw ? SumiTheme.indigo : nil)
                }
            }
            .padding(.horizontal, TVMetrics.gutter)
            .padding(.vertical, 20)
        }
        .scrollClipDisabled()
        .focusSection()
    }

    private func openCinema(_ item: MediaCard.Item) {
        showDetail = true
        Task {
            await model.openCinemaDetail(
                catalog: item.catalog ?? model.cinemaCatalog(forId: item.id),
                id: item.id,
                title: item.title,
                coverURL: item.coverImageURL
            )
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
                LazyVStack(alignment: .leading, spacing: 32) {
                    if model.appMode == .cinema {
                        if model.cinemaSearchResults.isEmpty {
                            ForEach(model.cinemaShelves.prefix(2)) { shelf in
                                TVPosterShelf(title: shelf.title, items: shelf.items, onOpen: openCinema)
                            }
                        } else {
                            TVPosterGrid(items: model.cinemaSearchResults, onOpen: openCinema)
                        }
                    } else if model.searchResults.isEmpty {
                        TVPosterShelf(title: "Trending", items: model.trendingItems, onOpen: open)
                    } else {
                        TVPosterGrid(items: model.searchResults, onOpen: open)
                    }
                }
                .padding(.vertical, 24)
            }
            .scrollClipDisabled()
            .background(SumiTheme.background)
            // tvOS draws the search keyboard across the top of the tab and
            // the results underneath it; there is no field to place.
            .searchable(text: $query, prompt: model.appMode == .cinema ? "Search films and series" : "Search anime")
            // Search on submit rather than on every keystroke: AniList is
            // rate-limited per minute and a per-character search burns the
            // budget on prefixes nobody asked for. The TV keyboard has no
            // submit key of its own -- the query fires when the viewer moves
            // focus down into the results -- so an empty query clears.
            .onSubmit(of: .search) { runSearch() }
            .onChange(of: query) { _, new in
                if new.isEmpty { runSearch() }
            }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    private func runSearch() {
        Task {
            if model.appMode == .cinema {
                await model.searchCinema(query)
            } else {
                await model.search(query: query)
            }
        }
    }

    private func openCinema(_ item: MediaCard.Item) {
        showDetail = true
        Task {
            await model.openCinemaDetail(
                catalog: item.catalog ?? model.cinemaCatalog(forId: item.id),
                id: item.id,
                title: item.title,
                coverURL: item.coverImageURL
            )
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

// MARK: - Resolving card

/// "Finding a stream", with the seconds counting up and a Cancel the remote
/// can reach. Focus is handed to it on appearance: the card is the only
/// control on screen worth pressing while a resolve runs, and without the
/// hand-off the Menu button was the only way out.
struct TVResolvingCard: View {
    let startedAt: Date
    let status: String?
    let onCancel: () -> Void

    @FocusState private var cancelFocused: Bool

    var body: some View {
        HStack(spacing: 24) {
            ProgressView()
                .tint(SumiTheme.indigo)
            VStack(alignment: .leading, spacing: 4) {
                Text(status ?? "Finding a stream…")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(1)
                    .animation(.smooth, value: status)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                        .font(.system(size: 20, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                }
            }
            Spacer(minLength: 24)
            Button("Cancel", action: onCancel)
                .focused($cancelFocused)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 24)
        .frame(maxWidth: 900)
        .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 30, y: 10)
        .focusSection()
        .onAppear { cancelFocused = true }
    }
}
#endif
