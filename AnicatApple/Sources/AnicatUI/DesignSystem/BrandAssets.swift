import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Bundled brand images that need loading outside a single view (the menu
/// bar icon is set from `AnicatApp`, a different target than the sidebar
/// mark that already does this lookup — see `SidebarView`'s private `mark`).
public enum BrandAssets {
    /// The authentic AniCat cat silhouette mark for the macOS status bar.
    public static let menuBarIcon: Image? = {
        let candidates = [
            Bundle.module.url(forResource: "anicat_menu_icon", withExtension: "png"),
            Bundle.module.url(forResource: "anicat_menu_icon", withExtension: "png", subdirectory: "Images"),
            Bundle.module.url(forResource: "tray_icon", withExtension: "png"),
            Bundle.module.url(forResource: "tray_icon", withExtension: "png", subdirectory: "Images"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png", subdirectory: "Images"),
        ]
        #if os(macOS)
        for case let url? in candidates {
            if let nsImage = NSImage(contentsOf: url) {
                // Template mode: macOS recolors it to match the menu bar's
                // own light/dark/vibrancy state, same as every other status
                // item icon.
                nsImage.isTemplate = true
                // Standard macOS menu bar status item height is 18pt.
                // Maintain the authentic cat silhouette aspect ratio (~0.72):
                nsImage.size = NSSize(width: 13, height: 18)
                return Image(nsImage: nsImage)
            }
        }
        #else
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                return Image(uiImage: uiImage)
            }
        }
        #endif
        return nil
    }()
}
