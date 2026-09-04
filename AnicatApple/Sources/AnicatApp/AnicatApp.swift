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
        AppWindow.main = window
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
        MenuBarExtra {
            if model.activeStreamURL != nil, let title = model.currentPlaybackTitle ?? Optional(model.playerController.title), !title.isEmpty {
                let ep = model.currentPlaybackEpisode ?? Int64(model.playerController.episodeNumber)
                Text("\(title) — Ep \(ep)")
                Button(model.playerController.isPlaying ? "Pause" : "Play") {
                    model.playerController.togglePlayPause()
                }
                Divider()
            } else if let first = model.upNextItems.first {
                Button("Resume \(first.title) (\(first.unit) \(first.nextEpisodeOrChapter))") {
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
                Divider()
            }

            Button("Open AniCat") {
                NSApp.activate(ignoringOtherApps: true)
                AppWindow.main?.makeKeyAndOrderFront(nil)
            }
            .keyboardShortcut("o")

            Button("Settings...") {
                NSApp.activate(ignoringOtherApps: true)
                model.currentNavSection = .settings
                AppWindow.main?.makeKeyAndOrderFront(nil)
            }
            .keyboardShortcut(",")

            Divider()

            Button("Quit AniCat") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            if let icon = BrandAssets.menuBarIcon {
                icon
            } else {
                Image(systemName: "cat.fill")
            }
        }
        .menuBarExtraStyle(.menu)
        #endif
    }
}
