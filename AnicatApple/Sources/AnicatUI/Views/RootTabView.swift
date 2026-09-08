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
                // Deliberately NOT `.ignoresSafeArea()` here. Applying it to
                // the whole player zeroes the insets *inside* it, so the
                // controls' own `safeAreaPadding` padded by nothing and the
                // title row landed on the clock and the Dynamic Island. The
                // picture ignores the safe area from inside instead, where
                // the video layer can do it without taking the chrome with
                // it.
                .transition(.opacity)
                .zIndex(30)
            }

            // Tapping an episode used to do nothing visible for the seconds a
            // resolve takes — indexers searched, candidates raced, a swarm
            // pre-buffered, all before there is a frame to show. The desktop
            // has raised this card since its play path was written; the phone
            // never did.
            if let startedAt = model.resolveStartedAt {
                ResolvingCard(startedAt: startedAt) {
                    model.activeResolveTask?.cancel()
                    model.resolveStartedAt = nil
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 92)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(40)
            }
        }
        .animation(.snappy, value: model.resolveStartedAt)
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
        // One alert for every play the phone starts from a tap, mounted on
        // the root so the two call sites -- Continue Watching and an episode
        // row on a pushed page -- share it rather than each growing their
        // own.
        .alert("You are on cellular", isPresented: Binding(
            get: { model.cellularPrompt != nil },
            set: { if !$0 { model.cellularPrompt = nil } }
        ), presenting: model.cellularPrompt) { prompt in
            Button("Play Anyway") {
                model.cellularPrompt = nil
                prompt.proceed()
            }
            Button("Cancel", role: .cancel) { model.cellularPrompt = nil }
        } message: { _ in
            Text("An episode is usually over a gigabyte, and the stream keeps downloading while it plays. Turn this warning off in Settings.")
        }
        // Handoff, Mac to phone. Both platforms have always *advertised*
        // playback through `ContinuityManager`; only `RootView` ever
        // received, so picking the phone up from the Mac's Handoff banner
        // opened Up Next with no idea what the Mac was playing.
        //
        // To the detail page, not into playback, matching macOS: a system
        // callback carries no user gesture, and forcing a resolve from one
        // races `resolveAndPlay`'s own resume logic. The reading activity is
        // deliberately not handled here -- the phone has no reader UI to
        // hand off into.
        .onContinueUserActivity(ContinuityManager.playbackActivityType) { activity in
            guard case .playback(let catalogId, let catalog, let title, _, _) =
                    ContinuityManager.shared.parseIncomingActivity(activity) else { return }
            Task {
                switch catalog {
                case "tmdb_movie":
                    await model.openCinemaDetail(catalog: .tmdbMovie, id: catalogId, title: title)
                case "tmdb_tv":
                    await model.openCinemaDetail(catalog: .tmdbTv, id: catalogId, title: title)
                default:
                    await model.openDetail(id: catalogId, isManga: false)
                }
            }
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


/// Anime or cinema, in the header of all three tabs.
///
/// A two-segment control rather than a fourth tab or a sidebar item: the
/// mode changes what every tab means, so it has to be visible from all of
/// them, and switching it from inside Library should leave you in Library.
/// Hidden entirely when the engine reports no TMDB access — a dead segment
/// that silently refuses to switch is worse than no segment.
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
            .frame(maxWidth: 210)
        }
    }
}

