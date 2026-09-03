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
                .background(SumiTheme.background)
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
                onResumeLastWatched: {
                    if let first = model.upNextItems.first {
                        Task {
                            _ = try? await model.resolveAndPlay(
                                catalogId: first.id,
                                episode: Int64(first.nextEpisodeOrChapter),
                                title: first.title
                            )
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
