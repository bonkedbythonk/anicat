import Foundation
#if os(macOS)
import AppKit

/// Serialises fullscreen toggles on the main window.
///
/// `toggleFullScreen` called while AppKit is still animating the previous
/// toggle leaves the window in a half-state: the content view stops
/// receiving layout, the frame shows a stale snapshot, and a Dock click
/// opens a second window because the first no longer counts as visible.
/// Playback drives fullscreen from `activeStreamURL`'s edge and the viewer
/// drives it from Escape, F and the player button, so two toggles inside
/// one 0.6 s transition are easy to produce. Requests made mid-transition
/// are remembered and applied once the window reports the transition done.
@MainActor
public enum FullScreenGuard {
    /// Posted once a fullscreen transition has finished, either way. The
    /// player listens: this is the moment its layer has its final size.
    public static let transitionEndedNotification = Notification.Name("anicat.fullScreenTransitionEnded")
    private static var observers: [NSObjectProtocol] = []
    private static var inTransition = false
    private static var wanted: Bool?
    private static weak var window: NSWindow?

    public static func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        FullScreenState.shared.isFullScreen = window.styleMask.contains(.fullScreen)
        observers.forEach(NotificationCenter.default.removeObserver)
        self.window = window
        inTransition = false
        wanted = nil
        let center = NotificationCenter.default
        let begin: (Notification) -> Void = { _ in armTransitionTimeout() }
        let end: (Notification) -> Void = { _ in
            inTransition = false
            FullScreenState.shared.isFullScreen = self.window?.styleMask.contains(.fullScreen) ?? false
            NotificationCenter.default.post(name: FullScreenGuard.transitionEndedNotification, object: nil)
            guard let window = self.window, let target = wanted else { return }
            wanted = nil
            if window.styleMask.contains(.fullScreen) != target {
                armTransitionTimeout()
                window.toggleFullScreen(nil)
            }
        }
        observers = [
            center.addObserver(forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main, using: begin),
            center.addObserver(forName: NSWindow.willExitFullScreenNotification, object: window, queue: .main, using: begin),
            center.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main, using: end),
            center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main, using: end),
        ]
    }

    /// A transition the system cancels (Mission Control, a display change)
    /// reports failure only through delegate methods this type does not
    /// own, and would otherwise leave `inTransition` true forever with every
    /// later request queued behind it. A finished transition takes well
    /// under a second; after three the flag is assumed stale.
    private static func armTransitionTimeout() {
        inTransition = true
        let token = UUID()
        transitionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard transitionToken == token, inTransition else { return }
            inTransition = false
            if let window, let target = wanted {
                wanted = nil
                set(target, on: window)
            }
        }
    }
    private static var transitionToken = UUID()

    /// Enter or leave fullscreen, now or as soon as the current transition ends.
    public static func set(_ fullScreen: Bool, on window: NSWindow) {
        attach(to: window)
        if inTransition {
            wanted = fullScreen
            return
        }
        guard window.styleMask.contains(.fullScreen) != fullScreen else {
            wanted = nil
            return
        }
        armTransitionTimeout()
        window.toggleFullScreen(nil)
    }

    public static func toggle(on window: NSWindow) {
        // Mid-transition the style mask already shows the state being
        // entered, so the toggle target is derived from the queued request
        // when there is one.
        let current = wanted ?? window.styleMask.contains(.fullScreen)
        set(!current, on: window)
    }
}

/// Whether the main window is in fullscreen, for views that care (the
/// player's glow is fullscreen-only by default). Written by the guard on
/// every completed transition, so a view reading it is redrawn then.
@Observable
@MainActor
public final class FullScreenState {
    public static let shared = FullScreenState()
    public var isFullScreen = false
    private init() {}
}
#else
/// No window fullscreen on iOS; the player's safe-area rule reads this and
/// gets "not fullscreen", which is the honouring branch it wants there.
@Observable
@MainActor
public final class FullScreenState {
    public static let shared = FullScreenState()
    public var isFullScreen = false
    private init() {}
}
#endif
