import SwiftUI
import WidgetKit

/// Only Live Activities. Home-screen widgets were here for a day: they
/// need an App Group to read anything from the app, and an App Group needs
/// a paid team, which this project does not have. The activities need no
/// entitlement and were seen working on a personal team.
@main
struct AnicatWidgetBundle: WidgetBundle {
    var body: some Widget {
        DownloadLiveActivity()
        RemoteLiveActivity()
    }
}

/// The app's Ink & Index accent, by hand: the extension cannot import
/// `SumiTheme` without importing the whole UI target.
enum WidgetTheme {
    static var accent: Color {
        Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.561, green: 0.722, blue: 0.863, alpha: 1)
                : UIColor(red: 0.184, green: 0.353, blue: 0.463, alpha: 1)
        })
    }
}
