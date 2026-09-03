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
    }
}
