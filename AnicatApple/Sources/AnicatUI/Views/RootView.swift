import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

public struct RootView: View {
    @Bindable public var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotionForPushBack

    private var updatePromptHint: String {
        #if os(macOS)
        if model.canInstallUpdate {
            return "Update now downloads it, quits Anicat and opens the new version."
        }
        #endif
        return "The page has the zip to drop into Applications."
    }
    // Shared between every card grid and the detail page so tapping a card
    // grows its poster into the detail page's poster rather than crossfading
    // two separate images. Which card (if any) actually gets tagged with
    // this namespace is gated per-shelf by `model.openingDetailSourceKey`,
    // not by catalog id alone — see that property's comment for why.
    @Namespace private var cardNamespace
    // Shared between the episode rows (the detail page's and the Up Next
    // shelf's) and the placeholder still inside the player, so pressing Play
    // grows that row's thumbnail into the video frame. Its own namespace
    // rather than more keys in `cardNamespace`: that one is handed over only
    // while a card-driven detail open is in flight, and this morph has to
    // work from a page opened any other way. Gated per-row by
    // `model.openingPlayerSourceKey`, same as the poster morph is by
    // `openingDetailSourceKey`.
    @Namespace private var playerNamespace
    #if os(macOS)
    // Only exit fullscreen on close if we're the one who entered it — if the
    // window was already fullscreen (user did it manually before pressing
    // play), leave it that way when the player closes.
    @State private var enteredFullscreenForPlayback = false

