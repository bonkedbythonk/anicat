import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

public struct RootView: View {
    @Bindable public var model: AppModel
    @State private var showSyosetuReader = false
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
                                isLoading: model.isDetailLoading,
                                onPlayEpisode: { ep in
                                    playEpisode(
                                        model: model, catalogId: details.id, episode: ep.number, title: details.title,
                                        morphKey: MediaDetailView.playerMorphKey(catalogId: details.id, episode: ep.number),
                                        morphThumbnailURL: ep.thumbnailURL
                                    )
                                },
                                onPlayEpisodeFromStart: { ep in
                                    playEpisode(
                                        model: model, catalogId: details.id, episode: ep.number, title: details.title, fromStart: true,
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
                                    openDetailFor(
                                        id: id,
                                        title: title,
                                        coverURL: coverURL,
                                        isManga: isManga
                                    )
                                },
                                onExportAppleBooks: {},
                                onSelectCharacter: { model.openCharacter(id: $0) },
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
                                downloadStates: model.downloadStates,
                                namespace: model.openingDetailSourceKey != nil ? cardNamespace : nil,
                                playerNamespace: playerNamespace,
                                playerSourceKey: model.openingPlayerSourceKey,
                                restoredTab: model.restoredDetailTab,
                                onTabChanged: { model.currentDetailTab = $0 }
                            )
                            .id(details.id)
                            .transition(.opacity)
                            .zIndex(2)
                            // Same reason `sectionContent` is gated on the
                            // detail page: the detail page stays mounted
                            // under an open character/staff/thread page, so
                            // without this its cards keep taking clicks and
                            // hover through the page covering them.
                            .allowsHitTesting(!model.isPersonPageOpen)
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
                    .animation(.easeInOut(duration: 0.32), value: model.selectedMediaDetails != nil)
                    .animation(.easeInOut(duration: 0.32), value: model.personPageStack)
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            }
            .ignoresSafeArea()

            // Command palette. Above sections, player, and reader so navigation is accessible anywhere.
            if model.paletteOpen {
                CommandPalette(commands: paletteCommands, onSearchTitles: { query in
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

            // Keyboard shortcuts overlay. Above palette and modal views.
            if model.shortcutsOpen {
                KeyboardShortcutsOverlay {
                    withAnimation(.snappy) {
                        model.shortcutsOpen = false
                    }
                }
                .zIndex(60)
                .transition(.opacity)
            }


            // In-App Video Player Overlay — always mounted once a stream is
            // active, minimized or not. See `PlayerView.isMinimized`'s doc
            // comment: wrapping this in `if !model.isPlayerMinimized` (the
            // previous version) unmounted `MpvSurface` entirely on
            // minimize, and its `dismantleNSView` path stops playback — so
            // "Minimize" was indistinguishable from closing the player.
            if let streamURL = model.activeStreamURL {
                PlayerView(
                    controller: model.playerController,
                    streamURL: streamURL,
                    onClose: {
                        #if os(macOS)
                        NSCursor.setHiddenUntilMouseMoves(false)
                        #endif
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
                    morphThumbnailURL: model.openingPlayerThumbnailURL
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
                // In: fade up from 96%, the window's fullscreen zoom taking
                // over as it lands (see the delayed `FullScreenGuard.set`).
                // Out: plain fade; a shrink on the way out fought the
                // detail page morphing back underneath it.
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.96)),
                    removal: .opacity
                ))
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
                            .textSelection(.enabled)

                        Spacer()

                        // Only for failures retrying might actually fix (a
                        // resolve timeout, a dead candidate) — see
                        // `errorRetryAction`'s doc comment.
                        if let retry = model.errorRetryAction {
                            Button(action: retry) {
                                Text("Retry")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(SumiTheme.indigo)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .background(SumiTheme.indigo.opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                            }
                            .buttonStyle(.sumiPressable)
                        }

                        Button(action: {
                            withAnimation(.snappy) {
                                model.errorMessage = nil
                                model.errorRetryAction = nil
                            }
                        }) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(SumiTheme.muted)
                                .padding(4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
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
            // short of force-quitting. A small corner toast, not a centered
            // modal with a full-screen scrim: a modal in the middle of the
            // screen for something this routine (every single play press
            // shows it, if only for a moment) read as far more alarming than
            // it is, and blocked seeing/using anything else while it waited.
            if let startedAt = model.resolveStartedAt {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        ResolvingStreamCard(
                            startedAt: startedAt,
                            onCancel: { model.cancelResolve() }
                        )
                        .padding(.trailing, 24)
                        .padding(.bottom, 24)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .animation(.snappy, value: model.shortcutsOpen)

        .globalKeyboardShortcuts(model: model)
        // `ContinuityManager` broadcasts Handoff activities on every page/time
        // update, but nothing ever received them — Handoff on another device
        // opened straight to the home screen with no idea what was playing.
        // Routed to the detail page rather than straight into playback: every
        // other entry point into a title goes through it too, and forcing
        // playback from a system callback races `resolveAndPlay`'s own resume
        // logic with no user gesture behind it.
        .onContinueUserActivity(ContinuityManager.playbackActivityType) { activity in
            guard case .playback(let catalogId, _, _, _) = ContinuityManager.shared.parseIncomingActivity(activity) else { return }
            Task { await model.openDetail(id: catalogId, isManga: false) }
        }
        .onContinueUserActivity(ContinuityManager.readingActivityType) { activity in
            guard case .reading(_, let anilistId, _, _, _) = ContinuityManager.shared.parseIncomingActivity(activity),
                  let anilistId else { return }
            Task { await model.openDetail(id: anilistId, isManga: true) }
        }
        #if os(macOS)
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
                // Env switch for a driven test copy: fullscreen would take
                // the screen from whoever is at the keyboard.
                if !wasPlaying, !window.styleMask.contains(.fullScreen),
                   ProcessInfo.processInfo.environment["ANICAT_NO_AUTO_FULLSCREEN"] == nil {
                    enteredFullscreenForPlayback = true
                    // After the player's own entrance, not on top of it: the
                    // fade-and-scale in and the window's fullscreen zoom
                    // running together read as two animations fighting.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.38) {
                        guard model.activeStreamURL != nil, let window = AppWindow.main else { return }
                        FullScreenGuard.set(true, on: window)
                    }
                }
            } else {
                AppWindow.setToolbarVisible(false)
                AppWindow.setTrafficLightsHidden(false)
                NSCursor.setHiddenUntilMouseMoves(false)
                if wasPlaying, enteredFullscreenForPlayback, window.styleMask.contains(.fullScreen) {
                    FullScreenGuard.set(false, on: window)
                    enteredFullscreenForPlayback = false
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
        #endif
    }

    // MARK: - Section Content Switcher
    private var sectionContent: some View {
        // The slide has to wrap the switch rather than sit beside the `.id`
        // above: an `AnyTransition` declared here would lose to the one the
        // identified view already carries, and a wrapper placed outside the
        // `.id` is not what this property returns.
        SectionSlide(index: model.currentNavSection.displayIndex) {
            sectionBody
        }
    }

    @ViewBuilder
    private var sectionBody: some View {
        switch model.currentNavSection {
        case .upNext:
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
        case .schedule:
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
        case .search:
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
        case .manga:
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
                onBrowse: { model.currentNavSection = .search }
            )
        case .novels:
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
                onOpenSyosetu: { showSyosetuReader = true }
            )
            .sheet(isPresented: $showSyosetuReader) {
                SyosetuReaderView(model: model)
                    .frame(minWidth: 560, minHeight: 640)
            }
        case .history:
            HistoryView(
                viewer: model.viewer,
                activity: model.activity,
                titles: model.knownTitles,
                namespace: cardNamespace,
                openingSourceKey: model.openingDetailSourceKey,
                onSelectFavourite: { item in
                    openDetailFor(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: item.isManga, sourceKey: "history-fav:\(item.id)")
                },
                onOpenTitle: { id, title in
                    openDetailFor(id: id, title: title ?? "", coverURL: model.knownCovers[id], isManga: false)
                }
            )
        case .stats:
            StatsView(
                stats: model.watchStatsSnapshot,
                recentStats: model.watchStatsRecentSnapshot,
                knownTitles: model.knownTitles,
                knownCovers: model.knownCovers,
                // Reloaded on every entry into the section and nowhere else.
                // The other obvious trigger is "after progress is recorded",
                // which lives in the playback path; every panel here but the
                // streak has a day's resolution, so an open is soon enough.
                onLoad: { model.loadWatchStats() },
                onSelectTitle: { id, title in
                    openDetailFor(id: id, title: title ?? "", coverURL: model.knownCovers[id], isManga: false)
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
                }
            )
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
private func playEpisode(
    model: AppModel,
    catalogId: Int64,
    episode: Int,
    title: String,
    chosenName: String? = nil,
    fromStart: Bool = false,
    morphKey: String? = nil,
    morphThumbnailURL: URL? = nil
) {
    model.openingPlayerSourceKey = morphKey
    model.openingPlayerThumbnailURL = morphThumbnailURL
    model.activeResolveTask = Task {
        do {
            _ = try await model.resolveAndPlay(
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
            model.errorMessage = "Failed to play episode \(episode): \(error.localizedDescription)"
            model.errorRetryAction = { [weak model] in
                model?.errorMessage = nil
                guard let model else { return }
                playEpisode(
                    model: model,
                    catalogId: catalogId,
                    episode: episode,
                    title: title,
                    chosenName: chosenName,
                    fromStart: fromStart
                )
            }
        }
    }
}

/// The `.upNext` section: queue, week strip, Watching, and every configurable
/// discover row. Pulled out of `RootView.sectionContent` because it used to
/// be a computed property inlined into the 1198-line body — any one shelf's
/// array changing (a Watching progress tick from playback, a background
/// refreshAll updating Trending) re-evaluated every other shelf's layout
/// along with it. Own `@State` for the two sheets it owns, since neither is
/// read outside this section.
private struct HomeSectionView: View {
    @Bindable var model: AppModel
    let namespace: Namespace.ID
    /// The episode-still-to-video namespace, for the Up Next shelf's Play.
    let playerNamespace: Namespace.ID
    // 5th arg is the shelf-scoped source key for the poster morph (e.g.
    // "watching:12345"), nil where there's no card to morph from.
    let onOpenDetail: (Int64, String, URL?, Bool, String?) -> Void

    @State private var showHomeCustomize = false
    /// Up Next shows four rows until asked for the rest: eight or more
    /// in-progress titles pushed the week strip and every shelf below the
    /// fold, and the first row is the one that gets played anyway.
    @State private var upNextExpanded = false
    private static let upNextCollapsedCount = 4
    @State private var showPicker = false

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

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: 40) {
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
                        .buttonStyle(.sumiPressable)

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
                        .buttonStyle(.sumiPressable)
                    }

                    // Up Next Queue Container
                    if !model.upNextItems.isEmpty {
                        UpNextQueueView(
                            items: upNextExpanded ? model.upNextItems : Array(model.upNextItems.prefix(Self.upNextCollapsedCount)),
                            namespace: namespace,
                            openingSourceKey: model.openingDetailSourceKey,
                            shelfKey: "upnext",
                            playerNamespace: playerNamespace,
                            playerSourceKey: model.openingPlayerSourceKey,
                            onSelect: { entry in
                                onOpenDetail(entry.id, entry.title, entry.thumbnailURL, entry.unit == "CH", "upnext:\(entry.id)")
                            },
                            onPlay: { entry in
                                if entry.unit == "CH" {
                                    onOpenDetail(entry.id, entry.title, entry.thumbnailURL, true, "upnext:\(entry.id)")
                                } else {
                                    playFromShelf(
                                        model: model,
                                        catalogId: entry.id,
                                        episode: entry.nextEpisodeOrChapter,
                                        title: entry.title,
                                        coverURL: entry.thumbnailURL,
                                        morphThumbnailURL: entry.thumbnailURL
                                    )
                                }
                            }
                        )
                        if model.upNextItems.count > Self.upNextCollapsedCount {
                            Button {
                                withAnimation(.smooth(duration: 0.35)) { upNextExpanded.toggle() }
                            } label: {
                                HStack(spacing: 6) {
                                    Text(upNextExpanded ? "Show fewer" : "Show all \(model.upNextItems.count)")
                                        .font(.system(size: 12.5, weight: .semibold))
                                    Image(systemName: upNextExpanded ? "chevron.up" : "chevron.down")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundColor(SumiTheme.muted)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel(upNextExpanded ? "Show fewer Up Next titles" : "Show all Up Next titles")
                        }
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
                        onOpenDetail(item.id, item.title, item.coverImageURL, false, nil)
                    }
                }

                // Watching is fixed, not configurable — same split as
                // HomeView.tsx (queue + Watching are the front page; the rest
                // are rows the user can reorder or hide).
                if !model.watchingItems.isEmpty {
                    mediaRow(title: "Watching", count: model.watchingItems.count, items: model.watchingItems, shelfKey: "watching")
                } else if model.isSignedIn && model.isLoading {
                    MediaRowSkeleton(title: "Watching")
                }

                // Configurable rows, in the user's saved order; hidden ones
                // are skipped entirely rather than shown collapsed.
                ForEach(model.homeRowConfig.filter(\.visible)) { row in
                    homeDiscoverRow(id: row.id, title: row.title)
                }
            }
            // Capped so the shelves do not stretch across a whole 1512 pt
            // fullscreen, and centred: left-aligned under a 1100 cap the
            // right third of a fullscreen window was empty ("blank space on
            // the right side").
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: 1280, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
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
                    // No source card behind a modal sheet once it's
                    // dismissed, so no sourceKey — plain fade like any
                    // other non-card open.
                    onOpenDetail(item.id, item.title, item.coverImageURL, item.isManga, nil)
                }
            )
        }
    }

    /// One configurable row, by id. Skeletons preserve the shelf layout
    /// while queries are in flight, preventing sudden reflows. `id` doubles
    /// as the row's shelf key: distinct rows can show the same title at
    /// once (Watching and Trending, say), so the poster-morph source has to
    /// be scoped per-row, not just per-id — see `AppModel.openingDetailSourceKey`.
    @ViewBuilder
    private func homeDiscoverRow(id: String, title: String) -> some View {
        switch id {
        case "becauseYouWatched":
            // No skeleton branch: signed out the engine answers with an
            // empty list rather than an error, so a placeholder here would
            // sit on the page forever for anyone without a token.
            if !model.becauseYouWatched.isEmpty {
                mediaRow(title: title, count: model.becauseYouWatched.count, items: model.becauseYouWatched, shelfKey: "because")
            }
        case "planning":
            if model.isSignedIn {
                if !model.planningItems.isEmpty {
                    mediaRow(title: title, count: model.planningItems.count, items: model.planningItems, shelfKey: id)
                } else if model.isLoading {
                    MediaRowSkeleton(title: title)
                }
            }
        case "smartPlaylist":
            if model.isSignedIn {
                if !model.smartPicks.isEmpty {
                    mediaRow(title: title, count: model.smartPicks.count, items: model.smartPicks, shelfKey: id)
                } else if model.isLoading {
                    MediaRowSkeleton(title: title)
                }
            }
        case "trending":
            if !model.trendingItems.isEmpty {
                mediaRow(title: title, count: model.trendingItems.count, items: model.trendingItems, shelfKey: id)
            } else if model.isLoading {
                MediaRowSkeleton(title: title)
            }
        case "newlyReleasing":
            if !model.newlyReleasingItems.isEmpty {
                mediaRow(title: title, count: model.newlyReleasingItems.count, items: model.newlyReleasingItems, shelfKey: id)
            } else if model.isLoading {
                MediaRowSkeleton(title: title)
            }
        case "seasonal":
            if !model.seasonalItems.isEmpty {
                mediaRow(title: title, count: model.seasonalItems.count, items: model.seasonalItems, shelfKey: id)
            } else if model.isLoading {
                MediaRowSkeleton(title: title)
            }
        default:
            EmptyView()
        }
    }

    private func mediaRow(title: String, count: Int, items: [MediaCard.Item], shelfKey: String) -> some View {
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
                        MediaCard(
                            item: item,
                            namespace: model.openingDetailSourceKey == "\(shelfKey):\(item.id)" ? namespace : nil,
                            onPrefetch: {
                                model.prefetchDetail(id: item.id, isManga: item.isManga)
                            }
                        ) {
                            onOpenDetail(item.id, item.title, item.coverImageURL, item.isManga, "\(shelfKey):\(item.id)")
                        }
                        .equatable()
                        .frame(width: 180)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

#if os(macOS)
import AppKit

@MainActor
private final class SwipeGestureTracker {
    var accumulatedDeltaX: CGFloat = 0
    var accumulatedDeltaY: CGFloat = 0
    var isCooling = false
    var gestureDisqualified = false
    var lastSwipeEventAt: Date = .distantPast

    func reset() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        gestureDisqualified = false
    }
}

private struct GlobalKeyboardShortcutsModifier: ViewModifier {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitor: Any?
    @State private var scrollMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var swipeTracker = SwipeGestureTracker()

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
        // Two-finger trackpad swipe back & forward navigation.
        // Accumulates horizontal scroll delta on trackpads with an idle-gap cooldown
        // and horizontal dominance guard. Triggers an instantaneous, smooth fade
        // via `model.closeDetail()` and `model.goForwardDetail()`.
        // Tracking state lives in `swipeTracker` (a plain reference type) rather
        // than view `@State` so wheel ticks do not re-evaluate `RootView` / `MediaDetailView`
        // at 120Hz during normal vertical scrolling.
        let tracker = self.swipeTracker
        // A CGEvent tap, not a local NSEvent monitor: with responsive
        // scrolling on, the monitor saw 2 of 133 trackpad events and the
        // swipe went dead (see ScrollEventTap). Listen-only, so the scroll
        // view still receives the gesture; on a detail page nothing scrolls
        // sideways, so that costs nothing.
        scrollMonitor = ScrollEventTap.shared.subscribe { [self, tracker] event in
            guard model.activeStreamURL == nil,
                  model.activeReadingSession == nil,
                  !model.paletteOpen,
                  !model.shortcutsOpen else {
                return
            }

            // Trackpad swipe navigation ONLY operates when a detail page is open.
            // On the home screen and other sections, all scroll wheel events belong
            // exclusively to the page's vertical feed and horizontal carousels.
            guard model.selectedMediaDetails != nil else { return }

            let canGoBack = true
            // Forward goes inert while a person page is open: redoing a
            // detail-page step would swap the title *underneath* the
            // character page and leave that character floating over a show
            // it has nothing to do with.
            let canGoForward = model.canGoForward && !model.isPersonPageOpen

            // Only trackpad / precise scrolling gestures participate in swipe navigation
            guard event.hasPreciseScrollingDeltas else { return }

            // Ignore inertial momentum tail after fingers lift to prevent double-popping
            if !event.momentumPhase.isEmpty {
                return
            }

            let now = Date()

            // Cooldown: stay cooling until the gesture goes idle (> 0.15s gap) so one
            // physical swipe fires exactly once.
            if tracker.isCooling {
                if now.timeIntervalSince(tracker.lastSwipeEventAt) > 0.15 {
                    tracker.isCooling = false
                } else {
                    tracker.lastSwipeEventAt = now
                    return
                }
            }

            // Fresh gesture start on began phase or after an idle pause
            if event.phase == .began || now.timeIntervalSince(tracker.lastSwipeEventAt) > 0.15 {
                tracker.reset()
            }
            tracker.lastSwipeEventAt = now

            // Normalize deltaX so physical swipe right (back) is positive, swipe left (forward) is negative.
            let rawDeltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let rawDeltaY = event.scrollingDeltaY

            tracker.accumulatedDeltaX += rawDeltaX
            tracker.accumulatedDeltaY += abs(rawDeltaY)

            // Disqualify if vertical scrolling is clearly dominant over horizontal travel.
            if tracker.accumulatedDeltaY > abs(tracker.accumulatedDeltaX) * 1.5 && tracker.accumulatedDeltaY > 20 {
                tracker.gestureDisqualified = true
            }

            if event.phase == .ended || event.phase == .cancelled {
                tracker.reset()
                return
            }

            guard !tracker.gestureDisqualified else { return }

            let isHorizontal = abs(tracker.accumulatedDeltaX) > tracker.accumulatedDeltaY * 1.3
            let threshold: CGFloat = 50.0

            // Swipe right: Back (close detail / return to previous)
            if tracker.accumulatedDeltaX > threshold && isHorizontal && canGoBack {
                tracker.reset()
                tracker.isCooling = true
                // Once per physical gesture without a flag of its own: the
                // cooldown set on the line above is what keeps the rest of
                // one swipe's ticks from reaching here.
                AppHaptics.swipeThreshold()
                AppSounds.swipeBack.play()
                model.popBackOne()
                return
            }

            // Swipe left: Forward (redo detail navigation)
            if tracker.accumulatedDeltaX < -threshold && isHorizontal && canGoForward {
                tracker.reset()
                tracker.isCooling = true
                // Haptic but no sound: crossing the line feels the same in
                // either direction, while the only sound there is says
                // "back" and would be a lie on the way forward.
                AppHaptics.swipeThreshold()
                model.goForwardDetail()
                return
            }

            return
        }
        // Buttons 3/4 are the standard back/forward side-buttons on 5-button mice in AppKit (0=left, 1=right, 2=middle).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [self] event in
            guard model.selectedMediaDetails != nil || model.canGoForward else { return event }
            if event.buttonNumber == 3 && model.selectedMediaDetails != nil {
                model.popBackOne()
                return nil
            } else if event.buttonNumber == 4 && model.canGoForward && !model.isPersonPageOpen {
                model.goForwardDetail()
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
        if let id = scrollMonitor as? UUID {
            ScrollEventTap.shared.unsubscribe(id)
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
        // Not wrapped in `withAnimation`: every state `handleEscapeKey`/
        // `closeDetail`/`goForwardDetail` can touch already has its own
        // `.animation(value:)` modifier on the ZStack that renders it. A
        // second explicit transaction here raced those with a different
        // curve every keypress.
        if event.keyCode == 53 {
            let handled = model.handleEscapeKey()
            return handled ? nil : event
        }

        // Arrow keys in AppKit automatically include `.numericPad` and `.function`
        // flags, so we exclude explicit modifiers instead of checking a raw flag mask.
        if isAlt && !isCmd && !isCtrl && !isShift && event.keyCode == 123 && model.selectedMediaDetails != nil {
            model.popBackOne()
            return nil
        }

        // Right arrow (keyCode 124) mirrors Left above — Alt+Right redoes
        // through `detailForwardStack`, matching a browser's Alt+Right/Cmd+].
        if isAlt && !isCmd && !isCtrl && !isShift && event.keyCode == 124 && model.canGoForward && !model.isPersonPageOpen {
            model.goForwardDetail()
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
            // Up arrow: volume +5%
            if event.keyCode == 126 {
                model.playerController.setVolume(model.playerController.volume + 0.05)
                return nil
            }
            // Down arrow: volume -5%
            if event.keyCode == 125 {
                model.playerController.setVolume(model.playerController.volume - 0.05)
                return nil
            }
            // 'm': toggle mute
            if chars == "m" {
                model.playerController.toggleMute()
                return nil
            }
            // 'f': toggle fullscreen
            if chars == "f" {
                if let window = AppWindow.main {
                    if model.activeStreamURL != nil {
                        AppWindow.setToolbarVisible(false)
                    }
                    FullScreenGuard.toggle(on: window)
                }
                return nil
            }
            // 'n': next episode
            if chars == "n" {
                model.playerController.nextEpisode()
                return nil
            }
            // 'p': previous episode. Shift excluded explicitly — this block
            // guards only the other three modifiers, so Shift+P was landing
            // here and there was no key left to give Picture in Picture.
            if chars == "p" && !isShift {
                model.playerController.previousEpisode()
                return nil
            }
        }

        // Shift+P: Picture in Picture. Modelled on Shift+V below rather than
        // a monitor of the player's own: two local monitors claiming one key
        // resolve in whichever order AppKit happens to dispatch them.
        if model.activeStreamURL != nil && isShift && !isCmd && !isCtrl && !isAlt && chars == "p" {
            PictureInPicture.shared.toggle(aspectRatio: model.playerController.videoAspectRatio)
            return nil
        }

        // Shift+V: rotate video 90 degrees (off / CW / CCW)
        if model.activeStreamURL != nil && isShift && !isCmd && !isCtrl && !isAlt && chars == "v" {
            model.playerController.cycleSideways()
            return nil
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

            // Letter shortcuts: H (Home/Up Next), L (Library), M (Manga), N (Novels), T (Stats), D (Downloads)
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
                .buttonStyle(.sumiPressable)
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

                        Button(action: { withAnimation(.snappy) { model.moveHomeRow(at: index, by: -1) } }) {
                            Image(systemName: "chevron.up")
                                .foregroundColor(index == 0 ? SumiTheme.muted.opacity(0.3) : SumiTheme.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .disabled(index == 0)

                        Button(action: { withAnimation(.snappy) { model.moveHomeRow(at: index, by: 1) } }) {
                            Image(systemName: "chevron.down")
                                .foregroundColor(index == model.homeRowConfig.count - 1 ? SumiTheme.muted.opacity(0.3) : SumiTheme.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .disabled(index == model.homeRowConfig.count - 1)

                        Button(action: { withAnimation(.snappy) { model.toggleHomeRow(id: row.id) } }) {
                            Image(systemName: row.visible ? "eye" : "eye.slash")
                                .foregroundColor(row.visible ? SumiTheme.indigo : SumiTheme.muted.opacity(0.5))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .animation(.snappy, value: row.visible)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(SumiTheme.card.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
                .animation(.snappy, value: model.homeRowConfig)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(SumiTheme.background)
    }
}

/// Shown while `resolveAndPlay` is inside its `resolveStream` FFI call —
/// see the loading overlay's comment for why this exists instead of a bare
/// spinner. `TimelineView` rather than a `Timer`/`@State` tick: it's a
/// display-only clock with no state to manage or invalidate when the card
/// disappears.
private struct ResolvingStreamCard: View {
    let startedAt: Date
    let onCancel: () -> Void

    var body: some View {
        // A compact horizontal toast, same corner the mini-player uses —
        // not a centered modal. This shows on every single play
        // press (if only for a moment), so treating it like an alarming
        // blocking dialog was wrong to begin with; a small notification you
        // can glance at (or ignore) fits what it actually is.
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(SumiTheme.indigo)

            VStack(alignment: .leading, spacing: 1) {
                Text("Finding a stream…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text("\(elapsed)s")
                        .sumiTabularMono(size: 10)
                        .foregroundColor(SumiTheme.muted)
                }
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(SumiTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.sumiPressable)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 56)
        .sumiCardStyle()
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}
