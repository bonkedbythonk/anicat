#if os(iOS)
import SwiftUI

/// The iPhone root, in place of `RootView`'s 200pt sidebar rail.
///
/// Not a narrower `RootView`: the rail is a list of ten sections and a tab
/// bar holds five. Up Next, Library and Search are the three a phone reaches
/// for; Read carries manga and light novels under one segment, the way the
/// header already carries Anime and Films & TV. The sections without a tab
/// sit where a streaming app's viewer looks for them, not in the rail's
/// order: today's schedule on Up Next, Downloads and History beside the
/// lists in Library. Under More, all three were two taps deep, and Downloads
/// is what someone opens offline. More keeps Stats and Settings.
public struct RootTabView: View {
    @Bindable var model: AppModel

    public init(model: AppModel) {
        self.model = model
    }

    enum Tab: Hashable {
        case upNext, library, read, search, more
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

                PhoneReadTab(model: model, showDetail: scoped(to: .read))
                    .tabItem { Label("Read", systemImage: "book") }
                    .tag(Tab.read)

                SearchTab(model: model, showDetail: scoped(to: .search))
                    .tabItem { Label("Search", systemImage: "magnifyingglass") }
                    .tag(Tab.search)

                PhoneMoreTab(model: model, showDetail: scoped(to: .more))
                    .tabItem { Label("More", systemImage: "ellipsis.circle") }
                    .tag(Tab.more)
            }
            // Room for the mini-player bar above the tab bar, so the last
            // row of a list is not under it.
            .safeAreaInset(edge: .bottom) {
                if model.activeStreamURL != nil, model.isPlayerMinimized {
                    Color.clear.frame(height: PhonePlayerView.miniBarHeight + 8)
                }
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
                    isMinimized: model.isPlayerMinimized,
                    onMinimize: {
                        withAnimation(.sumi(.page)) { model.isPlayerMinimized = true }
                    },
                    onRestore: {
                        withAnimation(.sumi(.page)) { model.isPlayerMinimized = false }
                    },
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
            // Behind an `if` for the same reason as the desktop's: this layer
            // is above the player's zIndex and should exist only while it has
            // something on it.
            // The readers and the person pages sit over the tab view at the
            // same layers the Mac gives them (`RootView`): both readers are
            // pure SwiftUI with their AppKit bits behind `#if os(macOS)`,
            // so the phone mounts the same views and adds no twin. One call
            // site each, outside the tabs, for the reason the player is.
            if let session = model.activeReadingSession {
                MangaReaderView(
                    title: session.title,
                    chapterTitle: session.chapterTitle,
                    pageURLs: session.pageURLs,
                    initialPage: session.startPage,
                    onPageChanged: { page in
                        model.recordReadingPage(chapterId: session.chapterId, page: page, pageCount: session.pageURLs.count)
                        ContinuityManager.shared.advertiseReading(
                            mangaId: session.chapterId, anilistId: session.anilistId,
                            title: session.title, chapter: session.chapterTitle, pageIndex: page)
                    },
                    onNextChapter: { Task { await model.nextChapter() } },
                    onPrevChapter: { Task { await model.prevChapter() } },
                    onClose: { withAnimation(.smooth) { model.closeReader() } }
                )
                .transition(.opacity)
                .zIndex(35)
            }

            if model.novelReaderOpen {
                SyosetuReaderView(model: model)
                    .transition(.opacity)
                    .zIndex(31)
            }

            if let page = model.personPageStack.last {
                PersonPageView(model: model)
                    .id(page.id)
                    .background(SumiTheme.background.ignoresSafeArea())
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .zIndex(34)
            }

            if let personId = model.openCinemaPersonId {
                CinemaPersonView(
                    model: model,
                    personId: personId,
                    fallbackName: model.openCinemaPersonName,
                    onDismiss: { model.openCinemaPersonId = nil }
                )
                .background(SumiTheme.background.ignoresSafeArea())
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(34)
            }

            // First launch, above everything, as on the Mac. The phone
            // mounted nothing here for its first three days: `initialize`
            // set `onboardingOpen` and no view read it, so the flag stayed
            // true, the shelves showed under it, and Settings was the only
            // route to "Connect AniList".
            if model.onboardingOpen {
                OnboardingView(model: model)
                    .zIndex(80)
                    .transition(.opacity)
            }

            // The Mac has drawn `errorMessage` as a toast since its play path
            // was written; the phone read it only inside a detail page that
            // had failed to load. A resolve that found no seeders, the
            // opening watchdog running out of releases, a stream dying
            // mid-episode: each set the message, closed whatever it closed,
            // and showed nothing, so a tap "did nothing" and a player
            // "closed itself". Above the player (30) and the resolve card
            // (40), under onboarding (80), same as the Mac's 60.
            if let error = model.errorMessage {
                PhoneErrorToast(message: error, retry: model.errorRetryAction) {
                    withAnimation(.snappy) {
                        model.errorMessage = nil
                        model.errorRetryAction = nil
                    }
                }
                .zIndex(60)
            }

            // Not over the full-screen player: a release switch or Next from
            // inside it drew this card across the landscape picture, above the
            // player's own spinner carrying the same line. The player shows
            // the status and its own Cancel then.
            if model.resolveStartedAt != nil, model.activeStreamURL == nil || model.isPlayerMinimized {
                VStack(spacing: 10) {
                    if let startedAt = model.resolveStartedAt {
                        // `cancelResolve`, not a bare task cancel: it also stops
                        // the status poller, which otherwise wrote the line back
                        // until the engine's resolve returned.
                        ResolvingCard(startedAt: startedAt, status: model.playerController.resolveStatus) {
                            model.cancelResolve()
                        }
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 92)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(40)
            }
        }
        .animation(.snappy, value: model.resolveStartedAt)
        .animation(.snappy, value: model.errorMessage != nil)
        .animation(.smooth, value: model.onboardingOpen)
        // The lock is applied from `syncPlaybackSession`, which does not
        // run on a minimise; this is the one other edge it has to follow.
        .onChange(of: model.isPlayerMinimized) { _, minimized in
            OrientationLock.apply(playerOpen: model.activeStreamURL != nil && !minimized)
        }
        // A quick action, a widget or `anicat://section/<name>` lands in
        // `AppModel.navigate(to:)`, which only the Mac's sidebar used to
        // read. The phone's tabs are their own state, so the Search quick
        // action reached the model and the screen did not move.
        .onChange(of: model.currentNavSection) { _, section in
            switch section {
            case .upNext, .schedule: tab = .upNext
            case .library, .history, .downloads: tab = .library
            case .manga, .novels: tab = .read
            case .search: tab = .search
            case .stats, .settings: tab = .more
            }
        }
        .animation(.sumi(.page), value: model.personPageStack.count)
        .animation(.sumi(.page), value: model.openCinemaPersonId)
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
        // races `resolveAndPlay`'s own resume logic.
        .onContinueUserActivity(AppModel.spotlightActivityType) { activity in
            model.handleSpotlightActivity(activity)
        }
        .onContinueUserActivity(ContinuityManager.readingActivityType) { activity in
            guard case .reading(let chapterId, let anilistId, _, _, let page) =
                    ContinuityManager.shared.parseIncomingActivity(activity),
                  let anilistId else { return }
            Task { await model.openReadingHandoff(anilistId: anilistId, chapterId: chapterId, page: page) }
        }
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
            //
            // The model is cleared here, synchronously, and never through
            // `closeDetail`. Taking the page to another tab used to pop the
            // first tab's page, whose `onChange` ran `closeDetail` on the
            // shared model while the new title's fetch was starting: it
            // cancelled that fetch and restored the previous entry of
            // `detailHistory` (a title reached through a relation row), so a
            // tap on one show landed on a different one. The phone has no
            // step-back through that history -- Back leaves the page -- so
            // nothing here should ever restore from it. Tap order keeps this
            // safe: `showDetail = true` runs before the `openDetail` task.
            set: { presented in
                if presented {
                    if let previous = detailOwner, previous != owner {
                        model.clearDetail()
                    }
                    detailOwner = owner
                } else if detailOwner == owner {
                    detailOwner = nil
                    model.clearDetail()
                }
            }
        )
    }
}