    /// The one-per-session fullscreen enter, after the first frame. Env
    /// switch for a driven test copy: fullscreen would take the screen from
    /// whoever is at the keyboard.
    private func enterFullscreenForPlaybackIfWanted() {
        guard model.activeStreamURL != nil, !enteredFullscreenForPlayback,
              let window = AppWindow.main, !window.styleMask.contains(.fullScreen),
              DebugHooks.env("ANICAT_NO_AUTO_FULLSCREEN") == nil else { return }
        enteredFullscreenForPlayback = true
        FullScreenGuard.set(true, on: window)
    }
    #else
    /// No window fullscreen on iOS; the player's callback has nothing to do.
    private func enterFullscreenForPlaybackIfWanted() {}
    #endif

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        ZStack {
            SumiTheme.background
                .ignoresSafeArea()

            // Ink & Index shell: fixed 200pt sidebar rail + 1px hairline border +
            // full-bleed main column. We deliberately avoid NavigationSplitView,
            // which injects AppKit NSToolbar items, creates floating rounded
            // inset sidebars, and forces top titlebar gaps.
            HStack(spacing: 0) {
                SidebarView(
                    currentView: Binding(
                        get: { model.currentNavSection },
                        set: { section in
                            // Mirror the web `handleNavigate`: closing the
                            // detail page is what lets a sidebar click switch
                            // sections while a title is open. Without it the
                            // detail view keeps rendering because its `if let
                            // details` branch wins over `currentNavSection`.
                            // The person page draws over the detail page and
                            // has to go with it — a sidebar click does not
                            // route through `navigate(to:)`, so clearing it
                            // there alone left a character page mounted over
                            // whichever section was switched to.
                            model.clearPersonPages()
                            model.clearDetail()
                            model.currentNavSection = section
                        }
                    ),
                    mode: model.appMode,
                    modeCaption: model.appMode == .cinema ? "Films and series" : "Anime",
                    // nil hides the switch entirely: with no TMDB key there is
                    // no second world to move to.
                    switchModeCaption: model.cinemaAvailable
                        ? (model.appMode == .cinema ? "anime" : "cinema")
                        : nil,
                    // With no key the mark is still a control, and pressing it
                    // lands on the card that asks for one. Drawn as a plain
                    // watermark instead, the switch was reported as broken by
                    // someone who had no way to tell it was never there.
                    switchModeLocked: !model.cinemaAvailable,
                    // Signed out there is no Watching list to judge by, and
                    // the calendar's global view is the whole point of it.
                    showsSchedule: !model.isSignedIn || model.watchingItems.contains { $0.isAiring },
                    onSwitchMode: {
                        guard model.cinemaAvailable else {
                            model.clearPersonPages()
                            model.clearDetail()
                            model.currentNavSection = .settings
                            return
                        }
                        withAnimation(.smooth(duration: 0.3)) {
                            model.setAppMode(model.appMode == .cinema ? .anime : .cinema)
                        }
                    },
                    onOpenSearchPalette: { model.paletteOpen = true }
                )
                .frame(width: 200)

                // 1px hairline border separating sidebar and main content
                Rectangle()
                    .fill(SumiTheme.border)
                    .frame(width: 1)
                    .ignoresSafeArea()

                // Dynamic Main Content Area
                VStack(spacing: 0) {
                    // Anime mode only: cinema tracks nothing on AniList, and
                    // a film viewer with no account was told a service they
                    // never use was down, on every launch of an outage.
                    if model.isAniListDown, model.appMode == .anime {
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
                    //
                    // sectionContent stays mounted underneath at all times and
                    // MediaDetailView overlays on top of it rather than the two
                    // being mutually-exclusive branches of one `if`. With an
                    // `if`/`else` here, opening or closing the detail page
                    // cross-fades two full-size opaque views (both carry a
                    // near-black SumiTheme.background) simultaneously — at the
                    // transition's midpoint both are ~50% opaque and stacked,
                    // which reads as a black bar fading in/out over the page.
                    // Keeping sectionContent always rendered means only the
                    // detail page's own opacity animates, so closing it reveals
                    // the already-fully-opaque section beneath instantly.
                    ZStack {
                        sectionContent
                            .id(model.currentNavSection)
                            .transition(.opacity)
                            .zIndex(1)
                            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                            .allowsHitTesting(model.selectedMediaDetails == nil)
                            // The feed drops back as the page comes forward,
                            // so the two read as depth rather than as one
                            // picture replacing another. Same gate as the
                            // page's own offset: on a shelf open the poster
                            // this layer holds is one half of a live
                            // `matchedGeometryEffect` pair, and moving it
                            // mid-flight is what the morph is measuring
                            // against.
                            .scaleEffect(isFeedPushedBack ? 0.97 : 1)
                            .opacity(isFeedPushedBack ? 0.8 : 1)
                            // Its own curve, and a bounce-free one. Left to
                            // ride the enclosing transaction it took
                            // `.sumi(.morph)`, whose 0.86 damping is
                            // underdamped by design -- so on close the whole
                            // feed scaled a little past its resting size and
                            // sprang back into place. A spring is right for a
                            // poster being thrown across the screen and wrong
                            // for the wall behind it.
                            //
                            // Closing takes the page's own duration rather
                            // than the longer one it opens with. One gesture
                            // had three finishes -- the page's fade at 0.26,
                            // this at 0.35, the travel somewhere between --
                            // so the feed went on scaling by itself for
                            // ~100ms after the page it was reacting to had
                            // gone. Measured at ~14% of the transition's peak
                            // movement, which is not a tail, it is a second
                            // animation.
                            .animation(
                                isFeedPushedBack
                                    ? .sumi(.page)
                                    : .easeInOut(duration: Self.detailFadeOut),
                                value: isFeedPushedBack
                            )

                        // The detail page replaces the section, inside the
                        // content column. It is not a window-wide overlay: the
                        // sidebar stays visible and stays navigable, which is what
                        // the web build does by rendering it inside <main>.
                        if let details = model.selectedMediaDetails {
                            detailPage(details)
                        }

                        // A character, staff or thread page covers the
                        // detail page it was opened from, in the same
                        // column. `.id` on the top of the stack so a
                        // character -> voice actor -> character chain
                        // re-mounts each time instead of reusing the
                        // previous page's scroll offset and revealed
                        // spoilers.
                        if let page = model.personPageStack.last {
                            PersonPageView(model: model)
                                .id(page.id)
                                .transition(.opacity)
                                .zIndex(3)
                        }
                    }
                    .animation(.smooth(duration: 0.2), value: model.currentNavSection)
                    // No `.animation(value: selectedMediaDetails != nil)` here.
                    // It covered the whole stack, so the feed's push-back was
                    // animated twice over -- once by its own curve and once by
                    // this one, both firing on the same update. Two animations
                    // re-targeting the same property mid-flight is a small
                    // correction right at the end, which is what a close
                    // "tweaking back into place" over a short distance was.
                    // The curve is named where the state changes instead:
                    // `closeDetail`, `clearDetail` and `loadDetail` each wrap
                    // their own mutation, and the transitions carry theirs.
                    .animation(.easeInOut(duration: 0.32), value: model.personPageStack)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()

            // Command palette. Above sections, player, and reader so navigation is accessible anywhere.
            if model.paletteOpen {
                CommandPalette(commands: paletteCommands, onSearchTitles: { query in
                    // The palette searches the world the app is showing. In
                    // cinema mode it used to answer with anime, which is the
                    // one place ⌘K could open a title the mode cannot play.
                    if model.appMode == .cinema {
                        let items = await model.quickSearchCinema(query)
                        return items.map { item in
                            let id = item.id
                            let title = item.title
                            let coverURL = item.coverImageURL
                            let catalog = item.catalog ?? .tmdbMovie
                            let group = catalog == .tmdbMovie ? "Films" : "Series"
                            return CommandPalette.Command(id: "cinema-\(catalog.rawValue)-\(id)", label: title, group: group) {
                                Task { @MainActor in
                                    model.openingDetailSourceKey = nil
                                    await model.openCinemaDetail(
                                        catalog: catalog, id: id, title: title, coverURL: coverURL
                                    )
                                }
                            }
                        }
                    }
                    let items = await model.quickSearchTitles(query)
                    return items.map { item in
                        // See `paletteCommands` below for why this hops back
                        // through `Task { @MainActor in }` rather than
                        // calling `openDetailFor` directly: `Command.action`
                        // is `@Sendable`, so the closure has to cross that
                        // boundary with only Sendable captures.
                        let id = item.id
                        let title = item.title
                        let coverURL = item.coverImageURL
                        let isManga = item.isManga
                        return CommandPalette.Command(id: "title-\(item.id)", label: item.title, group: "Shows") {
                            Task { @MainActor in
                                self.openDetailFor(id: id, title: title, coverURL: coverURL, isManga: isManga)
                            }
                        }
                    }
                }) {
                    withAnimation(.snappy) {
                        model.paletteOpen = false
                    }
                }
                .zIndex(50)
                .transition(.opacity)
            }

            // First launch. Above everything: nothing underneath is
            // meaningful until the viewer has either connected or skipped.
            if model.onboardingOpen {
                OnboardingView(model: model)
                    .zIndex(80)
                    .transition(.opacity)
            }



            // In-App Video Player Overlay — always mounted once a stream is
            // active, minimized or not. See `PlayerView.isMinimized`'s doc
            // comment: wrapping this in `if !model.isPlayerMinimized` (the
            // previous version) unmounted `MpvSurface` entirely on
            // minimize, and its `dismantleNSView` path stops playback — so
            // "Minimize" was indistinguishable from closing the player.
            // Mounted at the press, not at the stream URL, when the play
            // came from a card (`openingPlayerSourceKey`): the resolve takes
            // one to three seconds, and with the mount waiting on the URL
            // nothing on screen moved for that long and then the black, the
            // fly-in and the first frame all landed inside a few hundred
            // milliseconds -- "a jumpscare", the owner's word. Now the card
            // lifts on the press and waits in place with the status line
            // under it; the URL arrives into the already-mounted surface.
            // A play with no card (Downloads, retry) keeps mounting on the
            // URL, so that path is unchanged.
            if model.activeStreamURL != nil
                || (model.resolveStartedAt != nil && model.openingPlayerSourceKey != nil) {
                PlayerView(
                    controller: model.playerController,
                    streamURL: model.activeStreamURL,
                    onClose: {
                        #if os(macOS)
                        NSCursor.setHiddenUntilMouseMoves(false)
                        #endif
                        // Closing during the wait is cancelling the resolve;
                        // there is no stream to stop yet.
                        guard model.activeStreamURL != nil else {
                            model.cancelResolve()
                            return
                        }
                        withAnimation(.smooth) {
                            model.stopPlayback()
                        }
                    },
                    // No `withAnimation` on either of these, and none at the
                    // other two mutation sites in `AnicatApp`: `PlayerView`
                    // owns the minimize curve (see its `minimizeCurve`), and
                    // a `withAnimation(.smooth)` here ran a second
                    // transaction with a different curve against it — the
                    // same mistake `closeDetail`'s comment above records.
                    onMinimize: {
                        #if os(macOS)
                        NSCursor.setHiddenUntilMouseMoves(false)
                        #endif
                        model.isPlayerMinimized = true
                    },
                    isMinimized: model.isPlayerMinimized,
                    onRestore: {
                        model.isPlayerMinimized = false
                    },
                    morphSource: model.openingPlayerSourceKey.map {
                        EpisodeMorphSource(key: $0, namespace: playerNamespace)
                    },
                    morphThumbnailURL: model.openingPlayerThumbnailURL,
                    // After the first frame, and from a runloop turn of its
                    // own, never inside a view update: toggled from the
                    // player's `onAppear` the enter ran in the same
                    // transaction that mounted the player and hid the
                    // traffic lights, and AppKit left an unnamed
                    // screen-sized window behind after the exit (seen live
                    // in the AX window list). The 0.38s delay this replaced
                    // had kept the toggle clear of that by accident.
                    onFirstFrame: {
                        DispatchQueue.main.async { enterFullscreenForPlaybackIfWanted() }
                    }
                )
                // The player measures the window through its own
                // GeometryReader. In a window the safe area is the strip
                // under the transparent title bar, which is visible, so
                // honouring it left the video centred in a box 28pt short
                // and the top bar 28pt taller than the bottom. In fullscreen
                // the safe area is the notch strip, which is not visible, so
                // ignoring it there put the picture 16pt off centre under
                // the housing. Hence: ignored in a window, honoured in
                // fullscreen.
                .ignoresSafeArea(edges: FullScreenState.shared.isFullScreen ? [] : .all)
                // In: nothing. The fade-from-96% that used to be here scaled
                // and cross-faded a view whose content is a `CAMetalLayer`
                // mpv is already drawing into, and 0.38s later the window's
                // own fullscreen zoom started on top of it -- two scales over
                // the same picture, which is what "the entrance is broken"
                // was. The player is what the press asked for; it can simply
                // be there.
                // Out: plain fade; a shrink on the way out fought the detail
                // page morphing back underneath it.
                .transition(.asymmetric(
                    insertion: .identity,
                    removal: .opacity
                ))
                .zIndex(30)
            }

            // The novel reader, over everything, the way the manga reader
            // and the player are. It was a sheet on the novels section, which
            // meant two things: prose read in a 560pt box with the app around
            // it, and a volume opened from a light novel's own page set the
            // session while that section's sheet was nowhere on screen.
            if model.novelReaderOpen {
                SyosetuReaderView(model: model)
                    .transition(.opacity)
                    .zIndex(31)
            }

            // In-App Manga Reader Overlay
            if let session = model.activeReadingSession {
                MangaReaderView(
                    title: session.title,
                    chapterTitle: session.chapterTitle,
                    pageURLs: session.pageURLs,
                    initialPage: session.startPage,
                    onPageChanged: { page in
                        // Recorded as well as advertised: Handoff hands the
                        // page to another device, the registry hands it back
                        // to this one the next time the chapter opens.
                        model.recordReadingPage(
                            chapterId: session.chapterId,
                            page: page,
                            pageCount: session.pageURLs.count
                        )
                        ContinuityManager.shared.advertiseReading(
                            mangaId: session.chapterId,
                            anilistId: session.anilistId,
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

            // A line across the top of the page, not a card dropping in with
            // an amber border and a shadow: that read as a web toast.
            if let error = model.errorMessage {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        Text(error)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(SumiTheme.warning)
                            .lineLimit(2)
                            .sumiTextSelectable()

                        Spacer()

                        // Only for failures retrying might actually fix (a
                        // resolve timeout, a dead candidate) — see
                        // `errorRetryAction`'s doc comment.
                        if let retry = model.errorRetryAction {
                            Button(action: retry) {
                                Text("Retry")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .foregroundColor(SumiTheme.indigo)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                        }

                        Button(action: {
                            withAnimation(.snappy) {
                                model.errorMessage = nil
                                model.errorRetryAction = nil
                            }
                        }) {
                            Text("Dismiss")
                                .font(.system(size: 12.5))
                                .foregroundColor(SumiTheme.muted)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 9)
                    .background(SumiTheme.background)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(SumiTheme.border).frame(height: 1)
                    }
                    .padding(.top, 28)

                    Spacer()
                }
                .transition(.opacity)
                .zIndex(60)
            }

            #if os(macOS)
            // The prompt closes on Update now and the download takes about a
            // minute; with nothing on screen, an episode started in that
            // minute is the one the installer quits.
            if model.isInstallingUpdate, let version = model.availableUpdate?.version {
                VStack {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Updating to \(version). Anicat will quit and reopen.")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.indigo.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 12, y: 4)
                    .padding(.top, 44)
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(60)
            }
            #endif

            // Loading Scrim — suppressed while the player is already up: an
            // episode switch (`resolveAndPlay` from Next/Prev) also drives
            // `isLoading`, and this scrim sits at zIndex 70, above the
            // fullscreen `PlayerView` at 30. Without the guard, pressing Next
            // painted an opaque black scrim over the still-playing video for
            // the whole resolve — indistinguishable from a hang — when
            // `PlayerView`'s own `isBuffering` spinner already covers exactly
            // this case in place, without blacking out the frame underneath.
            if model.isLoading && model.activeStreamURL == nil && model.resolveStartedAt == nil {
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

            // Resolving a stream specifically (not some other loading state)
            // gets real feedback instead of a bare spinner: `resolveStream`
            // is a single opaque FFI call with no intermediate progress, and
            // used to have no ceiling at all — a stalled search or a dead
            // swarm hung here for as long as the viewer was willing to wait,
            // with no indication anything was even happening or a way out
            // short of force-quitting. A line across the top, not a centered
            // modal with a full-screen scrim: a modal in the middle of the
            // screen for something this routine (every single play press
            // shows it, if only for a moment) read as far more alarming than
            // it is, and blocked seeing/using anything else while it waited.
            // Behind an `if`, not an always-present stack: this layer can sit
            // zIndex 70 over the full-size player and its event catcher, and
            // it should be there only while it has something to show.
            if model.resolveStartedAt != nil {
                VStack(spacing: 0) {
                    // Not while the player itself is up for the wait: the status
            // line sits under the card there and this would be the same
            // words twice.
            if let startedAt = model.resolveStartedAt,
               model.activeStreamURL != nil || model.openingPlayerSourceKey == nil {
                        ResolvingStreamCard(
                            startedAt: startedAt,
                            status: model.playerController.resolveStatus,
                            onCancel: { model.cancelResolve() }
                        )
                        .transition(.opacity)
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 28)
                .transition(.opacity)
                .zIndex(70)
            }
        }
        .animation(.smooth, value: model.activeStreamURL != nil)
        .animation(.smooth, value: model.activeReadingSession != nil)
        // No `selectedMediaDetails != nil` entry here: the detail page's own
        // `.animation(..., value: model.selectedMediaDetails != nil)` is scoped
        // directly to the section/detail ZStack above to prevent conflicting curves.
        .animation(.snappy, value: model.errorMessage != nil)
        .animation(.smooth, value: model.isAniListDown)
        .animation(.snappy, value: model.isLoading)
        .animation(.snappy, value: model.paletteOpen)
        // Real sheets rather than cards floating over the window with a
        // scrim, a shadow and a round X: those read as a web modal.
        .sheet(isPresented: $model.shortcutsOpen) {
            KeyboardShortcutsOverlay(mode: model.appMode) { model.shortcutsOpen = false }
        }
        .sheet(isPresented: Binding(
            get: { model.openCinemaPersonId != nil },
            set: { if !$0 { model.openCinemaPersonId = nil } }
        )) {
            if let personId = model.openCinemaPersonId {
                CinemaPersonView(
                    model: model,
                    personId: personId,
                    fallbackName: model.openCinemaPersonName,
                    onDismiss: { model.openCinemaPersonId = nil }
                )
                .frame(width: 720, height: 640)
            }
        }

        .globalKeyboardShortcuts(model: model)
        // `ContinuityManager` broadcasts Handoff activities on every page/time
        // update, but nothing ever received them — Handoff on another device
        // opened straight to the home screen with no idea what was playing.
        // Routed to the detail page rather than straight into playback: every
        // other entry point into a title goes through it too, and forcing
        // playback from a system callback races `resolveAndPlay`'s own resume
        // logic with no user gesture behind it.
        // Once a day at most, and only for a version that has not already
        // been declined -- see `UpdateChecker`. Fired here rather than in
        // `initialize` so a failed or throttled check costs a launch nothing.
        .task { await model.checkForUpdates(force: false) }
        .alert(
            "Anicat \(model.availableUpdate?.version ?? "") is available",
            isPresented: Binding(
                get: { model.updatePromptOpen },
                set: { if !$0 { model.dismissUpdatePrompt() } }
            )
        ) {
            #if os(macOS)
            if model.canInstallUpdate {
                Button("Update now") { Task { await model.installUpdate() } }
            }
            #endif
            Button("Open release page") {
                if let url = model.availableUpdate?.pageURL { Platform.openExternal(url) }
                model.dismissUpdatePrompt()
            }
            Button("Not now", role: .cancel) { model.dismissUpdatePrompt() }
        } message: {
            Text("You are on \(UpdateChecker.currentVersion). \(updatePromptHint)")
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
        .onContinueUserActivity(ContinuityManager.readingActivityType) { activity in
            guard case .reading(let chapterId, let anilistId, _, _, let pageIndex) =
                    ContinuityManager.shared.parseIncomingActivity(activity),
                  let anilistId else { return }
            // Into the chapter and the page, not just the title. The payload
            // has carried both since it was written; this end dropped them
            // and opened the detail page, which is where the reading was
            // *before* the other device started.
            Task { await model.openReadingHandoff(anilistId: anilistId, chapterId: chapterId, page: pageIndex) }
        }
        #if os(macOS)
        // The one gate on the phone remote. `RemoteHost` accepts every
        // connection the Bonjour listener hands it -- most are discovery
        // probes that send nothing -- and only raises this once a device has
        // announced itself with a `hello` it has never seen before.
        .alert(
            "Allow \(RemoteHost.shared.pendingPairing?.deviceName ?? "this iPhone") to control Anicat?",
            isPresented: Binding(
                get: { RemoteHost.shared.pendingPairing != nil },
                // Dismissing without choosing is a refusal, not a deferral:
                // leaving the request pending would have the phone sit on
                // "waiting for approval" until it gave up.
                set: { presented in
                    if !presented { RemoteHost.shared.answerPairing(approved: false) }
                }
            )
        ) {
            Button("Allow") { RemoteHost.shared.answerPairing(approved: true) }
            Button("Don't Allow", role: .cancel) { RemoteHost.shared.answerPairing(approved: false) }
        } message: {
            Text("It can play, pause, seek and change episodes on this Mac. Asked once per device; clear them under Settings, Remote.")
        }
        // Driven off activeStreamURL's nil<->value edge rather than
        // PlayerView's onAppear/onDisappear: that view can be reused or
        // recreated across the transition (it's SwiftUI's call, not ours),
        // so its own appear/disappear isn't a reliable one-shot signal. This
        // edge is unambiguous and fires exactly once per playback session.
        .onChange(of: model.activeStreamURL != nil) { wasPlaying, isPlaying in
            guard let window = AppWindow.main else { return }
            AppWindow.isPlaybackActive = isPlaying
            if isPlaying {
                AppWindow.setToolbarVisible(false)
                // The zoom button's hover menu ("Exit Full Screen / Tile
                // Window") came up over the picture whenever the pointer was
                // left near the top-left as fullscreen began; no traffic
                // lights while a stream is up, so there is nothing to hover.
                AppWindow.setTrafficLightsHidden(true)
                // The pointer is hidden here and not left to the player's
                // own idle timer: a stream started from the phone begins
                // with nobody touching the mouse, so nothing ever moved to
                // start that timer and the cursor sat on the picture for the
                // whole episode. Any real movement brings it straight back.
                NSCursor.setHiddenUntilMouseMoves(true)
                // Fullscreen is entered from `PlayerView.onFirstFrame`, not
                // from here: fired 0.38s after this edge it ran under the
                // card opening into the picture, and fired at the mount it
                // ran inside the mount's own transaction (see the call).
            } else {
                AppWindow.setToolbarVisible(false)
                AppWindow.setTrafficLightsHidden(false)
                NSCursor.setHiddenUntilMouseMoves(false)
                // The flag resets on every close, not only the fullscreen
                // one: left true after a close that found the window
                // already windowed, the next session's enter was refused
                // and the play stayed in a window (seen in the log: a
                // resolve with no "[fullscreen]" line after it).
                let exitFullscreen = wasPlaying && enteredFullscreenForPlayback
                    && window.styleMask.contains(.fullScreen)
                enteredFullscreenForPlayback = false
                if exitFullscreen {
                    FullScreenGuard.set(false, on: window)
                    // Opening and closing streams in quick succession once
                    // left the window in a fullscreen the player had asked
                    // for with no player in it; the exit had been queued
                    // behind an enter that AppKit never reported finished.
                    // One late check re-issues it.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard model.activeStreamURL == nil, let window = AppWindow.main,
                              window.styleMask.contains(.fullScreen) else { return }
                        PlayerLog.write("[fullscreen] still fullscreen 4s after the player closed; exiting again")
                        FullScreenGuard.set(false, on: window)
                    }
                }
            }
        }
        // Not folded into `syncPlaybackSession`, which is otherwise the one
        // place that follows "is an episode playing right now":
        // `KeyboardBacklightDimmer` is `@MainActor` and owns `NSEvent`
        // monitors, while `AppModel` is `@unchecked Sendable` and
        // `syncPlaybackSession` runs on whatever thread mpv's pause observer
        // was on. Reading both values here is also what registers the
        // observation, so the pause edge arrives at all.
        //
        // No `initial: true`: the singleton is built lazily, so firing on
        // appear would run the `dlopen` and the notification registrations
        // at launch for a feature that defaults to off, and the call it
        // would make (`stop()` on a false value) does nothing anyway.
        .onChange(of: model.activeStreamURL != nil && model.playerController.isPlaying) { _, isWatching in
            if isWatching {
                KeyboardBacklightDimmer.shared.start()
            } else {
                KeyboardBacklightDimmer.shared.stop()
            }
        }
        // The keyboard goes out with the chrome rather than on the dimmer's
        // own three-second clock. The controls fading is the stronger
        // signal: it says the picture is what is being looked at, and a lit
        // keyboard under a dark room is the same distraction the chrome was.
        .onChange(of: model.playerController.areControlsVisible) { _, visible in
            guard model.activeStreamURL != nil else { return }
            if visible {
                KeyboardBacklightDimmer.shared.noteChromeShown()
            } else {
                KeyboardBacklightDimmer.shared.dimNow()
            }
        }
        #endif
    }

    // MARK: - Section Content Switcher
    private var sectionContent: some View {
        sectionBody
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.currentNavSection {
        case .upNext:
            // Cinema has no home page: an AniList id and a TMDB id are
            // different numbers for different titles, and its own Home was
            // the Films and Series shelves again. `redirectHomeInCinema`
            // moves the section on; this is the frame in between.
            if model.appMode == .cinema {
                CinemaHomeView(model: model, namespace: cardNamespace, page: .films, focusSearchOnAppear: false)
            } else {
                // Its own View struct, not a computed property here: `homeView`
                // used to inline into this 1198-line body, so any one shelf's
                // array changing (a Watching progress tick from playback, a
                // background refreshAll updating Trending) re-evaluated every
                // other shelf's layout along with it.
                HomeSectionView(
                    model: model,
                    namespace: cardNamespace,
                    playerNamespace: playerNamespace,
                    onOpenDetail: openDetailFor
                )
            }
        case .schedule:
            if model.appMode == .cinema {
                // Not in cinema's rail; reachable only by a stale restored
                // section, and Films is the landing for it.
                CinemaHomeView(model: model, namespace: cardNamespace, page: .films, focusSearchOnAppear: false)
            } else {
            ScheduleView(
                items: model.scheduleItems,
                calendarSlots: model.calendarMonths[AppModel.calendarMonthKey(model.calendarVisibleMonth)] ?? [],
                isCalendarLoading: model.calendarLoadingMonths.contains(AppModel.calendarMonthKey(model.calendarVisibleMonth)),
                onRequestMonth: { month in
                    model.calendarVisibleMonth = month
                    Task { await model.loadCalendarMonth(month) }
                },
                onSelectSlot: { slot in
                    openDetailFor(id: slot.catalogId, title: slot.title, coverURL: URL(string: slot.coverImage), isManga: false)
                }
            ) { item in
                openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: false)
            }
            }
        case .search:
            if model.appMode == .cinema {
                // The same page as Home, with the field focused: TMDB's
                // search takes a query and nothing else, so the formats,
                // genres, sorts and discover grid `SearchView` is built
                // around have nothing to drive here.
                CinemaHomeView(model: model, namespace: cardNamespace, page: .search, focusSearchOnAppear: true)
            } else {
            SearchView(
                searchText: $model.searchQuery,
                results: model.searchResults,
                discoverItems: model.searchDiscoverItems,
                isLoading: model.isLoading,
                namespace: cardNamespace,
                openingSourceKey: model.openingDetailSourceKey,
                onSearchCommit: { q, mediaType, filters in
                    Task { await model.search(query: q, mediaType: mediaType, filters: filters) }
                },
                onSelectMedia: { item, sourceKey in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga, sourceKey: sourceKey)
                },
                onLoadDiscover: { mediaType in
                    Task { await model.loadSearchDiscover(mediaType: mediaType) }
                },
                onShuffle: { mediaType in
                    Task {
                        await model.loadSearchDiscover(mediaType: mediaType)
                        model.searchDiscoverItems.shuffle()
                    }
                },
                hasMorePages: model.searchHasMorePages,
                isLoadingMore: model.isLoadingMoreSearchResults,
                onLoadMore: { q, mediaType, filters in
                    Task {
                        await model.search(
                            query: q, mediaType: mediaType, filters: filters,
                            page: model.searchCurrentPage + 1, append: true
                        )
                    }
                },
                hasMoreDiscoverPages: model.searchDiscoverHasMorePages,
                isLoadingMoreDiscover: model.isLoadingMoreSearchDiscover,
                onLoadMoreDiscover: { mediaType in
                    Task {
                        await model.loadSearchDiscover(
                            mediaType: mediaType,
                            page: model.searchDiscoverPage + 1,
                            append: true
                        )
                    }
                }
            )
            }
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
                onResetOnboarding: {
                    withAnimation(.smooth(duration: 0.4)) {
                        model.onboardingOpen = true
                    }
                },
                onOpenShortcuts: {
                    model.shortcutsOpen = true
                }
            )
        case .library:
            if model.appMode == .cinema {
                CinemaHomeView(model: model, namespace: cardNamespace, page: .watching, focusSearchOnAppear: false)
            } else {
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
                namespace: cardNamespace,
                openingSourceKey: model.openingDetailSourceKey,
                onSelect: {
                    openDetailFor(
                        id: $0.id, title: $0.title, coverURL: $0.coverImageURL,
                        isManga: model.libraryType == "MANGA" || $0.isManga,
                        sourceKey: "library:\($0.id)"
                    )
                }
            )
            }
        case .manga:
            if model.appMode == .cinema {
                CinemaHomeView(model: model, namespace: cardNamespace, page: .films, focusSearchOnAppear: false)
            } else {
            ReadingView(
                config: .manga,
                reading: model.mangaReading,
                planning: model.mangaPlanning,
                trending: model.mangaTrending,
                isSignedIn: model.isSignedIn,
                namespace: cardNamespace,
                openingSourceKey: model.openingDetailSourceKey,
                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true, sourceKey: $1) },
                onRead: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true, sourceKey: $1) },
                onBrowse: { model.currentNavSection = .search },
                onRemove: { item in Task { await model.removeListEntry(of: item) } }
            )
            }
        case .novels:
            if model.appMode == .cinema {
                CinemaHomeView(model: model, namespace: cardNamespace, page: .series, focusSearchOnAppear: false)
            } else {
            ReadingView(
                config: .novels,
                reading: model.novelReading,
                planning: model.novelPlanning,
                trending: model.novelTrending,
                isSignedIn: model.isSignedIn,
                namespace: cardNamespace,
                openingSourceKey: model.openingDetailSourceKey,
                onSelect: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true, sourceKey: $1) },
                onRead: { openDetailFor(id: $0.id, title: $0.title, coverURL: $0.coverImageURL, isManga: true, sourceKey: $1) },
                onBrowse: { model.currentNavSection = .search },
                // AniList/RanobeDB entries above have no linked text source
                // yet (see `AppModel.SyosetuSession`'s comment) — this is the
                // only way into a novel's actual chapter text today.
                onOpenSyosetu: { model.openNovelReaderEntry() },
                onRemove: { item in Task { await model.removeListEntry(of: item) } }
            )
            }
        case .history:
            HistoryView(
                // No AniList profile on a cinema page: the header would be
                // somebody's anime statistics over a page of films.
                viewer: model.appMode == .cinema ? nil : model.viewer,
                activity: model.appMode == .cinema ? model.cinemaActivity : model.activity,
                // Chapters belong in the anime-mode log: they are the same
                // registry and the same question, "what did I read or watch".
                reading: model.appMode == .cinema ? [] : model.readingActivity,
                titleFor: { catalog, id in model.registryTitle(catalog: catalog, id: id) },
                namespace: cardNamespace,
                openingSourceKey: model.openingDetailSourceKey,
                onSelectFavourite: { item in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga, sourceKey: "history-fav:\(item.id)")
                },
                onOpenTitle: { id, title, catalog in
                    openRegistryTitle(id: id, title: title, catalog: catalog)
                },
                onRemoveActivity: { row in
                    Task { await model.removeWatch(row) }
                },
                onClearHistory: {
                    Task { await model.clearWatchHistory() }
                }
            )
        case .stats:
            StatsView(
                stats: model.watchStatsSnapshot,
                recentStats: model.watchStatsRecentSnapshot,
                titleFor: { catalog, id in model.registryTitle(catalog: catalog, id: id) },
                coverFor: { catalog, id in model.registryCover(catalog: catalog, id: id) },
                // Reloaded on every entry into the section and nowhere else.
                // The other obvious trigger is "after progress is recorded",
                // which lives in the playback path; every panel here but the
                // streak has a day's resolution, so an open is soon enough.
                onLoad: { model.loadWatchStats() },
                onSelectTitle: { id, title, catalog in
                    openRegistryTitle(id: id, title: title, catalog: catalog)
                },
                onResolveTitle: { id in model.ensureKnownTitle(id) }
            )
        case .downloads:
            DownloadsView(
                downloads: model.libraryDownloads,
                onPlay: { download in
                    // The file that finished, not a fresh resolve: routed
                    // through `playEpisode` this searched the indexers again
                    // and streamed whichever release won, so what played had
                    // nothing to do with the row's own file.
                    Task { await model.playDownloadedFile(download) }
                },
                onRemove: { download in
                    model.libraryDownloads.removeAll { $0.id == download.id }
                },
                chapters: model.offlineChapters,
                chapterBytes: model.offlineBytes,
                chapterCapBytes: model.offlineCapBytes,
                titles: model.knownTitles,
                onRemoveChapter: { model.deleteOfflineChapter($0) }
            )
            .task { model.loadOfflineChapters() }
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


    /// Opens the detail page, querying the Rust core via UniFFI.
    // `sourceKey` is nil unless the caller can name exactly which card grid
    // it came from (e.g. "watching:12345") — relation/recommendation clicks
    // inside the detail page, schedule taps, and any other non-card open
    // leave it nil, which just means a plain fade with no poster morph.
    /// Opens a row that came out of the registry -- History, Stats -- where
    /// the id is whatever catalog recorded it. In cinema mode that is TMDB's,
    /// and sending it to `openDetailFor` opened the anime with that number.
    /// Opens a row that came out of the local registry — History, Stats.
    ///
    /// Routed by the row's own catalog, never by the mode showing or by the
    /// id alone. Reading the mode sent a TMDB row in the anime History to
    /// AniList, where 129552 is an unrelated manga rather than The Night
    /// Agent; and `cinemaCatalog(forId:)` answers `.tmdbMovie` for any id
    /// absent from the resume queue, so a series watched once and since
    /// fallen off it opened as a film.
    /// The detail page, lifted out of `body`.
    ///
    /// Not a style choice: with everything it takes inline, the enclosing
    /// builder passed the point where the type-checker gives up -- "unable
    /// to type-check this expression in reasonable time". `MediaDetailView`
    /// splits its own tabs out for the same reason; this is that boundary
    /// one level up.
    @ViewBuilder
    private func detailPage(_ details: HeroBanner.Details) -> some View {
                        let novelState = MediaDetailView.NovelTabState(
                            volumes: model.novelVolumes,
                            isLoading: model.isLoadingNovelVolumes,
                            sourceMissing: model.novelSourceMissing
                        )
                        MediaDetailView(
                            details: details,
                            episodes: model.selectedEpisodes,
                            mangaChapters: model.selectedMangaChapters,
                            novel: novelState,
                            onReadVolume: readNovelVolume,
                            characters: model.selectedCharacters,
                            relations: model.selectedRelations,
                            recommendations: model.selectedRecommendations,
                            discussions: model.selectedDiscussions,
                            isLoading: model.isDetailLoading,
                            tracksOnAniList: model.currentDetailCatalog == .anilist,
                            cinemaExtras: model.cinemaExtras,
                            isCinemaExtrasLoading: model.isCinemaExtrasLoading,
                            cinemaListStatus: model.cinemaListStatus,
                            chapterOfflineStates: model.chapterOfflineStates,
                            onDownloadChapter: { model.downloadChapter($0) },
                            onDeleteChapterDownload: { model.deleteChapterDownload($0) },
                            novelVolumeStates: model.novelVolumeStates,
                            onDownloadVolume: { model.downloadNovelVolume($0) },
                            onDeleteVolumeDownload: { model.deleteNovelVolumeDownload($0) },
                            onExportVolume: { model.exportNovelVolume($0) },
                            onSetCinemaListStatus: { model.setCinemaListStatus($0) },
                            onPlayEpisode: { ep in
                                playEpisode(
                                    model: model, catalogId: details.id, episode: ep.number, title: details.title,
                                    catalog: model.playbackCatalogForOpenDetail,
                                    morphKey: MediaDetailView.playerMorphKey(catalogId: details.id, episode: ep.number),
                                    morphThumbnailURL: ep.thumbnailURL
                                )
                            },
                            onPlayEpisodeFromStart: { ep in
                                playEpisode(
                                    model: model, catalogId: details.id, episode: ep.number, title: details.title,
                                    catalog: model.playbackCatalogForOpenDetail, fromStart: true,
                                    morphKey: MediaDetailView.playerMorphKey(catalogId: details.id, episode: ep.number),
                                    morphThumbnailURL: ep.thumbnailURL
                                )
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
                                let isManga: Bool
                                if let fmt = rel.format {
                                    isManga = AppModel.isMangaFormat(fmt)
                                } else {
                                    isManga = AppModel.isMangaFormat(details.format)
                                }
                                openDetailFor(
                                    id: rel.id,
                                    title: rel.title,
                                    coverURL: rel.coverURL,
                                    isManga: isManga
                                )
                            },
                            onSelectMediaId: { id, title, coverURL, isManga in
                                // TMDB recommends films for a film and
                                // series for a series, so a pick here
                                // belongs to the page's own catalog --
                                // sent through `openDetailFor` it opened
                                // whatever anime carries that number.
                                if model.currentDetailCatalog != .anilist {
                                    Task {
                                        await model.openCinemaDetail(
                                            catalog: model.currentDetailCatalog,
                                            id: id,
                                            title: title,
                                            coverURL: coverURL
                                        )
                                    }
                                } else {
                                    openDetailFor(
                                        id: id,
                                        title: title,
                                        coverURL: coverURL,
                                        isManga: isManga
                                    )
                                }
                            },
                            onSelectCharacter: { id in
                                // A cinema page's cast are TMDB people;
                                // `openCharacter` is AniList's and would
                                // look this id up in the wrong catalog.
                                selectCharacter(id)
                            },
                            onSelectThread: { model.openThread(id: $0) },
                            // Not wrapped in `withAnimation` here:
                            // `closeDetail()` animates its own mutation
                            // internally (see AppModel). Wrapping it again at
                            // every call site raced a second transaction
                            // against the first with a different curve —
                            // that's what read as "jitters, stops, pops
                            // away," worse the faster it was retriggered.
                            onClose: {
                                model.closeDetail()
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
                                playEpisode(
                                    model: model, catalogId: details.id, episode: ep.number, title: details.title, chosenName: releaseName,
                                    morphKey: MediaDetailView.playerMorphKey(catalogId: details.id, episode: ep.number),
                                    morphThumbnailURL: ep.thumbnailURL
                                )
                            },
                            onDownloadEpisode: { ep in
                                Task { await model.startDownload(episode: ep.number) }
                            },
                            downloadStates: { model.downloadStates },
                            namespace: model.openingDetailSourceKey != nil ? cardNamespace : nil,
                            playerNamespace: playerNamespace,
                            playerSourceKey: model.openingPlayerSourceKey,
                            restoredTab: model.restoredDetailTab,
                            onTabChanged: { model.currentDetailTab = $0 }
                        )
                        .id(details.id)
                        .sumiTransition(detailTransition)
                        .zIndex(2)
                        // Same reason `sectionContent` is gated on the
                        // detail page: the detail page stays mounted
                        // under an open character/staff/thread page, so
                        // without this its cards keep taking clicks and
                        // hover through the page covering them.
                        .allowsHitTesting(!model.isPersonPageOpen)
    }

    /// Extracted for the same type-checking reason as `readNovelVolume`.
    /// A character on a TMDB page is a cast member, and `openCharacter`
    /// would look the id up in the wrong catalog.
    private func selectCharacter(_ id: Int64) {
        if model.currentDetailCatalog == .anilist {
            model.openCharacter(id: id)
        } else {
            let name = model.selectedCharacters.first { $0.id == id }?.name ?? ""
            model.openCinemaPerson(id: id, name: name)
        }
    }

    /// Extracted rather than written inline at the call site: adding a
    /// closure literal to `MediaDetailView`'s initializer took it past
    /// "unable to type-check this expression in reasonable time".
    private func readNovelVolume(_ volume: NovelChapterRef) {
        model.openLightNovelVolume(bookURL: volume.url, title: volume.title)
    }

    private func openRegistryTitle(id: Int64, title: String?, catalog: FfiCatalog) {
        switch catalog {
        case .tmdbMovie, .tmdbTv:
            let card: MediaCard.CardCatalog = catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv
            Task {
                await model.openCinemaDetail(
                    catalog: card,
                    id: id,
                    title: title ?? model.cinemaKnownTitles[AppModel.CinemaTitleKey(catalog: card, id: id)],
                    coverURL: model.cinemaKnownCovers[AppModel.CinemaTitleKey(catalog: card, id: id)]
                )
            }
        case .anilist, .mangaDex:
            openDetailFor(id: id, title: title ?? "", coverURL: model.knownCovers[id], isManga: false)
        }
    }

    /// How the detail page enters and leaves.
    ///
    /// **The fade is deliberately much shorter than the transition.** Both the
    /// page and the feed are opaque and near-black, so an opacity curve that
    /// ran for the whole spring left the two legible on top of each other for
    /// its entire length -- Up Next's rows readable straight through the
    /// synopsis. That reads as a ghost, not as a navigation. Giving the
    /// opacity its own curve collapses the overlap to a few frames while the
    /// poster morph and the feed's push-back keep the full spring.
    ///
    /// The offset is only for an open with no poster to morph -- Up Next's
    /// rows, the schedule, the command palette. Without it those opens had no
    /// motion at all beyond the fade, so the page simply appeared. On a shelf
    /// open the poster is mid-`matchedGeometryEffect` inside this view, and
    /// moving the page moves the thing the morph is interpolating towards.
    /// How long everything that leaves with the detail page takes. Named once
    /// because the page's fade, its travel and the feed's push-back all have
    /// to land on the same frame; three separate literals is how they drifted
    /// apart in the first place.
    /// Scaled by `MotionPolicy.slowMotion` for the same reason the springs
    /// are: an unscaled 0.26s fade against an 8x spring shows the poster
    /// vanishing mid-flight at every setting, which is an artefact of the
    /// instrument rather than the transition.
    /// Longer than `.sumi(.morphReturn)`, and by the ratio documented
    /// there -- roughly 0.58 -- not merely longer: the poster morphing back
    /// into its card lives inside the page this fade removes, so it has to
    /// land while the fade has left it enough opacity to be seen arriving.
    /// Lengthening one of the two alone is what makes the card look like it
    /// snaps into place.
    static let detailFadeOut: Double = 0.33 * MotionPolicy.slowMotion

    private var detailTransition: AnyTransition {
        // Asymmetric, because the two directions have opposite problems.
        // Arriving, the page has to cover the feed fast or the two are
        // readable at once. Leaving, there is nothing to cover -- the feed is
        // already opaque underneath -- so the same short curve just made the
        // page blink out. It goes at nearly twice the length on the way out,
        // which is long enough to read as receding and still short enough
        // that the overlap never becomes a dissolve.
        let arrive = AnyTransition.opacity.animation(.easeOut(duration: 0.14 * MotionPolicy.slowMotion))
        let leave = AnyTransition.opacity.animation(.easeInOut(duration: Self.detailFadeOut))
        guard model.openingDetailSourceKey == nil else {
            return .asymmetric(insertion: arrive, removal: leave)
        }
        // The travel is bounce-free for the same reason the feed's is: a page
        // that settles past its resting position and comes back reads as a
        // wobble, not as a page.
        //
        // Page to page (a relation, Back, Forward) it used to rise from below
        // like an open from the feed, so a sideways swipe was answered with
        // vertical motion. It comes from the side the swipe points to, a
        // right swipe being Back. Both stacks are empty when a page opens from
        // the feed (and after a step taken mid-load, which skips the push).
        // The removal cannot follow suit: a leaving view keeps the transition
        // of its last render, before the step was known.
        let travel: AnyTransition = model.detailHistory.isEmpty && model.detailForwardStack.isEmpty
            ? .offset(y: 24)
            : .offset(x: model.detailSteppedBack ? -24 : 24)
        return .asymmetric(
            insertion: travel.animation(.sumi(.page)).combined(with: arrive),
            // Less travel than it arrived with: a page being dismissed that
            // slides as far as it came reads as being thrown away rather than
            // as the layer above closing.
            // Same curve as the fade, not merely the same length: a shape
            // that eases differently drifts against it and lands early.
            removal: AnyTransition.offset(y: 14)
                .animation(.easeInOut(duration: Self.detailFadeOut))
                .combined(with: leave)
        )
    }

    /// Whether the section behind an open detail page is pushed back.
    ///
    /// Never under Reduce Motion: the setting is read live from the
    /// environment rather than through `MotionPolicy`, whose cached flag a
    /// view body does not re-read when the system setting changes.
    private var isFeedPushedBack: Bool {
        !reduceMotionForPushBack
            && model.selectedMediaDetails != nil
            && model.openingDetailSourceKey == nil
    }

    private func openDetailFor(id: Int64, title: String, coverURL: URL?, isManga: Bool = false, sourceKey: String? = nil) {
        // Every navigation to a *different* title funnels through here (a
        // relation, a recommendation, a command-palette pick). A character
        // page draws over the detail page, so without this a palette pick
        // made from one left that character standing over the new title.
        model.clearPersonPages()
        model.openingDetailSourceKey = sourceKey
        Task { await model.openDetail(id: id, title: title, coverURL: coverURL, isManga: isManga) }
    }

}

