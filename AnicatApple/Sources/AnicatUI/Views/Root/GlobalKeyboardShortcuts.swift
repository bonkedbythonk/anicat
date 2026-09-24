import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

#if os(macOS)
import AppKit

@MainActor
final class SwipeGestureTracker {
    var accumulatedDeltaX: CGFloat = 0
    var accumulatedDeltaY: CGFloat = 0
    var isCooling = false
    var gestureDisqualified = false
    var lastSwipeEventAt: Date = .distantPast
    /// Whether this gesture started over something that scrolls sideways.
    /// Decided once, when the gesture begins, and held for its whole length:
    /// a strip that has run out of travel stops looking scrollable halfway
    /// through, and the back-swipe would take over mid-flick.
    var startedOverHorizontalScroller = false

    func reset() {
        accumulatedDeltaX = 0
        accumulatedDeltaY = 0
        gestureDisqualified = false
    }
}

#if os(macOS)
/// Whether the pointer is over a scroll view that has somewhere left to go
/// sideways.
///
/// The back-swipe is a listen-only CGEvent tap, so it cannot know whether a
/// scroll view consumed the gesture -- it only sees the deltas. That was fine
/// when nothing on a detail page scrolled sideways, and stopped being fine
/// when the page grew a horizontal tab strip and horizontal shelves: scrolling
/// the tabs out to "More" and back again accumulated enough rightward travel
/// to read as a back-swipe, and the page closed.
///
/// The vertical page scroller does not match: its document is exactly as wide
/// as its clip view.
@MainActor
func pointerIsOverHorizontalScroller() -> Bool {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
          let contentView = window.contentView else { return false }
    let point = contentView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
    // The registered strips first. The hit test below walks NSViews, and a
    // SwiftUI ScrollView's content does not always sit under one in the
    // responder chain: scrolling the detail tabs out to "More" and back
    // closed the page again with the hit test in place.
    let topLeft = CGPoint(x: point.x, y: contentView.isFlipped ? point.y : contentView.bounds.height - point.y)
    if BackSwipeExemptRegions.frames.values.contains(where: { $0.contains(topLeft) }) {
        return true
    }
    guard let hit = contentView.hitTest(point) else { return false }
    return sequence(first: hit, next: { $0.superview }).contains { view in
        guard let scroll = view as? NSScrollView, let document = scroll.documentView else {
            return false
        }
        return document.frame.width > scroll.contentView.bounds.width + 1
    }
}
#endif

struct GlobalKeyboardShortcutsModifier: ViewModifier {
    @Bindable var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var monitor: Any?
    @State private var scrollMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var swipeTracker = SwipeGestureTracker()

