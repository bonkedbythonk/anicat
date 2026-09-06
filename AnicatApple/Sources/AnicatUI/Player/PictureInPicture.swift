import Foundation
#if os(macOS)
import AppKit
import Observation

/// Picture in Picture, done to the app's own window.
///
/// Not AVKit's: that wants an `AVPlayerLayer` or an
/// `AVSampleBufferDisplayLayer` to hand to the system, and mpv draws into a
/// `CAMetalLayer` of ours through `wid` (see `MpvRenderBackend`). Bridging
/// its frames into a sample-buffer layer is a different, much larger piece of
/// work. Nor can the surface simply be moved to a second window: an
/// `NSViewRepresentable` that changes call site is torn down, and
/// `dismantleNSView` stops playback — the mistake `PlayerView.isMinimized`'s
/// doc comment records as "minimize exits the stream".
///
/// So the window becomes the PiP: small, floating, on every Space, with the
/// player already filling it. Everything that made it small is remembered and
/// put back.
@MainActor
@Observable
public final class PictureInPicture {
    public static let shared = PictureInPicture()

    public private(set) var isActive = false

    private var savedFrame: NSRect?
    private var savedLevel: NSWindow.Level?
    private var savedCollectionBehavior: NSWindow.CollectionBehavior?
    private var savedMinSize: NSSize?
    private var savedContentMinSize: NSSize?
    private var exitFullScreenObserver: NSObjectProtocol?

    /// Width is fixed; height follows the video so the picture is not
    /// letterboxed inside a box that is itself a letterbox.
    public static let width: CGFloat = 480
    private static let fallbackHeight: CGFloat = 270
    private static let screenMargin: CGFloat = 24

    private init() {}

    public func toggle(aspectRatio: Double?) {
        if isActive {
            exit()
        } else {
            enter(aspectRatio: aspectRatio)
        }
    }

    public func enter(aspectRatio: Double?) {
        guard !isActive, let window = AppWindow.main else { return }

        // A fullscreen window cannot be resized at all, and playback puts the
        // window into fullscreen on its own (see RootView's
        // `activeStreamURL` edge), so this is the normal case rather than the
        // exotic one. `FullScreenGuard` serialises the exit; the rest of this
        // runs when the window says it is out.
        if window.styleMask.contains(.fullScreen) {
            observeExitFullScreenOnce(on: window) { [weak self] in
                self?.enter(aspectRatio: aspectRatio)
            }
            FullScreenGuard.set(false, on: window)
            return
        }

        savedFrame = window.frame
        savedLevel = window.level
        savedCollectionBehavior = window.collectionBehavior
        savedMinSize = window.minSize
        savedContentMinSize = window.contentMinSize
        // The content's own minimum is the full desktop layout's (a 200pt
        // rail plus a content column), and AppKit clamps `setFrame` to it —
        // without lowering these the window simply refuses to get small.
        window.minSize = NSSize(width: 200, height: 120)
        window.contentMinSize = NSSize(width: 200, height: 120)

        let height = Self.pipHeight(aspectRatio: aspectRatio)
        window.setFrame(Self.pipFrame(width: Self.width, height: height, on: window),
                        display: true, animate: true)
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isActive = true
    }

    public func exit() {
        guard isActive else { return }
        isActive = false
        guard let window = AppWindow.main else {
            clearSavedState()
            return
        }
        window.level = savedLevel ?? .normal
        window.collectionBehavior = savedCollectionBehavior ?? [.fullScreenPrimary]
        window.minSize = savedMinSize ?? .zero
        window.contentMinSize = savedContentMinSize ?? .zero
        if let savedFrame {
            window.setFrame(savedFrame, display: true, animate: true)
        }
        clearSavedState()
    }

    private func clearSavedState() {
        savedFrame = nil
        savedLevel = nil
        savedCollectionBehavior = nil
        savedMinSize = nil
        savedContentMinSize = nil
    }

    static func pipHeight(aspectRatio: Double?) -> CGFloat {
        guard let aspectRatio, aspectRatio > 0 else { return fallbackHeight }
        return (width / aspectRatio).rounded()
    }

    /// Bottom right of whichever screen the window is on, inside the visible
    /// frame so it clears the Dock and the menu bar.
    static func pipFrame(width: CGFloat, height: CGFloat, on window: NSWindow) -> NSRect {
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSRect(
            x: visible.maxX - width - screenMargin,
            y: visible.minY + screenMargin,
            width: width,
            height: height
        )
    }

    /// One-shot, and removed from inside its own handler. Left installed it
    /// would re-enter PiP on every later fullscreen exit — and
    /// `FullScreenGuard.attach` clears only the observers it owns, so this
    /// one is nobody else's to tidy up.
    private func observeExitFullScreenOnce(
        on window: NSWindow,
        then: @escaping @Sendable @MainActor () -> Void
    ) {
        if let exitFullScreenObserver {
            NotificationCenter.default.removeObserver(exitFullScreenObserver)
            self.exitFullScreenObserver = nil
        }
        exitFullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didExitFullScreenNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let token = self.exitFullScreenObserver {
                    NotificationCenter.default.removeObserver(token)
                    self.exitFullScreenObserver = nil
                }
                then()
            }
        }
    }
}
#endif
