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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
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
        // Overlay-style titlebar, like Tauri's `titleBarStyle: "Overlay"`:
        // the content runs under the traffic lights with no title text and no
        // background strip. Traffic lights stay (Tauri's `decorations: true`),
        // which is why the sidebar still reserves its 38pt strip for them.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.fullSizeContentView)
        window.backgroundColor = .clear
    }
}
#endif

@main
struct AnicatApp: App {
    @State private var model = AppModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppearanceLock.self) private var appearanceLock
    #endif

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task {
                    await model.initialize()
                }
                .preferredColorScheme(.dark)
                #if os(macOS)
                .frame(minWidth: 1080, idealWidth: 1280, minHeight: 700, idealHeight: 820)
                .background(WindowConfigurator())
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        .commands {
            SidebarCommands()
        }
        #endif

        #if os(macOS)
        MenuBarExtra("AniCat", systemImage: "cat.fill") {
            MenuBarView(
                lastWatchedTitle: model.upNextItems.first?.title,
                lastWatchedEpisode: model.upNextItems.first?.nextEpisodeOrChapter,
                lastWatchedThumbnailURL: model.upNextItems.first?.thumbnailURL,
                airingItems: model.scheduleItems.prefix(5).map {
                    MenuBarView.AiringTodayItem(
                        id: $0.id,
                        title: $0.title,
                        episodeNumber: $0.episodeNumber,
                        countdownText: $0.countdownText
                    )
                },
                onResumeLastWatched: {
                    if let first = model.upNextItems.first {
                        if first.unit != "CH" {
                            Task {
                                do {
                                    _ = try await model.resolveAndPlay(
                                        catalogId: first.id,
                                        episode: Int64(first.nextEpisodeOrChapter),
                                        title: first.title
                                    )
                                } catch {
                                    model.errorMessage = "Failed to play episode \(first.nextEpisodeOrChapter): \(error.localizedDescription)"
                                }
                            }
                        } else {
                            Task { @MainActor in
                                await model.openDetail(id: first.id, isManga: true)
                            }
                        }
                    }
                },
                onOpenMainApp: {
                    NSApp.activate(ignoringOtherApps: true)
                },
                onQuit: {
                    NSApp.terminate(nil)
                }
            )
        }
        .menuBarExtraStyle(.window)
        #endif
    }
}
