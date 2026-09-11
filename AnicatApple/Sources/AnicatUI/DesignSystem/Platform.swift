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
        #elseif os(tvOS)
        // tvOS has no pasteboard. The one thing the app copies is a debug
        // report, which Settings on the TV never offers.
        _ = text
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

    /// True on Apple TV. Neither a pointer nor a touch screen: everything
    /// is reached by moving focus with the Siri Remote, so hover, drag and
    /// tap-to-reveal code paths are compiled out and the TV root
    /// (`TVRootView`) is built around focus instead.
    public static var isTV: Bool {
        #if os(tvOS)
        return true
        #else
        return false
        #endif
    }

    /// The OS name the debug report prints. Hardcoding "macOS" there would
    /// have the iPhone build hand a support report claiming to come from a
    /// Mac, which is exactly the field a reader trusts without checking.
    public static var osName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #else
        return "iOS"
        #endif
    }

    /// The name this machine advertises over Bonjour. Foundation's `Host`
    /// exists only on macOS, so naming it directly in `BonjourDiscovery`
    /// broke the iOS build in a file that is otherwise pure Network.
    public static var deviceName: String {
        #if canImport(AppKit)
        return Host.current().localizedName ?? "MacBook"
        #elseif os(tvOS)
        // `ProcessInfo.hostName` answers "localhost" on tvOS, and the TV's
        // Bonjour name is exactly what the phone and the Mac should see.
        return UIDevice.current.name
        #elseif canImport(UIKit)
        // Not `UIDevice.current.name`: this is read as a default argument, so
        // a main-actor-isolated source would drag every caller of
        // `startAdvertising` onto the main actor. The hostname carries the
        // same user-set device name with a ".local" suffix.
        return ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        #endif
    }
}

public extension View {
    /// Escape-to-dismiss for the overlays that own the whole screen.
    /// `onExitCommand` exists on macOS (Escape) and tvOS (the Menu / Back
    /// button); iOS has no keyboard shortcut layer yet, so the modifier
    /// disappears there rather than every call site growing an `#if`.
    @ViewBuilder
    func sumiExitCommand(perform action: @escaping () -> Void) -> some View {
        #if os(macOS) || os(tvOS)
        self.onExitCommand(perform: action)
        #else
        self
        #endif
    }
}

public extension View {
    /// `textSelection(.enabled)` where the SDK has it. tvOS has nothing to
    /// select with, and the modifier is not declared there.
    @ViewBuilder
    func sumiTextSelectable() -> some View {
        #if os(tvOS)
        self
        #else
        self.textSelection(.enabled)
        #endif
    }

    /// `onHover` where a pointer exists. A no-op on tvOS, where focus is the
    /// only thing that moves and the modifier is not declared.
    @ViewBuilder
    func sumiOnHover(perform action: @escaping (Bool) -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        self.onHover(perform: action)
        #endif
    }

    /// `keyboardShortcut` where there is a keyboard. Not declared on tvOS.
    @ViewBuilder
    func sumiKeyboardShortcut(_ key: KeyEquivalent, modifiers: EventModifiers = .command) -> some View {
        #if os(tvOS)
        self
        #else
        self.keyboardShortcut(key, modifiers: modifiers)
        #endif
    }

    /// A popover on the Mac and the phone; a sheet on the TV, which has no
    /// anchored popovers at all. The Mac-shaped views that use this are not
    /// mounted on the TV today, so the sheet is what keeps them compiling
    /// rather than a design.
    @ViewBuilder
    func sumiPopover<Content: View>(
        isPresented: Binding<Bool>,
        arrowEdge: Edge = .top,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(tvOS)
        self.sheet(isPresented: isPresented, content: content)
        #else
        self.popover(isPresented: isPresented, arrowEdge: arrowEdge, content: content)
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