/// A shelf's Play/Resume button: open the show's page first, then start the
/// stream on top of it. Closing the player then lands on the episode list of
/// what was just watched instead of back on the home feed, and a resolve
/// failure has the page it belongs to underneath it rather than a shelf.
///
/// It also means `resolveAndPlay` finds the title's episodes in
/// `selectedEpisodes` and skips the detail fetch `ensurePlaybackEpisodes`
/// would otherwise make for a play with no page open.
/// Shared with the menu bar's Resume: every shelf-style play goes through
/// the show's page first, so the two entry points cannot drift apart.
/// `morphThumbnailURL` is the shelf row's still, when the caller has one on
/// screen — the menu bar's Resume does not, and leaves it nil for a plain
/// fade.
@MainActor
public func playFromShelf(
    model: AppModel,
    catalogId: Int64,
    episode: Int,
    title: String,
    coverURL: URL?,
    morphThumbnailURL: URL? = nil
) {
    // No poster morph on this path, deliberately: `UpNextQueueView` hands
    // its rows no namespace (its 104x60 landscape thumbnail interpolated
    // into a portrait poster reads as a squash), so a source key set here
    // would name a `matchedGeometryEffect` source that does not exist.
    model.openingDetailSourceKey = nil
    // The player morph does not have that mismatch — landscape still into a
    // landscape video frame — so it is wired. Set here rather than left to
    // `playEpisode` below: this function opens the show's page first and can
    // return before ever reaching it, and the flight starts from the shelf
    // row, which by then is mounted but covered by that page. The placeholder
    // is drawn above the page (the player is at zIndex 30), so the flight
    // itself is visible; only its origin is not.
    let morphKey = morphThumbnailURL.map { _ in
        UpNextQueueView.playerMorphKey(catalogId: catalogId, episode: episode)
    }
    // Cleared up front rather than by `playEpisode` on success: this
    // function can return before ever reaching it (cancelled during the page
    // load), and a Retry left over from an earlier failure would then re-run
    // that older attempt against a page the viewer has since left.
    model.errorRetryAction = nil
    model.activeResolveTask = Task {
        await model.openDetail(id: catalogId, title: title, coverURL: coverURL, isManga: false)
        // Cancel pressed while the page was still loading. Without this the
        // resolve below still ran to completion — `resolveAndPlay` only
        // checks cancellation after its 120s-budget FFI call returns.
        guard !Task.isCancelled else { return }
        // Replaces `activeResolveTask` with the resolve's own task, so Cancel
        // targets whichever of the two stages is actually running.
        playEpisode(
            model: model, catalogId: catalogId, episode: episode, title: title,
            morphKey: morphKey, morphThumbnailURL: morphThumbnailURL
        )
    }
}