/// Anime or cinema, in the header of all three tabs.
///
/// A two-word toggle rather than a fourth tab or a sidebar item: the
/// mode changes what every tab means, so it has to be visible from all of
/// them, and switching it from inside Library should leave you in Library.
/// Hidden entirely when the engine reports no TMDB access — a dead segment
/// that silently refuses to switch is worse than no segment.
struct ModeToggle: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.cinemaAvailable {
            SumiSlashToggle(
                [(AppModel.AppMode.anime, "Anime"), (.cinema, "Films & TV")],
                selection: model.appMode
            ) { model.setAppMode($0) }
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
struct TabHeader<Trailing: View>: View {
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
/// Clearing the model belongs to `RootTabView.scoped(to:)`, which knows
/// whether the page went false because it was popped or because another tab
/// took it; this modifier cannot tell the two apart.
struct DetailPush: ViewModifier {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $isPresented) {
                PhoneDetailView(model: model)
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
                        SectionHeader("New episodes")
                        VStack(spacing: 0) {
                            ForEach(newEpisodes) { entry in
                                NewEpisodeRow(entry: entry) {
                                    open(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH")
                                }
                                Rectangle().fill(SumiTheme.border).frame(height: 1)
                            }
                        }
                    }

                    if !model.scheduleItems.isEmpty {
                        AiringTodayStrip(model: model, showDetail: $showDetail)
                    }

