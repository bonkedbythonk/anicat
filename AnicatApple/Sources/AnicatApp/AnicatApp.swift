import SwiftUI
import AnicatUI
import AnicatCoreKit

#if os(macOS)
/// Pins the process to dark aqua at launch.
///
/// `SumiTheme`'s colours are dynamic `NSColor`s that resolve by asking the
/// appearance they are drawn under, and `.preferredColorScheme(.dark)` only
/// covers SwiftUI's own environment — a colour resolved against the window or
/// the app appearance still answers with the washi-paper light palette on a
/// Mac set to Light. The web build ships the Ink & Index dark skin with no
/// light toggle wired up, so there is nothing for a light resolution to be
/// right about.
final class AppearanceLock: NSObject, NSApplicationDelegate {
    /// A Dock click with no visible window (the main window hidden behind a
    /// fullscreen space that was left, or closed) brings the window back
    /// rather than doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { AppWindow.main?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The theme store owns the appearance now: Paper is light, Ink and
        // OLED are dark, and a pinned darkAqua left menus and scrollers dark
        // over a light ground.
        ThemeStore.shared.applyToNativeChrome()
        _ = ScrollPocketWorkaround.disableScrollPocketsOnce
        // A `Window` scene does not always open at launch: after a kill or a
        // crash (no clean quit to record the window as open) the app came up
        // with the menu bar icon, the log's first line and nothing else, until
        // a Dock click sent it the reopen event. Reproduced three times in a
        // row on 2026-09-11 after `pkill`. The same event, sent to ourselves
        // once the scene had its chance, is what a Dock click would do.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            let hasMainWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
            guard !hasMainWindow else { return }
            AppLog.write("launch opened no window; sending reopen to self")
            let target = NSAppleEventDescriptor.currentProcess()
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication),
                targetDescriptor: target,
                returnID: AEReturnID(kAutoGenerateReturnID),
                transactionID: AETransactionID(kAnyTransactionID)
            )
            _ = try? event.sendEvent(options: [.noReply], timeout: 1)
        }
    }
}

/// Window delegate that ensures the toolbar and menu bar autohide in fullscreen,
/// preventing the solid ~35px gray toolbar from sticking at the top of the screen.
@MainActor
final class AnicatWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = AnicatWindowDelegate()

    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        return [.fullScreen, .autoHideToolbar, .autoHideMenuBar]
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            window.toolbar = nil
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            window.toolbar = nil
        }
    }

}

/// The window's own size and position across launches. `isRestorable` is
/// off (see `WindowConfigurator`), and with it off SwiftUI's frame autosave
/// stopped restoring too: the key it writes was present in the defaults
/// while every launch still opened at `defaultSize`, and
/// `setFrameAutosaveName` never wrote its key at all. So the frame is kept
/// by hand: saved on resize and move outside fullscreen, applied once when
/// the window first appears, and only if it still fits a screen.
@MainActor
enum WindowFrameMemory {
    static let key = "anicat_window_frame"
    private static var restored = false
    private static var observers: [NSObjectProtocol] = []

    /// Notifications rather than delegate methods: SwiftUI owns the
    /// window's delegate slot and the resize/move callbacks on the app's
    /// own delegate never arrived (no frame was written in a full session).
    static func watch(_ window: NSWindow) {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { save(AppWindow.main) }
            })
        }
    }

    static func save(_ window: NSWindow?) {
        guard let window, !window.styleMask.contains(.fullScreen), window.isVisible,
              window.frame.width > 200, window.frame.height > 200 else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }

    static func restoreOnce(_ window: NSWindow) {
        guard !restored else { return }
        restored = true
        guard let stored = UserDefaults.standard.string(forKey: key) else { return }
        let frame = NSRectFromString(stored)
        guard frame.width > 200, frame.height > 200,
              NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: true)
    }
}

