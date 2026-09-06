import SwiftUI
#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

// The one place AnicatUI names an AppKit or UIKit type by platform. Every
// view that used to reach for NSWorkspace, NSPasteboard or NSImage directly
// goes through here, so the iOS build needs a UIKit twin of each helper
// once instead of an `#if` at each of the call sites (there were about
// twenty across the design system and the views).

#if canImport(AppKit)
public typealias PlatformColor = NSColor
public typealias PlatformImage = NSImage
public typealias PlatformFont = NSFont
#elseif canImport(UIKit)
public typealias PlatformColor = UIColor
public typealias PlatformImage = UIImage
public typealias PlatformFont = UIFont
#endif

public enum Platform {
    /// Opens a URL in the default browser (macOS) or the system handler
    /// (iOS). Used for AniList authorization and external links.
    @MainActor
    public static func openExternal(_ url: URL) {
        #if canImport(AppKit)
        NSWorkspace.shared.open(url)
        #elseif canImport(UIKit)
        UIApplication.shared.open(url)
        #endif
    }

    /// Replaces the pasteboard's contents with `text`.
    @MainActor
    public static func copyToPasteboard(_ text: String) {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }

    /// True on iPhone and iPad, where hover, cursor hiding and window
    /// toolbars have no meaning and code paths that assume them are
    /// compiled out rather than stubbed.
    public static var isTouch: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }
}

public extension Image {
    /// One initializer for a platform image, so callers never spell out
    /// `nsImage:` or `uiImage:`.
    init(platformImage: PlatformImage) {
        #if canImport(AppKit)
        self.init(nsImage: platformImage)
        #elseif canImport(UIKit)
        self.init(uiImage: platformImage)
        #endif
    }
}

public extension PlatformImage {
    /// A CGImage for the image's natural size, or nil. AppKit and UIKit
    /// expose this differently; callers that feed Core Graphics or
    /// MediaPlayer artwork want one spelling.
    var platformCGImage: CGImage? {
        #if canImport(AppKit)
        return cgImage(forProposedRect: nil, context: nil, hints: nil)
        #elseif canImport(UIKit)
        return cgImage
        #endif
    }
}