    func body(content: Content) -> some View {
        content
            .onAppear {
                setupMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
    }

    private func setupMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event)
        }
        // Two-finger trackpad swipe back & forward navigation.
        // Accumulates horizontal scroll delta on trackpads with an idle-gap cooldown
        // and horizontal dominance guard. Triggers an instantaneous, smooth fade
        // via `model.closeDetail()` and `model.goForwardDetail()`.
        // Tracking state lives in `swipeTracker` (a plain reference type) rather
        // than view `@State` so wheel ticks do not re-evaluate `RootView` / `MediaDetailView`
        // at 120Hz during normal vertical scrolling.
        let tracker = self.swipeTracker
        // A CGEvent tap, not a local NSEvent monitor: with responsive
        // scrolling on, the monitor saw 2 of 133 trackpad events and the
        // swipe went dead (see ScrollEventTap). Listen-only, so the scroll
        // view still receives the gesture; on a detail page nothing scrolls
        // sideways, so that costs nothing.
        scrollMonitor = ScrollEventTap.shared.subscribe { [self, tracker] event in
            // The player only disqualifies the gesture while it covers the
            // screen -- `handleKeyDown`'s `playerCoversScreen` test. Gated
            // on the stream alone, back and forward were dead for as long
            // as anything was playing, mini-player included, where the
            // detail page underneath is exactly what the viewer is using.
            guard !(model.activeStreamURL != nil && !model.isPlayerMinimized),
                  model.activeReadingSession == nil,
                  !model.paletteOpen,
                  !model.shortcutsOpen else {
                return
            }

            // Trackpad swipe navigation ONLY operates when a detail page is open.
            // On the home screen and other sections, all scroll wheel events belong
            // exclusively to the page's vertical feed and horizontal carousels.
            guard model.selectedMediaDetails != nil else { return }

            let canGoBack = true
            // Forward goes inert while a person page is open: redoing a
            // detail-page step would swap the title *underneath* the
            // character page and leave that character floating over a show
            // it has nothing to do with.
            let canGoForward = model.canGoForward && !model.isPersonPageOpen

            // Only trackpad / precise scrolling gestures participate in swipe navigation
            guard event.hasPreciseScrollingDeltas else { return }

            // Ignore inertial momentum tail after fingers lift to prevent double-popping
            if !event.momentumPhase.isEmpty {
                return
            }

            let now = Date()

            // Cooldown: stay cooling until the gesture goes idle (> 0.15s gap) so one
            // physical swipe fires exactly once.
            if tracker.isCooling {
                if now.timeIntervalSince(tracker.lastSwipeEventAt) > 0.15 {
                    tracker.isCooling = false
                } else {
                    tracker.lastSwipeEventAt = now
                    return
                }
            }

            // Fresh gesture start on began phase or after an idle pause
            if event.phase == .began || now.timeIntervalSince(tracker.lastSwipeEventAt) > 0.15 {
                tracker.reset()
                let hitStart = CFAbsoluteTimeGetCurrent()
                tracker.startedOverHorizontalScroller = pointerIsOverHorizontalScroller()
                PlayerLog.write(String(format: "[scroll] back-swipe hit test %.2fms", (CFAbsoluteTimeGetCurrent() - hitStart) * 1000))
            }
            // Stamped before the strip check, not after it: with the stamp
            // below the early return, a gesture over a strip never
            // refreshed it, every tick read as a fresh gesture, and the hit
            // test above ran on all of them -- eight in 20ms in the log, at
            // 0.5ms each, for the length of the flick.
            tracker.lastSwipeEventAt = now
            // A sideways scroll belongs to whatever is under the pointer, not
            // to navigation.
            if tracker.startedOverHorizontalScroller { return }

            // Normalize deltaX so physical swipe right (back) is positive, swipe left (forward) is negative.
            let rawDeltaX = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            let rawDeltaY = event.scrollingDeltaY

            tracker.accumulatedDeltaX += rawDeltaX
            tracker.accumulatedDeltaY += abs(rawDeltaY)

            // Disqualify if vertical scrolling is clearly dominant over horizontal travel.
            if tracker.accumulatedDeltaY > abs(tracker.accumulatedDeltaX) * 1.5 && tracker.accumulatedDeltaY > 20 {
                tracker.gestureDisqualified = true
            }

            if event.phase == .ended || event.phase == .cancelled {
                tracker.reset()
                return
            }

            guard !tracker.gestureDisqualified else { return }

            let isHorizontal = abs(tracker.accumulatedDeltaX) > tracker.accumulatedDeltaY * 1.3
            let threshold: CGFloat = 50.0

            // Swipe right: Back (close detail / return to previous)
            if tracker.accumulatedDeltaX > threshold && isHorizontal && canGoBack {
                tracker.reset()
                tracker.isCooling = true
                // Once per physical gesture without a flag of its own: the
                // cooldown set on the line above is what keeps the rest of
                // one swipe's ticks from reaching here.
                AppHaptics.swipeThreshold()
                model.popBackOne()
                return
            }

            // Swipe left: Forward (redo detail navigation)
            if tracker.accumulatedDeltaX < -threshold && isHorizontal && canGoForward {
                tracker.reset()
                tracker.isCooling = true
                AppHaptics.swipeThreshold()
                model.goForwardDetail()
                return
            }

            return
        }
        // Buttons 3/4 are the standard back/forward side-buttons on 5-button mice in AppKit (0=left, 1=right, 2=middle).
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [self] event in
            guard model.selectedMediaDetails != nil || model.canGoForward else { return event }
            if event.buttonNumber == 3 && model.selectedMediaDetails != nil {
                model.popBackOne()
                return nil
            } else if event.buttonNumber == 4 && model.canGoForward && !model.isPersonPageOpen {
                model.goForwardDetail()
                return nil
            }
            return event
        }
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
        if let id = scrollMonitor as? UUID {
            ScrollEventTap.shared.unsubscribe(id)
            scrollMonitor = nil
        }
        if let m = mouseMonitor {
            NSEvent.removeMonitor(m)
            mouseMonitor = nil
        }
    }

    @MainActor
    private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
        let isCmd = event.modifierFlags.contains(.command)
        let isCtrl = event.modifierFlags.contains(.control)
        let isAlt = event.modifierFlags.contains(.option)
        let isShift = event.modifierFlags.contains(.shift)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        let rawChars = event.characters ?? ""

        // Cmd-K, Cmd-[ / Cmd-], Cmd-1...9 are Go menu items (AnicatApp's
        // AppCommands); a monitor branch here would swallow them first.

        // 2. ESC key (keyCode 53):
        // Order of dismissal:
        // 1. KeyboardShortcutsOverlay (topmost help modal)
        // 2. CommandPalette (topmost overlay)
        // 3. PlayerView (modal video overlay)
        // 4. MangaReaderView (modal reader overlay)
        // 5. MediaDetailView (detail page)
        // Not wrapped in `withAnimation`: every state `handleEscapeKey`/
        // `closeDetail`/`goForwardDetail` can touch already has its own
        // `.animation(value:)` modifier on the ZStack that renders it. A
        // second explicit transaction here raced those with a different
        // curve every keypress.
        if event.keyCode == 53 {
            // A sheet takes its own Escape (its Done button). Handled here
            // first, Escape on the cast sheet closed the detail page under it
            // and left the sheet up.
            if NSApp.keyWindow?.sheetParent != nil { return event }
            let handled = model.handleEscapeKey()
            return handled ? nil : event
        }

        // Arrow keys in AppKit automatically include `.numericPad` and `.function`
        // flags, so we exclude explicit modifiers instead of checking a raw flag mask.
        if isAlt && !isCmd && !isCtrl && !isShift && event.keyCode == 123 && model.selectedMediaDetails != nil {
            model.popBackOne()
            return nil
        }

        // Right arrow (keyCode 124) mirrors Left above — Alt+Right redoes
        // through `detailForwardStack`, matching a browser's Alt+Right/Cmd+].
        if isAlt && !isCmd && !isCtrl && !isShift && event.keyCode == 124 && model.canGoForward && !model.isPersonPageOpen {
            model.goForwardDetail()
            return nil
        }

        // Guard: Don't intercept single-key navigation when typing in an input field
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField || responder is NSText {
            return event
        }

        // 3. '?': Toggle Keyboard Shortcuts overlay
        if !isCmd && !isCtrl && !isAlt && (rawChars == "?" || chars == "?") {
            withAnimation(.snappy) {
                model.shortcutsOpen.toggle()
            }
            return nil
        }

        // 4. Player-specific shortcuts when PlayerView is active
        if model.activeStreamURL != nil && !isCmd && !isCtrl && !isAlt {
            // Spacebar: play / pause
            if event.keyCode == 49 {
                model.playerController.togglePlayPause()
                return nil
            }
            // Left arrow: seek -5s
            if event.keyCode == 123 {
                model.playerController.seekRelative(by: -5)
                return nil
            }
            // Right arrow: seek +5s
            if event.keyCode == 124 {
                model.playerController.seekRelative(by: 5)
                return nil
            }
            // Up arrow: volume +5%
            if event.keyCode == 126 {
                model.playerController.setVolume(model.playerController.volume + 0.05)
                return nil
            }
            // Down arrow: volume -5%
            if event.keyCode == 125 {
                model.playerController.setVolume(model.playerController.volume - 0.05)
                return nil
            }
            // 'm': toggle mute
            if chars == "m" {
                model.playerController.toggleMute()
                return nil
            }
            // 'f': toggle fullscreen
            if chars == "f" {
                if let window = AppWindow.main {
                    if model.activeStreamURL != nil {
                        AppWindow.setToolbarVisible(false)
                    }
                    FullScreenGuard.toggle(on: window)
                }
                return nil
            }
            // 'n': next episode
            if chars == "n" {
                model.playerController.nextEpisode()
                return nil
            }
            // 'p': previous episode. Shift excluded explicitly — this block
            // guards only the other three modifiers, so a Shift+P chord
            // would otherwise skip an episode.
            if chars == "p" && !isShift {
                model.playerController.previousEpisode()
                return nil
            }
        }

        // Shift+V: rotate video 90 degrees (off / CW / CCW)
        if model.activeStreamURL != nil && isShift && !isCmd && !isCtrl && !isAlt && chars == "v" {
            model.playerController.cycleSideways()
            return nil
        }

        // 5. Navigation shortcuts (only when no modifier keys are held)
        if !isCmd && !isCtrl && !isAlt {
            // '/': Go to Search tab
            if chars == "/" {
                withAnimation(.smooth) {
                    model.navigate(to: .search)
                }
                return nil
            }

            // Numbers 1-9: Switch views
            if let num = Int(chars), let targetSection = SidebarView.NavSection.fromNumberKey(num, mode: model.appMode) {
                withAnimation(.smooth) {
                    model.navigate(to: targetSection)
                }
                return nil
            }

            // Letter shortcuts: H (Home/Up Next), L (Library), M (Manga), N (Novels), T (Stats), D (Downloads)
            // Not while the full-size player is up: L navigated the hidden
            // sidebar to Library behind the picture and swallowed the key
            // the player's J/L seek monitor was waiting for. The mini-player
            // is browsing, so it keeps them.
            let playerCoversScreen = model.activeStreamURL != nil && !model.isPlayerMinimized
            if !playerCoversScreen, let firstChar = chars.first, let targetSection = SidebarView.NavSection.fromLetterKey(firstChar, mode: model.appMode) {
                withAnimation(.smooth) {
                    model.navigate(to: targetSection)
                }
                return nil
            }
        }

        return event
    }
}
#endif
