import SwiftUI
import AnicatUI
import AnicatCoreKit
import CoreSpotlight

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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The theme store owns the appearance now: Paper is light, Ink and
        // OLED are dark, and a pinned darkAqua left menus and scrollers dark
        // over a light ground.
        ThemeStore.shared.applyToNativeChrome()
        _ = ScrollPocketWorkaround.disableScrollPocketsOnce
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
        AppWindow.main = window
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
        // Restoration off means the frame no longer comes back either, and
        // the window opened at the 1080x820 minimum: small and nearly
        // square. Frame autosave is separate from state restoration and
        // keeps the last size and position without bringing fullscreen back.
        window.setFrameAutosaveName("AnicatMainWindow")
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

@main
struct AnicatApp: App {
    @State private var model: AppModel
    @NSApplicationDelegateAdaptor(AppearanceLock.self) private var appearanceLock

    init() {
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
        WindowGroup {
            ThemedRoot { RootView(model: model) }
                .task {
                    await model.initialize()
                    // A notification tap or Spotlight hit that launched the
                    // app got here before there was an engine to route it
                    // with; this is where it finally runs.
                    model.drainPendingDeepLink()
                }
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    model.handleSpotlightActivity(activity)
                }
                .frame(minWidth: 1080, idealWidth: 1440, minHeight: 700, idealHeight: 900)
                .background(WindowConfigurator())
                .background(SystemIntegrationObserver(model: model))
        }
        .windowStyle(.hiddenTitleBar)
        // First launch, before any autosaved frame exists. 16:10 like the
        // MacBook panels it runs on, inside a 14-inch's 1512x982 points.
        .defaultSize(width: 1440, height: 900)

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
                nowPlaying: model.activeStreamURL != nil ? model.playerController : nil,
                onOpenAiringItem: { item in
                    model.handleDeepLink(.title(id: item.id, isManga: false))
                },
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
        let model = AppModel()
        _model = State(initialValue: model)
        model.registerAsShared()
    }

    var body: some Scene {
        WindowGroup {
            ThemedRoot { RootView(model: model) }
                .task {
                    await model.initialize()
                    model.drainPendingDeepLink()
                }
                // The URL scheme, Spotlight and notifications are not macOS
                // features: all three have iOS counterparts, and a scene that
                // only wired them up on one platform would compile on the
                // other and silently do nothing.
                .onOpenURL { url in
                    model.handleOpenURL(url)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    model.handleSpotlightActivity(activity)
                }
                .background(SystemIntegrationObserver(model: model))
        }
    }
}
#endif
