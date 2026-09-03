import SwiftUI
import AnicatUI
import AnicatCoreKit

@main
struct AnicatApp: App {
    @State private var model = AppModel()

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
