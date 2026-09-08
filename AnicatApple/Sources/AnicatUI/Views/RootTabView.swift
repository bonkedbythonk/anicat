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
    /// Which tab the open detail page belongs to, if any.
    ///
    /// Not "is a detail showing" scoped to the visible tab, which is what
    /// this was first: switching tabs then read as a dismissal on the tab
    /// being left (popping the page and clearing the model) and as a
    /// presentation on the tab being entered, so Library opened an empty
    /// spinner over a model that had just been emptied. The page belongs to
    /// the tab it was opened from and stays there.
    @State private var detailOwner: Tab?

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
                PhonePlayerView(
                    controller: model.playerController,
                    streamURL: streamURL,
                    onClose: {
                        withAnimation(.smooth) { model.stopPlayback() }
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(30)
                // A video is a landscape object on a device that starts
                // portrait. Rotating the window rather than asking the user
                // to turn the phone is what every other player on iOS does.
                .modifier(PlayerOrientation(active: true))
            }
        }
        .tint(SumiTheme.indigo)
        // A deep link (`anicat://title/<id>`) and a notification tap both go
        // straight to `openDetail` on the model, with no row tapped to have
        // claimed an owner. Handled here rather than in `DetailPush`, which
        // is installed three times and would have all three tabs claim the
        // same page. `detailOwner == nil` so it does not steal a page a tap
        // has already opened elsewhere.
        .onChange(of: model.selectedMediaDetails?.id) { _, id in
            if id != nil, detailOwner == nil { detailOwner = tab }
        }
    }

    private func scoped(to owner: Tab) -> Binding<Bool> {
        Binding(
            get: { detailOwner == owner },
            // Only the owning tab may release the page. An unguarded setter
            // let whichever tab was being left clear a page another tab owned.
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

                    // The page used to end after New Episodes and left two
                    // thirds of the screen black, which read as "nothing
                    // here" rather than "you are up to date". These rows are
                    // already fetched by `refreshAll` — only the rendering
                    // was missing.
                    PosterShelf(title: "Because You Watched", items: model.becauseYouWatched, onOpen: open)
                    PosterShelf(title: "This Season", items: model.seasonalItems, onOpen: open)
                    PosterShelf(title: "Trending", items: model.trendingItems, onOpen: open)
                    PosterShelf(title: "Planning", items: model.planningItems, onOpen: open)

                    if model.upNextItems.isEmpty && model.trendingItems.isEmpty {
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
            // Settings lives behind this button rather than in a fourth tab:
            // it is opened once to sign in and then rarely, which is not what
            // a tab slot is for. It is also the only route back to
            // "Connect AniList" once onboarding has been dismissed.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        PhoneSettingsView(model: model)
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
            }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
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

/// A horizontal row of posters. The grid is for a page whose whole job is
/// one list; a shelf is for a page carrying several, where each row has to
/// stay one screen-height tall so the next row is visible under it.
private struct PosterShelf: View {
    let title: String
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            Button { onOpen(item) } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    Color.clear
                                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                                        .overlay {
                                            CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 300) { image in
                                                image.resizable().aspectRatio(contentMode: .fill)
                                            } placeholder: {
                                                SumiTheme.card
                                            }
                                        }
                                        .frame(width: 104)
                                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                                    Text(item.title)
                                        .font(.system(size: 12))
                                        .foregroundStyle(SumiTheme.foreground)
                                        .lineLimit(2, reservesSpace: true)
                                        .multilineTextAlignment(.leading)
                                        .frame(width: 104, alignment: .leading)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
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
                .frame(width: Self.cardWidth, height: Self.cardWidth * 9 / 16)
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
        .frame(width: Self.cardWidth, alignment: .leading)
    }

    /// Three across, as the design sheet draws them. At 172pt only 2.3 fitted
    /// and the third card was a sliver at the edge, which read as the shelf
    /// being cut off rather than scrollable.
    static let cardWidth: CGFloat = (402 - 32 - 24) / 3
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
    /// Survives relaunches. `AppModel.libraryStatus` is the live value but it
    /// resets to CURRENT every launch, so someone who lives in Completed had
    /// to re-pick it every time they opened the app.
    @AppStorage("anicat_library_status") private var storedStatus = "CURRENT"

    /// The six AniList list statuses, in the order the site itself lists
    /// them. Paired with their labels here rather than reusing
    /// `PhoneDetailView.listStatus`: this drives a `Picker`'s tags, so the
    /// raw values have to round-trip, not just render.
    private static let statuses: [(raw: String, label: String)] = [
        ("CURRENT", "Watching"),
        ("PLANNING", "Planning"),
        ("COMPLETED", "Completed"),
        ("REPEATING", "Rewatching"),
        ("PAUSED", "Paused"),
        ("DROPPED", "Dropped")
    ]

    /// Reads the stored value, not the model's: the label has to be right
    /// on the first frame, before the fetch that syncs the model has run.
    private var currentLabel: String {
        Self.statuses.first { $0.raw == storedStatus }?.label ?? "Watching"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if !model.isSignedIn {
                        EmptyHint(
                            title: "No lists yet",
                            detail: "Connect AniList in Settings to see your library."
                        )
                    } else if model.isLoading && model.libraryItems.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 64)
                    } else if model.libraryItems.isEmpty {
                        EmptyHint(
                            title: "Nothing in \(currentLabel)",
                            detail: "Titles you move to this list on AniList show up here."
                        )
                    } else {
                        Text("\(model.libraryItems.count) TITLES")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(SumiTheme.muted)
                            .padding(.horizontal, 16)
                        PosterGrid(items: model.libraryItems, onOpen: open)
                    }
                }
                .padding(.vertical, 8)
            }
            .background(SumiTheme.background)
            .navigationTitle("Library")
            // A `Menu` in the bar, not a segmented control: six statuses in a
            // segmented control on a 402pt screen truncate to two letters
            // each. This is the same shape Mail uses for its filter.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Status", selection: Binding(
                            get: { storedStatus },
                            set: { next in
                                storedStatus = next
                                Task { await model.loadLibrary(status: next) }
                            }
                        )) {
                            ForEach(Self.statuses, id: \.raw) { status in
                                Text(status.label).tag(status.raw)
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(currentLabel)
                                .font(.system(size: 15))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                }
            }
            .refreshable { await model.loadLibrary() }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
        // Two jobs. `refreshAll` only ever fetches whatever `libraryStatus`
        // already held and the tab is built before that first fetch lands,
        // so without this the grid stayed empty until the filter was
        // touched; and the model starts every launch on CURRENT, so the
        // remembered status has to be pushed into it here.
        .task {
            guard model.isSignedIn else { return }
            if model.libraryStatus != storedStatus || model.libraryItems.isEmpty {
                await model.loadLibrary(status: storedStatus)
            }
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
    /// Kept here rather than in the engine: a search someone typed on this
    /// phone is not catalog data and has no business in the registry that
    /// syncs a watch history.
    @AppStorage("anicat_recent_searches") private var recentsRaw = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if model.searchResults.isEmpty {
                        if !recents.isEmpty {
                            recentChips
                        }
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
                remember(query)
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

    // MARK: Recent searches

    private var recents: [String] {
        recentsRaw.split(separator: "\n").map(String.init)
    }

    @ViewBuilder
    private var recentChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("RECENT")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
                Spacer()
                Button("Clear") { recentsRaw = "" }
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 16)

            FlowChips(items: recents) { term in
                query = term
                Task { await model.search(query: term) }
            }
            .padding(.horizontal, 16)
        }
    }

    private func remember(_ term: String) {
        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Case-insensitive dedupe, most recent first, eight kept: the sheet
        // draws two rows of chips and more than that wraps into the grid.
        var list = recents.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentsRaw = list.prefix(8).joined(separator: "\n")
    }
}