/// Shared by every `resolveAndPlay` call site (across both `RootView` and
/// `HomeSectionView`) so the error banner's Retry button
/// (`AppModel.errorRetryAction`) can re-run the exact same attempt rather
/// than each site wiring its own retry closure by hand.
/// `morphKey`/`morphThumbnailURL` name the row that was pressed, when there
/// was one — its still is what flies into the video frame. Assigned here
/// including the nil case, rather than only where a row exists: a play from
/// somewhere with no row at all (Downloads, the retry closure) would
/// otherwise inherit whatever the last play left set and fly a stale still.
@MainActor
private func playEpisode(
    model: AppModel,
    catalogId: Int64,
    episode: Int,
    title: String,
    catalog: FfiCatalog = .anilist,
    chosenName: String? = nil,
    fromStart: Bool = false,
    morphKey: String? = nil,
    morphThumbnailURL: URL? = nil
) {
    // An episode AniList has announced but not aired has nothing behind it,
    // and every path into it -- the page's rows, Up Next, the phone -- comes
    // through here. Said plainly rather than as a two-minute search ending in
    // "No HD torrent found".
    if model.selectedMediaDetails?.id == catalogId,
       let row = model.selectedEpisodes.first(where: { $0.number == episode }),
       !row.isAired {
        model.errorMessage = "Episode \(episode) has not aired yet."
        model.playFeedback(.error)
        return
    }
    model.openingPlayerSourceKey = morphKey
    model.openingPlayerThumbnailURL = morphThumbnailURL
    // A file already on the disk beats the swarm. Without this the only
    // place a download was ever used was next/prev inside the player: every
    // press of Play on the page re-resolved and re-fetched an episode the
    // viewer had explicitly downloaded.
    if let download = model.finishedDownload(
        catalog: catalog == .anilist ? .anilist : (catalog == .tmdbMovie ? .tmdbMovie : .tmdbTv),
        catalogId: catalogId,
        episode: episode
    ) {
        model.activeResolveTask = Task { await model.playDownloadedFile(download) }
        return
    }
    model.activeResolveTask = Task {
        do {
            _ = try await model.resolveAndPlay(
                catalog: catalog,
                catalogId: catalogId,
                episode: Int64(episode),
                title: title,
                chosenName: chosenName,
                fromStart: fromStart
            )
            model.errorRetryAction = nil
        } catch is CancellationError {
            // The viewer hit Cancel on the "Finding a stream…" overlay —
            // not a real failure.
        } catch {
            model.errorMessage = error.localizedDescription
            model.errorRetryAction = { [weak model] in
                model?.errorMessage = nil
                guard let model else { return }
                playEpisode(
                    model: model,
                    catalogId: catalogId,
                    episode: episode,
                    title: title,
                    catalog: catalog,
                    chosenName: chosenName,
                    fromStart: fromStart
                )
            }
        }
    }
}

extension View {
    fileprivate func globalKeyboardShortcuts(model: AppModel) -> some View {
        #if os(macOS)
        self.modifier(GlobalKeyboardShortcutsModifier(model: model))
        #else
        self
        #endif
    }
}