/// Configures the hosting `NSWindow` the moment a SwiftUI view lands in it,
/// rather than hoping a timed loop catches it after launch. This is the only
/// place the title bar is made invisible, and it runs per-window so a window
/// created (or recreated) at any point gets the same treatment.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window) }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        _ = ScrollPocketWorkaround.disableScrollPocketsOnce
        // Never move the pointer off the window a stream is playing in.
        // `configure` runs for any window SwiftUI lands a view in -- a second
        // one from state restoration, or from a build where File > New Window
        // still exists -- and the fullscreen exit that closing the player
        // issues goes to whatever this names.
        if !(AppWindow.isPlaybackActive && AppWindow.main != nil && AppWindow.main !== window) {
            AppWindow.main = window
        }
        FullScreenGuard.attach(to: window)
        window.delegate = AnicatWindowDelegate.shared
        window.acceptsMouseMovedEvents = true
        window.toolbar = nil
        // Quit (or a reinstall's kill) during fullscreen playback and AppKit
        // restores the window straight into fullscreen at the next launch,
        // black until Escape forces a layout: playback drove that fullscreen,
        // not the viewer, and it is gone. Fullscreen is decided per session
        // by playback, so the window opts out of state restoration; the
        // frame itself still comes back through SwiftUI's own autosave.
        window.isRestorable = false
        // Restoration off means the frame no longer comes back either;
        // `WindowFrameMemory` keeps the last size and position without
        // bringing fullscreen back.
        if !window.styleMask.contains(.fullScreen) {
            WindowFrameMemory.restoreOnce(window)
        }
        WindowFrameMemory.watch(window)
        if window.styleMask.contains(.fullScreen), !AppWindow.isPlaybackActive {
            FullScreenGuard.set(false, on: window)
        }
        // Overlay-style titlebar, like Tauri's `titleBarStyle: "Overlay"`:
        // the content runs under the traffic lights with no title text and no
        // background strip. Traffic lights stay (Tauri's `decorations: true`),
        // which is why the sidebar still reserves its 38pt strip for them.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        TitleStripDoubleClick.install()
        // Not .clear: a fully non-opaque window drops out of AppKit's opaque
        // fast path entirely, so every redraw anywhere in the window pays a
        // full recomposite-against-desktop cost, not just the sidebar's own
        // NSVisualEffectView bounds — that's what made scrolling in the main
        // content area jank even though only the sidebar is meant to be
        // vibrant. A real opaque color here keeps the rest of the window on
        // the fast path; VibrancyBackdrop's own .behindWindow view still
        // handles the sidebar's translucency independently.
        window.backgroundColor = NSColor(srgbRed: 22.0 / 255, green: 19.0 / 255, blue: 16.0 / 255, alpha: 1)
        ScrollPocketWorkaround.disableScrollPockets(in: window.contentView)
    }
}

#if os(macOS)
/// Double-click on the title strip zooms the window, the way a real title
/// bar does. With `.fullSizeContentView` and a transparent title bar the
/// SwiftUI content sits under the traffic lights and takes the click, so
/// AppKit's own double-click-to-zoom never fired ("i cant click the drag
/// bar at the top to make it fullscreen"). A local monitor watches for a
/// second click inside the top 28 pt and asks the window to zoom, unless
/// the player covers that strip, where a double-click is its own
/// fullscreen toggle. Honours the System Settings choice: "Minimize" in
/// "Double-click a window's title bar to" miniaturizes instead.
enum TitleStripDoubleClick {
    static let stripHeight: CGFloat = 28
    /// Written once from `install`, on the main thread; the token is only
    /// held so a second `configure` pass does not add a second monitor.
    nonisolated(unsafe) private static var monitor: Any?

    @MainActor
    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            handle(event)
        }
    }

    @MainActor
    private static func handle(_ event: NSEvent) -> NSEvent? {
            guard event.clickCount == 2,
                  let window = event.window, window == AppWindow.main,
                  !window.styleMask.contains(.fullScreen),
                  let contentView = window.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            let top = contentView.isFlipped ? point.y : contentView.bounds.height - point.y
            guard top >= 0, top <= stripHeight else { return event }
            if let hit = contentView.hitTest(point), hit.isDescendant(of: contentView),
               sequence(first: hit, next: { $0.superview }).contains(where: { $0 is MpvHostView }) {
                return event
            }
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            switch action {
            case "Minimize": window.performMiniaturize(nil)
            case "None": return event
            default: window.performZoom(nil)
            }
            return nil
    }
}
#endif