/// Chips that wrap onto as many rows as they need. SwiftUI has no flow
/// layout before iOS 16's `Layout`, and a `LazyVGrid` cannot do it either:
/// its columns are fixed widths, so short and long terms would sit in the
/// same column width and the row would read as a table.
struct FlowChips: Layout {
    let items: [String]
    let onTap: (String) -> Void

    init(items: [String], onTap: @escaping (String) -> Void) {
        self.items = items
        self.onTap = onTap
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + 8
                rowHeight = 0
            }
            x += size.width + 8
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + 8
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + 8
            rowHeight = max(rowHeight, size.height)
        }
    }
}

extension FlowChips: View {
    var body: some View {
        FlowChips(items: items, onTap: onTap) {
            ForEach(items, id: \.self) { term in
                Button { onTap(term) } label: {
                    Text(term)
                        .font(.system(size: 13))
                        .foregroundStyle(SumiTheme.foreground)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(SumiTheme.card, in: Capsule())
                }
                .buttonStyle(.plain)
            }
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
        // Falls back to any window scene rather than requiring a
        // foregroundActive one. Launching straight into the player (the
        // ANICAT_DEBUG_PLAY_FILE path, and a notification tap in the real
        // app) runs `onAppear` before the scene finishes activating, so the
        // strict lookup found nothing and the window stayed portrait with
        // the video letterboxed across the middle.
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive })
            ?? scenes.first
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

    /// AniList scores are 0-100; the sheet shows them out of ten.
    static func meta(for item: MediaCard.Item) -> String? {
        var parts: [String] = []
        if let score = item.score, score > 0 {
            // No star glyph in front of it: the house rule bars emoji, and
            // the ones that are not emoji render as one on some faces. The
            // detail hero's meta line already reads "7.3 · 2024 · 12 EPS",
            // so this matches it.
            parts.append(String(format: "%.1f", Double(score) / 10))
        }
        if let total = item.totalEpisodesOrChapters, total > 0 {
            parts.append("\(total) \(item.isManga ? "CH" : "EPS")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(items) { item in
                Button {
                    onOpen(item)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        // `aspectRatio` on the image itself *fits* the poster
                        // inside the cell, so a cover that is not exactly 2:3
                        // (ONE PIECE) came back shorter than its neighbours and
                        // the row lost its baseline. The box owns the ratio and
                        // the artwork fills it.
                        Color.clear
                            .aspectRatio(2.0 / 3.0, contentMode: .fit)
                            .overlay {
                                CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 360) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    SumiTheme.card
                                }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                        // Two lines are reserved whether or not the title needs
                        // them: the second independent cause of the ragged rows
                        // was a one-line title sitting beside a two-line one.
                        Text(item.title)
                            .font(.system(size: 12.5))
                            .foregroundStyle(SumiTheme.foreground)
                            .lineLimit(2, reservesSpace: true)
                            .multilineTextAlignment(.leading)

                        if let meta = Self.meta(for: item) {
                            Text(meta)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(SumiTheme.muted)
                                .lineLimit(1)
                        }
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