/// The title row the three tabs draw for themselves.
///
/// `navigationTitle` with the large display mode puts a 44pt bar above the
/// title whether or not anything is in it, so the first row of content began
/// 185pt down a 874pt screen — a fifth of the phone spent on chrome, and not
/// what the design sheet draws. Hiding the bar on the tab roots and drawing
/// the title here starts the content about 60pt higher. Pushed pages keep
/// the real navigation bar, so Back is untouched.
private struct TabHeader<Trailing: View>: View {
    let title: String
    var model: AppModel?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.sumiHeading(size: 32, weight: .bold))
                    .foregroundStyle(SumiTheme.foreground)
                Spacer(minLength: 8)
                trailing
            }
            if let model {
                ModeToggle(model: model)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 2)
        .padding(.bottom, 10)
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
    /// The Mac the open remote sheet is driving, captured when the button is
    /// pressed rather than read live.
    ///
    /// The button itself disappears the moment `discoveredMacNode` goes nil
    /// -- the Mac sleeping, quitting or leaving the Wi-Fi -- and a `.sheet`
    /// attached to it would go with it, snapping shut in the middle of
    /// whatever was on screen. Same shape as the `MpvSurface` note above:
    /// a view moved out of an `if` branch is torn down, and everything
    /// hanging off it goes too.
    @State private var remoteNode: BonjourDiscovery.DiscoveredNode?

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    TabHeader(title: "Up Next", model: model) {
                        HStack(spacing: 14) {
                            remoteButton
                            profileButton
                        }
                    }

                    if model.appMode == .cinema {
                        cinemaBody
                    } else {
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
                }
                .padding(.vertical, 8)
            }
            .background(SumiTheme.background)
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.refreshAll() }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
        // On the stack, not on the button: the button is conditional on a
        // Mac being in range and takes its modifiers with it when that goes.
        .sheet(item: $remoteNode) { node in
            PhoneRemoteView(node: node, model: model)
                .presentationDetents([.medium, .large])
        }
    }

    /// The same page for films and series. `cinemaShelves` is whatever TMDB
    /// rows the engine returned, so this does not hard-code a row list the
    /// way the anime side does — a row TMDB retires simply stops arriving.
    @ViewBuilder
    private var cinemaBody: some View {
        if !model.cinemaContinueWatching.isEmpty {
            PosterShelf(title: "Continue Watching", items: model.cinemaContinueWatching, onOpen: openCinema)
        }
        ForEach(model.cinemaShelves) { shelf in
            PosterShelf(title: shelf.title, items: shelf.items, onOpen: openCinema)
        }
        if let error = model.cinemaError, model.cinemaShelves.isEmpty {
            EmptyHint(title: "Films and TV unavailable", detail: Self.cinemaMessage(error))
        } else if model.cinemaShelves.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
        }
    }

    /// The engine's errors are Rust enum descriptions —
    /// `Network(msg: "tmdb_unauthorized")` is what reached the screen — and
    /// the two a viewer can actually act on are worth saying plainly.
    static func cinemaMessage(_ raw: String) -> String {
        if raw.contains("tmdb_unauthorized") {
            return "TMDB rejected the API key. Check it in Settings."
        }
        if raw.contains("tmdb_rate_limited") {
            return "TMDB is rate limiting this key. Try again shortly."
        }
        return raw
    }

    /// Appears only while a Mac running Anicat is advertising on this
    /// Wi-Fi. There is no disabled state and no "no Mac found" screen: the
    /// control is the answer to whether a Mac is there.
    @ViewBuilder
    private var remoteButton: some View {
        if let node = BonjourDiscovery.shared.discoveredMacNode {
            Button { remoteNode = node } label: {
                Image(systemName: "macbook.and.iphone")
                    .font(.system(size: 21))
                    .foregroundStyle(SumiTheme.muted)
            }
        }
    }

    /// Settings lives behind this button rather than in a fourth tab: it is
    /// opened once to sign in and then rarely, which is not what a tab slot
    /// is for. It is also the only route back to "Connect AniList" once
    /// onboarding has been dismissed.
    @ViewBuilder
    private var profileButton: some View {
        NavigationLink {
            PhoneSettingsView(model: model)
        } label: {
            // The signed-in avatar, not a generic person glyph: a
            // placeholder symbol reads as an unfinished control, the
            // account's own picture reads as the account.
            if let avatar = model.viewer?.avatarUrl.flatMap(URL.init(string:)) {
                CachedAsyncImage(url: avatar, maxPixelSize: 96) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 27))
                    .foregroundStyle(SumiTheme.muted)
            }
        }
    }


    /// TMDB ids are not AniList ids and the detail fetch is a different call,
    /// so cinema rows cannot go through `openDetail`. `cinemaCatalog(forId:)`
    /// is what knows whether an id is a film or a series.
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
                            .sumiShelfEdge()
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
                                model.playGuardedByCellular {
                                    playFromShelf(
                                        model: model,
                                        catalogId: entry.id,
                                        episode: entry.nextEpisodeOrChapter,
                                        title: entry.title,
                                        coverURL: entry.thumbnailURL
                                    )
                                }
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
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
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
                .font(.sumiHeading(size: 13, weight: .medium))
                .foregroundStyle(SumiTheme.foreground)
                .lineLimit(1)
            Text("\(entry.unit) \(entry.nextEpisodeOrChapter) · \(Int(100 - entry.progressPercent))% LEFT")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(SumiTheme.muted)
                .lineLimit(1)
        }
        // Three across whatever the screen is. This was a constant derived
        // from a 402pt iPhone 17 Pro, so on a 393pt 15 Pro the third card was
        // clipped and on a 440pt Max there was a dead gutter.
        .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 12)
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
                    TabHeader(title: "Library", model: model) { statusMenu }

                    if model.appMode == .cinema {
                        if model.cinemaWatchlist.isEmpty {
                            EmptyHint(
                                title: "Nothing saved",
                                detail: "Films and series you add to your watchlist show up here."
                            )
                        } else {
                            Text("\(model.cinemaWatchlist.count) TITLES")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(SumiTheme.muted)
                                .padding(.horizontal, 16)
                            PosterGrid(items: model.cinemaWatchlist, onOpen: openCinema)
                        }
                    } else if !model.isSignedIn {
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
            .toolbar(.hidden, for: .navigationBar)
            .refreshable { await model.loadLibrary() }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
        .task {
            guard model.isSignedIn else { return }
            if model.libraryStatus != storedStatus || model.libraryItems.isEmpty {
                await model.loadLibrary(status: storedStatus)
            }
        }
    }

    /// A menu, not a segmented control: six statuses across 402pt truncate to
    /// about two letters each. Same shape Mail uses for its filter. Cinema
    /// has its own watchlist statuses and does not use this one.
    @ViewBuilder
    private var statusMenu: some View {
        if model.appMode == .cinema {
            EmptyView()
        } else {
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

    /// TMDB ids are not AniList ids and the detail fetch is a different call,
    /// so cinema rows cannot go through `openDetail`.
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
    /// Kept here rather than in the engine: a search someone typed on this
    /// phone is not catalog data and has no business in the registry that
    /// syncs a watch history.
    @AppStorage("anicat_recent_searches") private var recentsRaw = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    TabHeader(title: "Search", model: model) { EmptyView() }

                    if model.appMode == .cinema {
                        if model.cinemaSearchResults.isEmpty {
                            if !recents.isEmpty { recentChips }
                            ForEach(model.cinemaShelves.prefix(2)) { shelf in
                                PosterSection(title: shelf.title, items: shelf.items, onOpen: openCinema)
                            }
                        } else {
                            PosterGrid(items: model.cinemaSearchResults, onOpen: openCinema)
                        }
                    } else if model.searchResults.isEmpty {
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
            .toolbar(.hidden, for: .navigationBar)
            // `.searchable` gives the system field, Cancel button and the
            // scroll-to-reveal behaviour for free. The desktop's command
            // palette has no iOS counterpart and is not reproduced.
            .searchable(text: $query, prompt: "Search anime")
            // Search on submit rather than on every keystroke: AniList is
            // rate-limited per minute and a per-character search burns the
            // budget on prefixes nobody asked for.
            .onSubmit(of: .search) {
                remember(query)
                Task {
                    if model.appMode == .cinema {
                        await model.searchCinema(query)
                    } else {
                        await model.search(query: query)
                    }
                }
            }
            .onChange(of: query) { _, new in
                if new.isEmpty {
                    Task {
                        if model.appMode == .cinema {
                            await model.searchCinema("")
                        } else {
                            await model.search(query: "")
                        }
                    }
                }
            }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    /// TMDB ids are not AniList ids and the detail fetch is a different call,
    /// so cinema rows cannot go through `openDetail`.
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


/// "Finding a stream", with the seconds counting up and a way out.
///
/// A card at the bottom rather than a blocking modal: it appears on every
/// single play, often only for a moment. The desktop's own comment on this
/// makes the same point — treating it as an alarming dialog was wrong.
private struct ResolvingCard: View {
    let startedAt: Date
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(SumiTheme.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text("Finding a stream…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(SumiTheme.muted)
                }
            }
            Spacer(minLength: 8)
            Button("Cancel", action: onCancel)
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
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
