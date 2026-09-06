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

        // Horizontal shelves stay on the old path. With the event thread
        // tracking a shelf's momentum, a vertical swipe that starts before
        // the momentum ends is routed to the shelf and dropped: measured 1
        // of 2 and then 2 of 3 vertical swipes lost in a nested test view,
        // 0 of 2 with responsive scrolling off. The flag is per class, so a
        // shelf is moved to a runtime subclass that answers no, at the
        // moment it joins a window and before AppKit reads the flag. Shelf
        // scrolling itself falls back to the 60 Hz cadence; the page keeps
        // 120 Hz, and the vertical swipe landed 3 of 3 after the swap.
        guard let shelfClass = objc_allocateClassPair(cls, "AnicatShelfScrollView", 0),
              let shelfMeta = object_getClass(shelfClass) else { return }
        let shelfFlag: @convention(block) (AnyObject) -> Bool = { _ in false }
        class_addMethod(shelfMeta, selector, imp_implementationWithBlock(shelfFlag), "B@:")
        objc_registerClassPair(shelfClass)
        let moveSelector = NSSelectorFromString("viewWillMoveToWindow:")
        typealias MoveFn = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        guard let moveMethod = class_getInstanceMethod(cls, moveSelector) else { return }
        let originalMove = unsafeBitCast(method_getImplementation(moveMethod), to: MoveFn.self)
        let moveBlock: @convention(block) (AnyObject, AnyObject?) -> Void = { object, window in
            if window != nil, object_getClass(object) == cls, let scrollView = object as? NSScrollView {
                let isShelf = MainActor.assumeIsolated {
                    scrollView.hasHorizontalScroller && !scrollView.hasVerticalScroller
                }
                if isShelf { object_setClass(object, shelfClass) }
            }
            originalMove(object, moveSelector, window)
        }
        method_setImplementation(moveMethod, imp_implementationWithBlock(moveBlock))
    }()
}
#else
public enum ResponsiveScrollingPatch {
    public static let applyOnce: Void = ()
}
#endif
