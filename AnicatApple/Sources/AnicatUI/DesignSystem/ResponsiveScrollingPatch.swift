import SwiftUI
#if os(macOS)
import AppKit
import ObjectiveC

/// Puts SwiftUI's scroll views back on AppKit's responsive scrolling path.
///
/// SwiftUI backs `ScrollView` with a private `NSScrollView` subclass,
/// `HostingScrollView`, whose `isCompatibleWithResponsiveScrolling` answers
/// false. On the non-responsive path AppKit applies wheel events on the
/// main thread at every *second* display refresh, so on a 120 Hz panel the
/// content moves at 60 Hz no matter how idle the app is. Measured with the
/// Hitches instrument under a synthetic trackpad scroll: a bare SwiftUI
/// `ScrollView` committed 208 frames two vsyncs apart against 84 one apart;
/// a plain `NSScrollView` with responsive scrolling turned off reproduced
/// the same split (218 to 123); with it on, or with this patch applied to
/// `HostingScrollView`, the split inverted (94 to 393). Finder scrolls at
/// the full rate for the same reason. Nothing public toggles it, so the
/// class method is replaced at launch; a SwiftUI that renames the class
/// simply leaves the old behaviour in place, which is why the lookup is
/// by name and never asserts.
public enum ResponsiveScrollingPatch {
    public static let applyOnce: Void = {
        let names = ["SwiftUI.HostingScrollView", "_TtC7SwiftUI17HostingScrollView"]
        guard let cls = names.lazy.compactMap({ NSClassFromString($0) }).first,
              cls is NSScrollView.Type,
              let meta = object_getClass(cls) else { return }
        let selector = NSSelectorFromString("isCompatibleWithResponsiveScrolling")
        let block: @convention(block) (AnyObject) -> Bool = { _ in true }
        let imp = imp_implementationWithBlock(block)
        if let method = class_getClassMethod(cls, selector) {
            method_setImplementation(method, imp)
        } else {
            class_addMethod(meta, selector, imp, "B@:")
        }
    }()
}
#else
public enum ResponsiveScrollingPatch {
    public static let applyOnce: Void = ()
}
#endif
