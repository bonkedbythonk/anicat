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

        // Responsive scrolling tracks the gesture on AppKit's event thread,
        // and the main thread stops seeing the wheel events: a local
        // NSEvent monitor counted 3 of 204 events once the flag above was
        // on, so the two-finger swipe back from a detail page went dead.
        // `wantsScrollEventsForSwipeTrackingOnAxis:` is the responder hook
        // that asks the event thread to forward one axis; answering yes for
        // horizontal brought 189 of 189 back to both the monitor and
        // `scrollWheel:`. Only scroll views with nothing to scroll
        // sideways answer yes, so horizontal shelves keep the responsive
        // path for their own scrolling.
        let swipeSelector = NSSelectorFromString("wantsScrollEventsForSwipeTrackingOnAxis:")
        let swipeBlock: @convention(block) (AnyObject, Int) -> Bool = { object, axis in
            // NSEvent.GestureAxis.horizontal == 1.
            guard axis == 1, let scrollView = object as? NSScrollView else { return false }
            // AppKit asks a responder this on the main thread.
            return MainActor.assumeIsolated {
                let contentWidth = scrollView.documentView?.frame.width ?? 0
                return contentWidth <= scrollView.contentView.bounds.width + 0.5
            }
        }
        let swipeImp = imp_implementationWithBlock(swipeBlock)
        if let method = class_getInstanceMethod(cls, swipeSelector) {
            method_setImplementation(method, swipeImp)
        } else {
            class_addMethod(cls, swipeSelector, swipeImp, "B@:q")
        }
    }()
}
#else
public enum ResponsiveScrollingPatch {
    public static let applyOnce: Void = ()
}
#endif
