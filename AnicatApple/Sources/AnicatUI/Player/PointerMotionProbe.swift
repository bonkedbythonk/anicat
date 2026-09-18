#if os(macOS)
import AppKit
import SwiftUI

/// Reports pointer motion over the player without taking any input.
///
/// This replaces a `.onContinuousHover` on `PlayerView`'s root. That
/// modifier makes the view it is attached to hit-testable across its whole
/// frame, and the player's root frame is the whole window whether the
/// player is full size or a 320x180 box in the corner -- so while the
/// mini-player was up, every click and every scroll anywhere in the app hit
/// the player and died there: "if im in the mini player then i cant
/// interact with anything in anicat, not even scrolling works". A tracking
/// area is not hit testing: it reports the pointer and `hitTest` still
/// answers `nil`, so the event goes on to whatever is underneath.
struct PointerMotionProbe: NSViewRepresentable {
    var onMove: () -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onMove = onMove
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onMove = onMove
    }

    final class ProbeView: NSView {
        var onMove: (() -> Void)?
        private var trackingArea: NSTrackingArea?

        /// The whole point: invisible to hit testing, so clicks and scrolls
        /// pass straight through to the views below.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseMoved(with event: NSEvent) {
            super.mouseMoved(with: event)
            onMove?()
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            onMove?()
        }
    }
}
#endif