@main
struct AnicatApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppearanceLock.self) private var appearanceLock

    init() {
        // Before anything else: the engine installs its logger in
        // `AppModel()` below, and the file has to be in place by then.
        AppLog.start()
        // AppKit reads the class flag when a scroll view is created, so the
        // patch has to land before the first scene builds its views.
        _ = ResponsiveScrollingPatch.applyOnce
        // Built here rather than as a property initializer so the instance
        // can be published before any scene exists: an App Intent is
        // constructed by the Shortcuts runtime and the notification delegate
        // by the system, and neither has a view to be handed the model
        // through. `registerAsShared` also installs the notification
        // delegate, which has to be in place before the first notification
        // is *delivered*, not before the first one is scheduled.
        let model = AppModel()
        _model = State(initialValue: model)
        model.registerAsShared()
    }

    var body: some Scene {
        // `Window`, not `WindowGroup`: a group hands out File > New Window
        // (and Cmd-N) for free, and a second window is not a second app. Both
        // windows mount `RootView` over the one `AppModel`, so a stream
        // playing in the first was mounted again in the new one -- two
        // `MpvSurface`s over one mpv handle -- and `WindowConfigurator` points
        // `AppWindow.main` at whichever window was configured last, so closing
        // the player exited fullscreen on the *new* window while the one
        // holding the picture stayed fullscreen with a frozen frame in it.
        // That is the "stuck after pressing exit" report. `Window` keeps
        // File > Close; removing the New Window command by hand took the whole
        // File menu, Cmd-W included, with it.
        Window("Anicat", id: "main") {
            ThemedRoot { RootView(model: model) }
                // The detail page's studio buttons and "More from" shelf
                // reach the model through here rather than through
                // `MediaDetailView.init`, whose one call site inside
                // `RootView` has no other interest in studios.
                .environment(\.studioPageActions, model.studioPageActions)
                .task {
                    await model.initialize()
                    // A notification tap that launched the app got here
                    // before there was an engine to route it with; this is
                    // where it finally runs.
                    model.drainPendingDeepLink()
                    if let path = ProcessInfo.processInfo.environment["ANICAT_DEBUG_PLAY_FILE"] {
                        model.debugPlayLocalFile(path)
                    }
                }
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .frame(minWidth: 1080, idealWidth: 1213, minHeight: 700, idealHeight: 754)
                .background(WindowConfigurator())
                .background(SystemIntegrationObserver(model: model))
        }
        .windowStyle(.hiddenTitleBar)
        // A `Window` scene publishes no File menu at all -- and Cmd-W went
        // with it, which the single-window change was never meant to take.
        // The group replaced is `saveItem`, not `newItem`: replacing the
        // latter leaves SwiftUI's own Close in place and the menu then reads
        // "Close, Close, Close All".
        .commands {
            CommandGroup(replacing: .saveItem) {
                Button("Close") { NSApp.keyWindow?.performClose(nil) }
                    .keyboardShortcut("w", modifiers: .command)
            }
        }
        // First launch, before any autosaved frame exists; after that the
        // autosaved frame wins, so resizing once is enough. 1440x900 read
        // as too big on a 14-inch panel, 1080x820 as a square, and 1280x820
        // still left the detail page's hero taller than it wanted to be.
        // 1213x754 is the size the app was actually settled at in use.
        .defaultSize(width: 1213, height: 754)

        MenuBarExtra {
            // `.window` style renders arbitrary SwiftUI in a popover instead of
            // a plain NSMenu, which is what makes the real MenuBarView (cover
            // art, resume card) usable here instead of a menu of text rows.
            MenuBarView(
                lastWatchedTitle: model.activeStreamURL != nil
                    ? (model.currentPlaybackTitle ?? model.playerController.title)
                    : model.upNextItems.first?.title,
                lastWatchedEpisode: model.activeStreamURL != nil
                    ? Int(model.currentPlaybackEpisode ?? Int64(model.playerController.episodeNumber))
                    : model.upNextItems.first.map { Int($0.nextEpisodeOrChapter) },
                lastWatchedThumbnailURL: model.upNextItems.first?.thumbnailURL,
                // "Airing today", not "airing at some point": `scheduleItems`
                // is the whole forward schedule, so without the date test
                // this listed episodes a fortnight out under a heading that
                // says today. Watching-only, because a menu bar popover is
                // the viewer's own queue and not a catalog listing.
                airingItems: model.scheduleItems
                    .filter { $0.isWatching && Calendar.current.isDateInToday(Date(timeIntervalSince1970: TimeInterval($0.airingAt))) }
                    .map {
                        MenuBarView.AiringTodayItem(
                            id: $0.id,
                            title: $0.title,
                            episodeNumber: $0.episodeNumber,
                            countdownText: $0.countdownText
                        )
                    },
                // Everything after the one already drawn in the resume card
                // above, so the same title is not offered twice.
                upNext: model.upNextItems
                    .dropFirst(model.activeStreamURL == nil ? 1 : 0)
                    .prefix(3)
                    .map {
                        MenuBarView.UpNextItem(
                            id: $0.id,
                            title: $0.title,
                            episodeNumber: Int($0.nextEpisodeOrChapter),
                            thumbnailURL: $0.thumbnailURL
                        )
                    },
                sleepTimerCaption: model.sleepTimerCaption,
                nowPlaying: model.activeStreamURL != nil ? model.playerController : nil,
                onOpenAiringItem: { item in
                    model.handleDeepLink(.title(id: item.id, isManga: false))
                },
                onPlayUpNext: { item in
                    model.handleDeepLink(.play(id: item.id, episode: item.episodeNumber))
                },
                onSetSleepTimer: { choice in
                    switch choice {
                    case .off: model.sleepTimer = .off
                    case .afterEpisode: model.sleepTimer = .afterEpisode
                    case .minutes(let m):
                        model.sleepTimer = .at(Date().addingTimeInterval(TimeInterval(m * 60)))
                    }
                },
                onMarkWatched: model.activeStreamURL != nil ? {
                    guard let id = model.currentPlaybackCatalogId,
                          let ep = model.currentPlaybackEpisode else { return }
                    model.markEpisodeFinished(catalogId: id, episode: ep)
                } : nil,
                onResumeLastWatched: {
                    if model.activeStreamURL != nil {
                        // Restore the player if it was backgrounded (see
                        // `AppModel.isPlayerMinimized`) rather than only
                        // toggling play/pause somewhere the viewer can't
                        // see — "Resume" should mean "show me the video",
                        // not silently unpause it off-screen.
                        NSApp.activate(ignoringOtherApps: true)
                        AppWindow.main?.makeKeyAndOrderFront(nil)
                        // Bare assignment: `PlayerView.minimizeCurve` owns
                        // this transition, and a `withAnimation` here ran a
                        // second transaction with a different curve against
                        // it.
                        model.isPlayerMinimized = false
                        if !model.playerController.isPlaying {
                            model.playerController.togglePlayPause()
                        }
                    } else if let first = model.upNextItems.first {
                        if first.unit != "CH" {
                            // Same sequence as the Up Next shelf: the show's
                            // page opens first, so the viewer lands on a page
                            // with a Cancel and an episode list rather than a
                            // bare spinner over whatever was on screen.
                            NSApp.activate(ignoringOtherApps: true)
                            AppWindow.main?.makeKeyAndOrderFront(nil)
                            playFromShelf(
                                model: model,
                                catalogId: first.id,
                                episode: first.nextEpisodeOrChapter,
                                title: first.title,
                                coverURL: model.knownCovers[first.id] ?? first.thumbnailURL
                            )
                        } else {
                            Task { @MainActor in
                                await model.openDetail(id: first.id, isManga: true)
                            }
                        }
                    }
                },
                onOpenMainApp: {
                    NSApp.activate(ignoringOtherApps: true)
                    AppWindow.main?.makeKeyAndOrderFront(nil)
                },
                onOpenSettings: {
                    NSApp.activate(ignoringOtherApps: true)
                    // The actual bug this fixes: `PlayerView` used to render
                    // unconditionally over everything whenever a stream was
                    // active, regardless of `currentNavSection` — so opening
                    // Settings from the menu bar while something was playing
                    // switched the section underneath but the video stayed
                    // covering the whole window with no visible way back to
                    // the app. Minimizing (not stopping) it is what actually
                    // uncovers Settings.
                    // Same as above: the curve lives in `PlayerView`.
                    model.isPlayerMinimized = true
                    // `RootView`'s detail page renders whenever
                    // `selectedMediaDetails` is set, regardless of
                    // `currentNavSection` -- the sidebar's own click handler
                    // already clears it for exactly this reason. This entry
                    // point skipped that, so opening Settings from the menu
                    // bar while a title's detail page was open silently did
                    // nothing: the section changed underneath, but the
                    // detail page kept rendering over it.
                    model.clearPersonPages()
                    model.clearDetail()
                    model.currentNavSection = .settings
                    AppWindow.main?.makeKeyAndOrderFront(nil)
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        } label: {
            if let icon = BrandAssets.menuBarIcon {
                icon
            } else {
                Image(systemName: "cat.fill")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

#else

/// The iOS entry point. Nothing the macOS one does above has an iOS
/// counterpart: there is no window to configure, no app delegate needed to
/// pin the appearance (`.preferredColorScheme(.dark)` covers a UIKit scene,
/// which resolves colours through SwiftUI's environment rather than an
/// `NSAppearance`), and no menu bar to extend.

@main
struct AnicatApp: App {
    @State private var model: AppModel

    init() {
        AppLog.start()
        let model = AppModel()
        _model = State(initialValue: model)
        model.registerAsShared()
    }

    var body: some Scene {
        WindowGroup {
            // `RootTabView`, not `RootView`: the desktop root opens with a
            // 200pt sidebar rail and a 1080pt minimum width, which on a
            // 402pt phone leaves the content column narrower than one poster.
            ThemedRoot { RootTabView(model: model) }
                // The detail page's studio buttons and "More from" shelf
                // reach the model through here rather than through
                // `MediaDetailView.init`, whose one call site inside
                // `RootView` has no other interest in studios.
                .environment(\.studioPageActions, model.studioPageActions)
                .task {
                    // Before `initialize`, which is slow: a Live Activity
                    // left running by a previous launch is already on the
                    // lock screen, and its buttons reach this process the
                    // moment it exists.
                    await model.initialize()
                    model.drainPendingDeepLink()
                    if let path = ProcessInfo.processInfo.environment["ANICAT_DEBUG_PLAY_FILE"] {
                        model.debugPlayLocalFile(path)
                    }
                }
                // The URL scheme and notifications are not macOS features:
                // both have iOS counterparts, and a scene that only wired
                // them up on one platform would compile on the other and
                // silently do nothing.
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .background(SystemIntegrationObserver(model: model))
        }
    }
}
#endif
