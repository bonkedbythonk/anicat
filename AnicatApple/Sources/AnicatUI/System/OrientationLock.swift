#if os(iOS)
import UIKit

/// Which way the phone may turn, decided by what is on screen.
///
/// The plist allows portrait and both landscapes so the player can lie
/// down; nothing enforced the rest. So the shelves, the detail page and
/// Settings all rotated too, and a phone set down on a table mid-scroll
/// re-laid three poster shelves out sideways. The player is the only screen
/// that wants landscape, and it wants nothing else: a 16:9 picture in
/// portrait is a strip across the middle of the phone.
///
/// A static mask read by the app delegate, since SwiftUI has no modifier
/// for this; `apply` also asks the scene to rotate now rather than waiting
/// for the viewer to turn the phone.
@MainActor
enum OrientationLock {
    private(set) static var mask: UIInterfaceOrientationMask = .portrait

    static func apply(playerOpen: Bool) {
        let wanted: UIInterfaceOrientationMask = playerOpen ? .landscape : .portrait
        guard wanted != mask else { return }
        mask = wanted
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: wanted)) { error in
                AppLog.write("[orientation] geometry update refused: \(error.localizedDescription)")
            }
            scene.keyWindow?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        }
    }
}

/// Exists for one callback. `UIApplicationDelegateAdaptor` in `AnicatApp`
/// installs it; everything else about the app stays in the SwiftUI scene.
public final class AnicatAppDelegate: NSObject, UIApplicationDelegate {
    public func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        OrientationLock.mask
    }

    /// Home-screen quick actions (`UIApplicationShortcutItems` in
    /// project.yml). Each carries its `anicat://` address in `userInfo`, so
    /// this is one line into the same `handleOpenURL` a notification tap
    /// uses; a cold launch parks it in `pendingDeepLink` until the engine
    /// is up.
    public func application(
        _ application: UIApplication,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        guard let raw = shortcutItem.userInfo?["url"] as? String, let url = URL(string: raw) else {
            completionHandler(false)
            return
        }
        completionHandler(AppModel.shared?.handleOpenURL(url) ?? false)
    }
}
#endif
