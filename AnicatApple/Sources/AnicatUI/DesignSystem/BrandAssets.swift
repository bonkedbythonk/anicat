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
        #if os(macOS)
        let targetSize = NSSize(width: 14, height: 20)

        // 1. Try pre-bundled multi-resolution TIFF containing both 1x and 2x Retina representations
        let tiffCandidates = [
            Bundle.module.url(forResource: "anicat_menu_icon", withExtension: "tiff"),
            Bundle.module.url(forResource: "anicat_menu_icon", withExtension: "tiff", subdirectory: "Images"),
        ]
        for case let url? in tiffCandidates {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = targetSize
                return Image(nsImage: img)
            }
        }

        // 2. Build multi-representation NSImage programmatically from @1x, @2x, and @3x PNGs
        let image = NSImage(size: targetSize)
        var addedRep = false

        let repNames = ["anicat_menu_icon", "anicat_menu_icon@2x", "anicat_menu_icon@3x"]
        for name in repNames {
            let urls = [
                Bundle.module.url(forResource: name, withExtension: "png"),
                Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Images"),
            ]
            for case let url? in urls {
                if let data = try? Data(contentsOf: url),
                   let rep = NSBitmapImageRep(data: data) {
                    rep.size = targetSize
                    image.addRepresentation(rep)
                    addedRep = true
                    break
                }
            }
        }

        if addedRep {
            image.isTemplate = true
            return Image(nsImage: image)
        }

        // 3. Fallback to tray_icon or anicat_logo
        let fallbacks = [
            Bundle.module.url(forResource: "tray_icon", withExtension: "png"),
            Bundle.module.url(forResource: "tray_icon", withExtension: "png", subdirectory: "Images"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png", subdirectory: "Images"),
        ]
        for case let url? in fallbacks {
            if let img = NSImage(contentsOf: url) {
                img.isTemplate = true
                img.size = targetSize
                return Image(nsImage: img)
            }
        }
        return nil
        #else
        let candidates = [
            Bundle.module.url(forResource: "anicat_menu_icon", withExtension: "png"),
            Bundle.module.url(forResource: "anicat_menu_icon", withExtension: "png", subdirectory: "Images"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png"),
            Bundle.module.url(forResource: "anicat_logo", withExtension: "png", subdirectory: "Images"),
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let uiImage = UIImage(data: data) {
                return Image(uiImage: uiImage)
            }
        }
        return nil
        #endif
    }()
}