                    // The page used to end after New Episodes and left two
                    // thirds of the screen black, which read as "nothing
                    // here" rather than "you are up to date". These rows are
                    // already fetched by `refreshAll` — only the rendering
                    // was missing.
                    PosterShelf(title: "Because you watched", items: model.becauseYouWatched, onOpen: open)
                    PosterShelf(title: "This season", items: model.seasonalItems, onOpen: open)
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
        // `fullScreenCover`, not a detented sheet. The remote was coming up
        // at `.medium` -- a half-height card with a poster, a scrubber and
        // two rows of controls crammed into it, under a title bar that still
        // belonged to the page behind. It is the only thing being used while
        // it is open, so it takes the screen.
        .fullScreenCover(item: $remoteNode) { node in
            PhoneRemoteView(node: node, model: model)
        }
        // `anicat://remote`, which is the only thing a Live Activity can ask
        // for. Answered here because this is where the sheet lives and where
        // the discovered Mac is known.
        .onChange(of: model.wantsRemoteSheet) { _, wanted in
            guard wanted else { return }
            model.wantsRemoteSheet = false
            guard let node = BonjourDiscovery.shared.discoveredMacNode else { return }
            remoteNode = node
        }
    }

    /// The same page for films and series. `cinemaShelves` is whatever TMDB
    /// rows the engine returned, so this does not hard-code a row list the
    /// way the anime side does — a row TMDB retires simply stops arriving.
    @ViewBuilder
    private var cinemaBody: some View {
        if !model.cinemaContinueWatching.isEmpty {
            PosterShelf(title: "Continue watching", items: model.cinemaContinueWatching, onOpen: openCinema)
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

/// Today's episodes on the home page, with the week one tap away. The
/// schedule used to be More > Schedule, two taps from anywhere, and it is
/// what someone following a weekly show checks. What they watch comes first,
/// then the rest of the day by air time.
struct AiringTodayStrip: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool

    /// Today's, or tomorrow's once today's have aired. `scheduleItems` holds
    /// each show's *next* airing, so an episode drops off the moment it airs
    /// and by the evening the row said "Nothing airs today" on a day with
    /// four episodes.
    private var day: (label: String, items: [ScheduleView.ScheduleItem]) {
        let calendar = Calendar.current
        func on(_ test: (Date) -> Bool) -> [ScheduleView.ScheduleItem] {
            model.scheduleItems
                .filter { test(Date(timeIntervalSince1970: Double($0.airingAt))) }
                .sorted { ($0.isWatching ? 0 : 1, $0.airingAt) < ($1.isWatching ? 0 : 1, $1.airingAt) }
        }
        let today = on(calendar.isDateInToday)
        if !today.isEmpty { return ("Airing today", today) }
        return ("Airing tomorrow", on(calendar.isDateInTomorrow))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            let day = day
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(day.label)
                Spacer()
                NavigationLink {
                    PhoneScheduleView(model: model, showDetail: $showDetail)
                } label: {
                    HStack(spacing: 3) {
                        Text("Schedule")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SumiTheme.indigo)
                }
                .padding(.trailing, 16)
            }
            if day.items.isEmpty {
                Text("Nothing airs today or tomorrow.")
                    .font(.system(size: 13))
                    .foregroundStyle(SumiTheme.muted)
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(day.items) { item in
                            Button { open(item) } label: { card(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func card(_ item: ScheduleView.ScheduleItem) -> some View {
        HStack(spacing: 10) {
            CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 200) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                SumiTheme.card
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("Ep \(item.episodeNumber) \u{00B7} \(item.airingTimeText)")
                    .font(.system(size: 10.5)).monospacedDigit()
                    .foregroundStyle(item.isWatching ? SumiTheme.indigo : SumiTheme.muted)
                    .lineLimit(1)
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(8)
        .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func open(_ item: ScheduleView.ScheduleItem) {
        showDetail = true
        Task { await model.openDetail(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: false) }
    }
}

/// A horizontal row of posters. The grid is for a page whose whole job is
/// one list; a shelf is for a page carrying several, where each row has to
/// stay one screen-height tall so the next row is visible under it.
struct PosterShelf: View {
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

struct ContinueWatchingRow: View {
    @Bindable var model: AppModel
    let onOpen: (Int64, String, URL?, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader("Continue watching")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(model.upNextItems) { entry in
                        // To the show's page, not straight into a stream: a
                        // tap on a card started a resolve the viewer had not
                        // asked for (owner, 2026-09-23). The page's own
                        // Continue button plays it; the long press keeps the
                        // one-tap route for whoever wants it.
                        Button {
                            onOpen(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH")
                        } label: {
                            ContinueWatchingCard(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if entry.unit != "CH" {
                                Button {
                                    model.playGuardedByCellular {
                                        playFromShelf(
                                            model: model,
                                            catalogId: entry.id,
                                            episode: entry.nextEpisodeOrChapter,
                                            title: entry.title,
                                            coverURL: entry.thumbnailURL
                                        )
                                    }
                                } label: {
                                    Label("Play Ep \(entry.nextEpisodeOrChapter)", systemImage: "play.fill")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

struct ContinueWatchingCard: View {
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
            Text("\(entry.unit.capitalized) \(entry.nextEpisodeOrChapter) · \(Int(100 - entry.progressPercent))% left")
                .font(.system(size: 10.5)).monospacedDigit()
                .foregroundStyle(SumiTheme.muted)
                .lineLimit(1)
        }
        // Three across whatever the screen is. This was a constant derived
        // from a 402pt iPhone 17 Pro, so on a 393pt 15 Pro the third card was
        // clipped and on a 440pt Max there was a dead gutter.
        .containerRelativeFrame(.horizontal, count: 3, span: 1, spacing: 12)
    }
}

struct NewEpisodeRow: View {
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
                    Text("\(entry.unit.capitalized) \(entry.nextEpisodeOrChapter) out\(entry.watchedTimeAgo.map { " · \($0)" } ?? "")")
                        .font(.system(size: 10.5)).monospacedDigit()
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
    /// AniList's own order is "recently updated", which is what the site
    /// shows and what the Mac keeps. The others are client-side over the
    /// fetched page, so they cost nothing and never touch the engine.
    @AppStorage("anicat_library_sort") private var sortRaw = LibrarySort.updated.rawValue
    @AppStorage("anicat_library_layout") private var layoutRaw = "grid"
    @State private var formatFilter = ""

    enum LibrarySort: String, CaseIterable {
        case updated, title, score, progress
        var label: String {
            switch self {
            case .updated: return "Recently updated"
            case .title: return "Title"
            case .score: return "Score"
            case .progress: return "Progress"
            }
        }
    }

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

    private var sort: LibrarySort { LibrarySort(rawValue: sortRaw) ?? .updated }
    private var isGrid: Bool { layoutRaw != "list" }

    /// The formats present in the fetched list, so the chips never offer a
    /// filter that empties the page. `format` is optional on the card: an
    /// old HomeCache snapshot decodes without it and those rows fall under
    /// no chip rather than under a "Unknown" one.
    private var availableFormats: [String] {
        var seen: [String] = []
        for item in model.libraryItems {
            if let format = item.format, !format.isEmpty, !seen.contains(format) { seen.append(format) }
        }
        return seen
    }

    private var shownItems: [MediaCard.Item] {
        var items = model.libraryItems
        if !formatFilter.isEmpty { items = items.filter { $0.format == formatFilter } }
        switch sort {
        case .updated: break
        case .title: items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .score: items.sort { ($0.score ?? -1) > ($1.score ?? -1) }
        case .progress:
            items.sort { Self.progressFraction($0) > Self.progressFraction($1) }
        }
        return items
    }

    static func progressFraction(_ item: MediaCard.Item) -> Double {
        guard let progress = item.progress, let total = item.totalEpisodesOrChapters, total > 0 else {
            return Double(item.progress ?? 0) / 10_000
        }
        return Double(progress) / Double(total)
    }

    static func formatLabel(_ raw: String) -> String {
        switch raw {
        case "TV": return "TV"
        case "TV_SHORT": return "TV Short"
        case "MOVIE": return "Movie"
        case "ONE_SHOT": return "One Shot"
        default: return raw.capitalized
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    TabHeader(title: "Library", model: model) { statusMenu }
                    shortcuts

                    if model.appMode == .cinema {
                        if model.cinemaWatchlist.isEmpty {
                            EmptyHint(
                                title: "Nothing saved",
                                detail: "Films and series you add to your watchlist show up here."
                            )
                        } else {
                            Text("\(model.cinemaWatchlist.count) title\(model.cinemaWatchlist.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
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
                        if availableFormats.count > 1 {
                            formatChips
                        }
                        HStack {
                            Text("\(shownItems.count) title\(shownItems.count == 1 ? "" : "s")")
                                .font(.system(size: 10, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(SumiTheme.muted)
                            Spacer()
                            sortMenu
                            Button {
                                layoutRaw = isGrid ? "list" : "grid"
                            } label: {
                                Image(systemName: isGrid ? "list.bullet" : "square.grid.2x2")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(SumiTheme.muted)
                            }
                            .accessibilityLabel(isGrid ? "Show as list" : "Show as grid")
                        }
                        .padding(.horizontal, 16)
                        if isGrid {
                            PosterGrid(items: shownItems, onOpen: open)
                        } else {
                            PosterList(items: shownItems, onOpen: open)
                        }
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

    /// Downloads and History, beside the lists as a streaming app keeps them.
    /// Pushed on this tab's own stack, so a title opened from either comes
    /// back to it.
    @ViewBuilder
    private var shortcuts: some View {
        HStack(spacing: 10) {
            NavigationLink { PhoneDownloadsView(model: model) } label: {
                shortcut("Downloads", "arrow.down.circle",
                         count: model.libraryDownloads.count + model.offlineChapters.count)
            }
            NavigationLink { PhoneHistoryView(model: model, showDetail: $showDetail) } label: {
                shortcut("History", "clock.arrow.circlepath", count: 0)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private func shortcut(_ title: String, _ symbol: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(SumiTheme.indigo)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(SumiTheme.foreground)
            Spacer(minLength: 4)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(SumiTheme.muted)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(SumiTheme.muted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SumiTheme.border, lineWidth: 1))
        .contentShape(Rectangle())
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
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(SumiTheme.foreground)
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(SumiTheme.muted)
            }
        }
        }
    }

    @ViewBuilder
    private var sortMenu: some View {
        Menu {
            Picker("Sort", selection: $sortRaw) {
                ForEach(LibrarySort.allCases, id: \.rawValue) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(sort.label)
                    .font(.system(size: 12))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(SumiTheme.muted)
        }
    }

    /// One row of chips, "All" first, scrolling sideways when the list has
    /// more formats than fit. A filter is one tap on and one tap off.
    @ViewBuilder
    private var formatChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("All", selected: formatFilter.isEmpty) { formatFilter = "" }
                ForEach(availableFormats, id: \.self) { format in
                    chip(Self.formatLabel(format), selected: formatFilter == format) {
                        formatFilter = formatFilter == format ? "" : format
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? SumiTheme.background : SumiTheme.foreground)
                .padding(.horizontal, 13)
                .padding(.vertical, 6)
                .background(selected ? SumiTheme.indigo : SumiTheme.card, in: Capsule())
        }
        .buttonStyle(.plain)
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

/// The list layout: a thumbnail, the title and the progress on one row.
/// For the viewer who keeps a 200-title Completed list and wants to scan
/// names, which a two-line poster caption cannot do.
struct PosterList: View {
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                Button { onOpen(item) } label: {
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 200) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            SumiTheme.card
                        }
                        .frame(width: 44, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title)
                                .font(.system(size: 15))
                                .foregroundStyle(SumiTheme.foreground)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            // Progress replaces the grid's episode count
                            // rather than joining it: "11 / 12 6.4 · 12 eps"
                            // said twelve twice with no separator.
                            HStack(spacing: 6) {
                                if let progress = item.progress, progress > 0 {
                                    Text("\(progress)\(item.totalEpisodesOrChapters.map { " / \($0)" } ?? "")")
                                    if let score = item.score, score > 0 {
                                        Text("\u{00B7} " + String(format: "%.1f", Double(score) / 10))
                                    }
                                } else if let meta = PosterGrid.meta(for: item) {
                                    Text(meta)
                                }
                            }
                            .font(.system(size: 10.5)).monospacedDigit()
                            .foregroundStyle(SumiTheme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(SumiTheme.muted)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Rectangle().fill(SumiTheme.border).frame(height: 1).padding(.leading, 72)
            }
        }
    }
}

// MARK: - Search

private struct SearchTab: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool
    @State private var query = ""
    /// `anicat://search?q=` and the Search quick action write
    /// `model.searchQuery`; the field here is local, so it has to follow.
    /// Kept here rather than in the engine: a search someone typed on this
    /// phone is not catalog data and has no business in the registry that
    /// syncs a watch history.
    @AppStorage("anicat_recent_searches") private var recentsRaw = ""
    @State private var filters = PhoneSearchFilters()
    @State private var showFilters = false

    /// The Mac searches on a 350ms debounce; the phone searched on submit
    /// only, on the theory that per-keystroke searches burn AniList's
    /// per-minute budget. The debounce is what makes that theory moot: a
    /// pause in typing is one request, and the Mac has run this way for
    /// months without hitting the limit.
    private static let debounce: Duration = .milliseconds(350)

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    TabHeader(title: "Search", model: model) {
                        // In the header, not the toolbar: the tab roots hide
                        // the navigation bar (see `TabHeader`).
                        if model.appMode == .anime {
                            Button {
                                showFilters = true
                            } label: {
                                Image(systemName: filters.isActive
                                      ? "line.3.horizontal.decrease.circle.fill"
                                      : "line.3.horizontal.decrease.circle")
                                    .font(.system(size: 24))
                                    .foregroundStyle(filters.isActive ? SumiTheme.indigo : SumiTheme.muted)
                            }
                            .accessibilityLabel("Filters")
                        }
                    }

                    searchField

                    if model.appMode == .anime {
                        activeFilterChips
                    }

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
                        // Somewhere to go without typing, as a streaming
                        // app's Browse opens: the page was one Trending grid,
                        // and every other way in sat behind the filter sheet.
                        if !filters.isActive {
                            genreChips
                        }
                        PosterShelf(title: "This season", items: model.seasonalItems, onOpen: open)
                        PosterShelf(title: "Trending", items: model.trendingItems, onOpen: open)
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
            // `.task(id:)` is the debounce: a keystroke cancels the sleep
            // of the previous one, so only the pause after typing searches.
            .task(id: query) {
                try? await Task.sleep(for: Self.debounce)
                guard !Task.isCancelled else { return }
                await runSearch()
            }
            .onChange(of: model.searchQuery) { _, incoming in
                if !incoming.isEmpty, incoming != query { query = incoming }
            }
            .onChange(of: filters) { _, _ in
                Task { await runSearch() }
            }
            .sheet(isPresented: $showFilters) {
                PhoneSearchFilterSheet(filters: $filters)
                    .presentationDetents([.medium, .large])
            }
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }

    /// A field of our own, not `.searchable`: that one lives in the
    /// navigation bar, and the tab roots hide the bar (see `TabHeader`), so
    /// the phone shipped a Search tab with no visible way to type into it.
    /// Scroll-to-reveal did not help either, since there was no bar to
    /// reveal.
    @ViewBuilder
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(SumiTheme.muted)
            TextField(filters.placeholder, text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .font(.system(size: 16))
                .foregroundStyle(SumiTheme.foreground)
                .onSubmit {
                    remember(query)
                    Task { await runSearch() }
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(SumiTheme.muted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SumiTheme.border, lineWidth: 1))
        .padding(.horizontal, 16)
    }

    /// One place decides what a search means, for the debounce, the submit
    /// and a filter change alike. An empty query with no filter clears the
    /// results rather than searching for nothing.
    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.appMode == .cinema {
            await model.searchCinema(trimmed)
            return
        }
        if trimmed.isEmpty, !filters.isActive {
            await model.search(query: "")
            return
        }
        await model.search(query: trimmed, mediaType: filters.mediaType, filters: filters.engineFilters)
    }

    /// The filters in force, as chips above the results. A tap on one
    /// clears just that filter; the sheet is for setting them.
    @ViewBuilder
    private var activeFilterChips: some View {
        let active = filters.activeChips
        if !active.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(active, id: \.label) { chip in
                        Button {
                            filters.clear(chip.key)
                        } label: {
                            HStack(spacing: 4) {
                                Text(chip.label)
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                            }
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(SumiTheme.background)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .background(SumiTheme.indigo, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
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

    /// The filter sheet's genres as one tap each. Ecchi is left to the sheet:
    /// this is the first thing the Search tab shows (owner 2026-09-21, "this
    /// app is family friendly").
    private static let browseGenres = PhoneSearchFilters.genreOptions
        .map(\.value)
        .filter { !$0.isEmpty && $0 != "Ecchi" }

    @ViewBuilder
    private var genreChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Genres")
                .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                .foregroundStyle(SumiTheme.muted)
                .padding(.horizontal, 16)
            // Setting the filter is the search: `onChange(of: filters)` runs
            // it, and the chip above the results takes it off again.
            FlowChips(items: Self.browseGenres) { genre in
                filters.genre = genre
            }
            .padding(.horizontal, 16)
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
                Text("Recent")
                    .font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(SumiTheme.muted)
                Spacer()
                Button("Clear") { recentsRaw = "" }
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 16)

            FlowChips(items: recents) { term in
                // Setting the query is enough: the `.task(id:)` debounce
                // runs the search with the filters in force.
                query = term
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
    /// See `ResolvingStreamCard.status` on the Mac: the only place the
    /// engine's phase can show before the player mounts.
    let status: String?
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
                .tint(SumiTheme.indigo)
            VStack(alignment: .leading, spacing: 1) {
                Text(status ?? "Finding a stream…")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(1)
                    .animation(.smooth, value: status)
                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    Text("\(max(0, Int(context.date.timeIntervalSince(startedAt))))s")
                        .font(.system(size: 10.5)).monospacedDigit()
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

struct PosterSection: View {
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

struct PosterGrid: View {
    let items: [MediaCard.Item]
    let onOpen: (MediaCard.Item) -> Void

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 12)]

    /// AniList scores are 0-100; the sheet shows them out of ten.
    static func meta(for item: MediaCard.Item) -> String? {
        var parts: [String] = []
        if let score = item.score, score > 0 {
            // No star glyph in front of it: the house rule bars emoji, and
            // the ones that are not emoji render as one on some faces. The
            // detail hero's meta line already reads "7.3 · 2024 · 12 eps",
            // so this matches it.
            parts.append(String(format: "%.1f", Double(score) / 10))
        }
        if let total = item.totalEpisodesOrChapters, total > 0 {
            parts.append("\(total) \(item.isManga ? "ch" : "eps")")
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
                                .font(.system(size: 10)).monospacedDigit()
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

struct SectionHeader: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(SumiTheme.foreground)
            .padding(.horizontal, 16)
    }
}

struct EmptyHint: View {
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

/// The Mac toast's phone twin: top of the screen under the status bar,
/// two lines, Retry when the failure is one a retry can fix.
private struct PhoneErrorToast: View {
    let message: String
    let retry: (() -> Void)?
    let dismiss: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(SumiTheme.warning)
                    .font(.system(size: 14))

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let retry {
                    Button(action: retry) {
                        Text("Retry")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SumiTheme.indigo)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(SumiTheme.indigo.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    }
                    .buttonStyle(.sumiPressable)
                }

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(SumiTheme.muted)
                        // 44pt target: the Mac's 4pt padding is a click
                        // size, not a thumb size.
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
            .padding(.leading, 16)
            .padding(.trailing, 6)
            .padding(.vertical, 10)
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(SumiTheme.warning.opacity(0.5), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.4), radius: 12, y: 4)
            .padding(.horizontal, 16)
            .padding(.top, 8)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
#endif
