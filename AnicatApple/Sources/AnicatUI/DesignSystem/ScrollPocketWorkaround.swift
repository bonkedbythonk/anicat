import SwiftUI
#if os(macOS)
import AppKit

/// Disables macOS 15+ (Tahoe) `NSScrollPocket` overlays on `NSScrollView`.
///
/// When an `NSScrollView` is placed inside an `NSWindow` configured with
/// `.fullSizeContentView` and a transparent titlebar, macOS AppKit automatically
/// enables `allowedPocketEdges = 3` (top and bottom). This injects private subviews
/// (`NSScrollPocket`, `PocketBlur`, `PocketMask`, and `LuminanceAdjustment`) that
/// render a blurred, darkened scrim across the top 32–60pt of the scrollview.
///
/// Over full-bleed banner artwork (such as in `MediaDetailView`), this results in
/// an unwanted frosted fade and a harsh demarcation line across the image.
///
/// Locking `allowedPocketEdges` to 0 eliminates these private blur subviews completely.
public enum ScrollPocketWorkaround {
    /// Applies method swizzles on `NSScrollView` once per process lifetime.
    public static let disableScrollPocketsOnce: Void = {
        let getterSel = Selector(("allowedPocketEdges"))
        let setterSel = Selector(("setAllowedPocketEdges:"))

        let swizGetterSel = #selector(NSScrollView._anicat_allowedPocketEdges)
        let swizSetterSel = #selector(NSScrollView._anicat_setAllowedPocketEdges(_:))

        if let origGet = class_getInstanceMethod(NSScrollView.self, getterSel),
           let swizGet = class_getInstanceMethod(NSScrollView.self, swizGetterSel) {
            method_exchangeImplementations(origGet, swizGet)
        }

        if let origSet = class_getInstanceMethod(NSScrollView.self, setterSel),
           let swizSet = class_getInstanceMethod(NSScrollView.self, swizSetterSel) {
            method_exchangeImplementations(origSet, swizSet)
        }
    }()

    /// Recursively clears pocket edges on any existing `NSScrollView` subviews.
    @MainActor
    public static func disableScrollPockets(in view: NSView?) {
        guard let view else { return }
        if let scrollView = view as? NSScrollView {
            if scrollView.responds(to: Selector(("setAllowedPocketEdges:"))) {
                scrollView.setValue(0, forKey: "allowedPocketEdges")
                scrollView.setNeedsDisplay(scrollView.bounds)
            }
        }
        for subview in view.subviews {
            disableScrollPockets(in: subview)
        }
    }
}

extension NSScrollView {
    @objc fileprivate func _anicat_allowedPocketEdges() -> Int {
        return 0
    }

    @objc fileprivate func _anicat_setAllowedPocketEdges(_ edges: Int) {
        // No-op: prevent AppKit from creating or re-attaching NSScrollPocket blur views
    }
}
#endif
