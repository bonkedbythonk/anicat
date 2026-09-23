import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import Libmpv

/// Carries a non-`Sendable` value across an explicit `@Sendable` closure
/// boundary. Safe here specifically because the receiving closure only ever
/// reads it once, after the sender has already stopped touching it — not a
/// general-purpose escape hatch.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// How mpv's frames reach the screen: mpv's own `gpu-next` output through
/// Vulkan, which MoltenVK maps onto Metal, drawing into a `CAMetalLayer` we
/// own and hand over as `wid`. That needs MPVKit's libmpv, whose `moltenvk`
/// context (their patch 0001) takes the layer pointer and creates a Vulkan
/// surface on it: no window, no view of mpv's own, no render context or
/// render thread of ours. Stock mpv has no such context; its macOS backend
/// only knows how to open its own window (tried 2026-09-06 with `macvk`:
/// "[vo/gpu-next] Window size: 1920x1080" and a fullscreen window nobody
/// asked for). The OpenGL render-API path that preceded it was removed after
/// 6.0.0 and 6.0.1 shipped without anyone needing it.
///
/// Verified on an M4 Pro, macOS 26: video, subtitles, Anime4K, two
/// open/close cycles, no window of mpv's own, zero libmpv frames on the
/// main thread under `sample`.
///
/// The layer mpv draws into.
///
/// The `drawableSize` override is MPVKit's workaround, carried over: during
/// a resize MoltenVK briefly forces the drawable to 1x1 to flush a
/// presentation, and if that value sticks the picture flickers or stays
/// 1x1. Refusing sizes that small keeps the last real one.
final class MpvMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }

    /// MoltenVK sets `framebufferOnly` to true when the swapchain is only
    /// ever a colour attachment, and a framebuffer-only texture cannot be
    /// sampled by the ambient glow's scale kernel. Pinned false; the cost
    /// is a texture the GPU cannot treat as write-only, which does not
    /// register at 1080p.
    override var framebufferOnly: Bool {
        get { false }
        set {}
    }

    /// The ambient sampler. Every
    /// drawable handed to MoltenVK is registered so its presented handler
    /// can copy the finished picture.
    nonisolated(unsafe) var ambientSampler: AmbientMetalSampler?

    override func nextDrawable() -> CAMetalDrawable? {
        let drawable = super.nextDrawable()
        if let drawable, let ambientSampler {
            ambientSampler.track(drawable)
        }
        return drawable
    }
}

#if os(macOS)
/// The `.metal` child: a layer-hosting view whose layer is the
/// `MpvMetalLayer` mpv renders into. mpv's `moltenvk` context reads the
/// layer's `drawableSize` when it (re)configures and lets the swapchain
/// follow it afterwards, so this view's only job is to keep that size in
/// step with its bounds at the backing scale; there is nothing to draw.
@MainActor
public final class MpvMetalView: NSView {
    let metalLayer = MpvMetalLayer()

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = NSColor.black.cgColor
        metalLayer.contentsScale = 2
        // Layer-hosting (assign before wantsLayer), not layer-backed:
        // AppKit must not replace or manage this layer.
        layer = metalLayer
        wantsLayer = true
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public override func layout() {
        super.layout()
        syncDrawableSize()
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        syncDrawableSize()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncDrawableSize()
    }

    private var pendingDrawableSync: DispatchWorkItem?
    private var pendingDrawableReport: DispatchWorkItem?
    /// The size last handed to `onDrawableSizeChanged`; see the work item in
    /// `syncDrawableSize`.
    private var lastReportedDrawableSize: CGSize = .zero

    /// Fired after a settled resize has been applied to the layer. mpv's
    /// MoltenVK context reads the layer's size only when the video
    /// reconfigures, never on a plain resize, so after a window or
    /// fullscreen change libplacebo drew the old-sized picture into the
    /// top-left of the new-sized drawable and left the rest black. The
    /// coordinator answers this by forcing one reconfig.
    var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// The layer's frame follows the bounds immediately (Core Animation
    /// scales the last drawable into it, so the picture never tears or
    /// gaps), but the drawable size, which is what makes MoltenVK rebuild
    /// the swapchain, is applied at most once per 50ms. SwiftUI animates
    /// the mini-player's frame change by re-laying this view out on every
    /// frame of the minimize spring; a swapchain rebuild per frame on top
    /// of decoding and rendering is what made the whole app hitch each time
    /// the player was minimized or restored.
    ///
    /// The 50ms is a *trailing* debounce, not a rate limit, which is why the
    /// spring's settling tail costs nothing extra: every layout pass cancels
    /// the pending work item, so exactly one rebuild happens 50ms after the
    /// frame stops moving, however long it took to get there.
    func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        if DebugHooks.env("ANICAT_PLAYER_DEBUG") != nil || metalLayer.drawableSize != CGSize(width: bounds.width * scale, height: bounds.height * scale) {
            PlayerLog.write(String(format: "[metal] bounds %@ scale %.0f drawable %@ superview %@", NSStringFromRect(bounds), scale, NSStringFromSize(metalLayer.drawableSize), superview.map { NSStringFromRect($0.frame) } ?? "-"))
        }
        pendingDrawableSync?.cancel()
        let changingFullScreen = FullScreenState.shared.isTransitioning
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.metalLayer.drawableSize != target {
                self.metalLayer.drawableSize = target
            }
            // Against the last size reported, not the layer's own: while a
            // picture is playing MoltenVK rebuilds its swapchain and writes
            // `drawableSize` itself, so the layer already read `target` by the
            // time this ran and the report was skipped. A minimize while
            // playing logged the drawable stepping down to 639x359 with no
            // "[nudge] drawable now" at all and the size check still comparing
            // against 2500x1560; the mini-player showed the top-left of the
            // full picture, and a restore after a paused minimize stayed at
            // 320x180 in the corner. Only a paused resize, where nothing
            // renders, ever reached mpv.
            // Fullscreen applies the drawable on every layout pass (below), so
            // the report gets a trailing 50ms of its own there. Minimizing or
            // restoring the fullscreen player re-lays this view out about 70
            // times, and each report was a nudge; paused, each nudge is a
            // refresh seek. The player log of a paused restore ended with the
            // vo at 640x360 in a 3024x1898 layer and the size check out of
            // attempts; with this, one report each way, reconfigured in
            // 0.12s.
            self.pendingDrawableReport?.cancel()
            let report = DispatchWorkItem { [weak self] in
                guard let self, self.lastReportedDrawableSize != target else { return }
                self.lastReportedDrawableSize = target
                self.onDrawableSizeChanged?(target)
            }
            self.pendingDrawableReport = report
            if changingFullScreen && self.lastReportedDrawableSize.width > 1 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: report)
            } else {
                report.perform()
            }
        }
        pendingDrawableSync = work
        // Debounce is only for the mini-player minimize spring, which
        // re-lays this view out every frame; a swapchain rebuild per frame
        // was the hitch. Fullscreen enter/exit is one step change, and the
        // debounce there let mpv configure at the stale windowed size in
        // the 50ms gap and keep it (the picture stuck in the top-left of a
        // fullscreen window, seen in the player log on a replay). So: apply
        // now on the first size, and whenever the window is or is becoming
        // fullscreen; debounce only a plain windowed resize.
        //
        // Immediate only while fullscreen is being entered or left, not for
        // as long as the window is fullscreen: minimizing to the mini-player
        // and back inside a fullscreen window re-laid this view out about 70
        // times, each applied, each a swapchain rebuild. Paused, whichever
        // rebuild came last was never drawn into -- the picture stayed at
        // 640x360 in the corner of a 3024x1898 layer, over black or magenta,
        // with mpv's own size check reading the right size. The spring
        // settles into one rebuild with a trailing 120ms; 50ms fired mid-
        // spring on a loaded main thread, whose layout steps came 30-40ms
        // apart.
        if metalLayer.drawableSize == .zero || metalLayer.drawableSize.width <= 1 || changingFullScreen {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }
}

/// The view SwiftUI hosts. It owns pointer handling and reports its size to
/// the controller; an `MpvMetalView` child does the drawing. The iOS twin puts a UIKit
/// `CAMetalLayer` view in the same slot under the same coordinator.
///
/// Pointer events live on a transparent topmost subview rather than on the
/// render child, so a child that handles events itself (mpv's own view
/// subclass, in a backend that inserts one) cannot swallow the click.
@MainActor
public final class MpvHostView: NSView {
    public weak var coordinator: MpvSurface.Coordinator?
    public private(set) var metalView: MpvMetalView?
    private let eventCatcher = MpvEventCatcherView(frame: .zero)

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        let metal = MpvMetalView(frame: bounds)
        metal.autoresizingMask = [.width, .height]
        addSubview(metal)
        metalView = metal
        eventCatcher.frame = bounds
        eventCatcher.autoresizingMask = [.width, .height]
        addSubview(eventCatcher)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public override var isFlipped: Bool { false }

    /// mpv adds its subview at the end; keep the catcher above it.
    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        if subview !== eventCatcher, eventCatcher.superview === self {
            eventCatcher.removeFromSuperview()
            addSubview(eventCatcher)
        }
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        eventCatcher.coordinator = coordinator
        coordinator?.attachMpv(to: self)
        reportContainerSize()
    }

    public override func layout() {
        super.layout()
        reportContainerSize()
    }

    func reportContainerSize() {
        coordinator?.controller.videoContainerSize = bounds.size
    }

    /// Rounded corners for the mini-player, applied on this layer rather
    /// than through SwiftUI's `.clipShape`. A clip shape over a view whose
    /// layer changes every frame becomes a mask layer, and Core Animation
    /// then renders the 60fps video offscreen before masking it, every
    /// frame, for as long as the mini-player is up. `cornerRadius` with
    /// `masksToBounds` is handled during compositing.
    public func setCornerRadius(_ radius: CGFloat) {
        guard let layer, layer.cornerRadius != radius else { return }
        layer.cornerRadius = radius
        layer.masksToBounds = radius > 0
    }
}

/// Transparent, topmost, and the only thing that hears the pointer. See
/// `MpvHostView`.
@MainActor
final class MpvEventCatcherView: NSView {
    weak var coordinator: MpvSurface.Coordinator?
    private var trackingArea: NSTrackingArea?

    override var isOpaque: Bool { false }

    /// Every click toggles play/pause immediately, no waiting to see if a
    /// second click is coming — `clickCount` on this same event already
    /// tells us that. A double click also carries a fullscreen toggle, at
    /// the cost of two play/pause flips netting out to no state change
    /// (the same trade-off YouTube's own player makes) rather than making
    /// every single click wait ~300ms to find out whether it's a double.
    override func mouseDown(with event: NSEvent) {
        coordinator?.controller.togglePlayPause()
        if event.clickCount >= 2 {
            if let window = AppWindow.main ?? NSApp.keyWindow {
                AppWindow.setToolbarVisible(false)
                FullScreenGuard.toggle(on: window)
            }
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        self.trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        coordinator?.controller.showControlsBriefly()
    }
}

#else

/// The iOS `.metal` child. UIKit has no layer-hosting concept, so the layer
/// is claimed through `layerClass` instead: the view's own backing layer
/// *is* the `MpvMetalLayer`, which is what keeps UIKit from swapping in a
/// plain `CALayer` the way an assigned one would be.
@MainActor
public final class MpvMetalView: UIView {
    public override class var layerClass: AnyClass { MpvMetalLayer.self }

    var metalLayer: MpvMetalLayer { layer as! MpvMetalLayer }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        syncDrawableSize()
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        syncDrawableSize()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        syncDrawableSize()
    }

    func syncDrawableSize() {
        // `UIScreen.main` only as a fallback: it is the wrong screen on an
        // external display and deprecated besides, but a view that has not
        // reached a window yet has no screen of its own to ask.
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        let target = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard metalLayer.drawableSize != target else { return }
        metalLayer.drawableSize = target
        onDrawableSizeChanged?(target)
    }

    /// Same contract as the macOS twin: the coordinator forces a vo
    /// reconfig so mpv's MoltenVK context re-reads the drawable size.
    var onDrawableSizeChanged: ((CGSize) -> Void)?
}

/// The iOS twin of `MpvHostView`, same contract: it owns touch handling and
/// reports its size to the controller, and the `MpvMetalView` under it does
/// the drawing for the one backend iOS has.
@MainActor
public final class MpvHostView: UIView {
    public weak var coordinator: MpvSurface.Coordinator?
    public private(set) var metalView: MpvMetalView?
    private let eventCatcher = MpvEventCatcherView(frame: .zero)

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        let metal = MpvMetalView(frame: bounds)
        metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metal)
        metalView = metal
        eventCatcher.frame = bounds
        eventCatcher.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(eventCatcher)
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// mpv adds its subview at the end; keep the catcher above it.
    public override func didAddSubview(_ subview: UIView) {
        super.didAddSubview(subview)
        if subview !== eventCatcher, eventCatcher.superview === self {
            bringSubviewToFront(eventCatcher)
        }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        eventCatcher.coordinator = coordinator
        // Before `attachMpv`, not after: UIKit runs `didMoveToWindow` ahead
        // of the first `layoutSubviews`, so mpv's moltenvk context would
        // otherwise configure its swapchain against the layer's default
        // drawable size rather than the one this view is about to have.
        metalView?.syncDrawableSize()
        coordinator?.attachMpv(to: self)
        reportContainerSize()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        reportContainerSize()
    }

    func reportContainerSize() {
        coordinator?.controller.videoContainerSize = bounds.size
    }

    /// Same contract as the macOS host: see its `setCornerRadius`.
    public func setCornerRadius(_ radius: CGFloat) {
        guard layer.cornerRadius != radius else { return }
        layer.cornerRadius = radius
        layer.masksToBounds = radius > 0
    }
}

/// Transparent, topmost, and the only thing that hears the touch. See
/// `MpvHostView`.
@MainActor
final class MpvEventCatcherView: UIView {
    weak var coordinator: MpvSurface.Coordinator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap))
        tap.numberOfTapsRequired = 1
        addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// One recognizer, deliberately: there is no fullscreen to toggle on
    /// iOS, so a second double-tap recognizer would buy nothing and cost
    /// every single tap the double-tap timeout before it could fire. A
    /// double tap therefore flips play/pause twice and nets out, the same
    /// trade-off the macOS catcher's `clickCount` comment records.
    @objc private func handleTap() {
        coordinator?.controller.togglePlayPause()
    }
}
#endif

public struct MpvSurface {
    @Bindable public var controller: PlayerController
    public let streamURL: URL?
    /// See `MpvHostView.setCornerRadius`.
    public let cornerRadius: CGFloat

    public init(controller: PlayerController, streamURL: URL?, cornerRadius: CGFloat = 0) {
        self.controller = controller
        self.streamURL = streamURL
        self.cornerRadius = cornerRadius
    }

    /// The body of `makeNSView`/`makeUIView`. Shared so the two
    /// representable conformances below are nothing but their required
    /// spellings — everything they actually do is the same.
    @MainActor
    fileprivate func makeHostView(coordinator: Coordinator) -> MpvHostView {
        let view = MpvHostView(frame: .zero)
        view.coordinator = coordinator
        coordinator.hostView = view
        coordinator.controller = controller

        if let streamURL {
            coordinator.setPendingStreamURL(streamURL.absoluteString)
        }

        return view
    }

    /// The body of `updateNSView`/`updateUIView`.
    @MainActor
    fileprivate func updateHostView(_ view: MpvHostView, coordinator: Coordinator) {
        view.coordinator = coordinator
        coordinator.hostView = view
        view.setCornerRadius(cornerRadius)
        coordinator.controller = controller

        if view.window != nil && coordinator.mpvHandle == nil {
            coordinator.attachMpv(to: view)
        }

        if let streamURL {
            coordinator.loadFile(url: streamURL.absoluteString)
        } else {
            coordinator.clearLoadedURL()
        }

        coordinator.setPaused(!controller.isPlaying)
        coordinator.applyAnime4K(enabled: controller.isAnime4KEnabled)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public final class Coordinator: NSObject, @unchecked Sendable {
        private var mpv: OpaquePointer?
        /// Held by every caller that reads `mpv` off the main thread, and by
        /// `stop()` while it takes the handle away. `stop()` only waits for
        /// the event loop before `mpv_destroy`; a track walk on a global
        /// queue that had already passed its `guard let mpv` kept using the
        /// freed core.
        private let handleLock = NSLock()

        /// Runs `body` with the handle pinned, or returns nil once `stop()`
        /// has taken it. Not for the main thread or the event loop, which
        /// are ordered against `stop()` already; nesting it deadlocks.
        private func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
            handleLock.lock()
            defer { handleLock.unlock() }
            guard let mpv else { return nil }
            return body(mpv)
        }
        private var isRunning = false
        fileprivate var controller: PlayerController
        fileprivate weak var hostView: MpvHostView?
        private var lastLoadedURL: String?
        private var pendingStreamURL: String?
        private var lastAnime4KState: Bool?
        private var sidewaysSavedHwdec: String?
        /// The `sid` the viewer picked from the subtitle list, so a later
        /// Sub/Dub toggle re-applies it rather than running the language
        /// rule over the top of it. Scoped to one file: track ids mean
        /// nothing across releases, so `loadFile` clears it.
        private var explicitSubtitleTrackId: String?
        /// Whether this file has already had the title's remembered tracks
        /// put back. `MPV_EVENT_FILE_LOADED` is not the only event that can
        /// arrive for one file, and re-applying would undo a pick the viewer
        /// made after the load.
        private var didApplyTrackMemory = false
        // Signaled once by the event-loop task's own thread when it has
        // actually stopped touching `mpv`, so `stop()` can block until that
        // happens before it frees the render context or destroys the
        // handle. Waiting on `isRunning` alone was not enough — the flag
        // flipping false and the loop noticing it are two different threads
        // observing the same field with no ordering between them and
        // whoever's `mpv`/render-context call landed first.
        private let eventLoopStopped = DispatchSemaphore(value: 0)

        public var mpvHandle: OpaquePointer? { mpv }

        init(controller: PlayerController) {
            self.controller = controller
            super.init()
        }

        deinit {
            // `dismantleNSView` stops the coordinator on the main thread
            // before releasing it; this only catches one dropped without it.
            guard isRunning else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated { stop() }
            } else {
                assertionFailure("MpvSurface.Coordinator released off the main thread while running")
            }
        }

        func setPendingStreamURL(_ url: String) {
            pendingStreamURL = url
        }

        @MainActor
        func attachMpv(to view: MpvHostView) {
            guard mpv == nil else { return }
            setupMpv(for: view, controller: controller)
        }

        @MainActor
        func setupMpv(for view: MpvHostView, controller: PlayerController) {
            guard mpv == nil else { return }

            guard let handle = mpv_create() else {
                print("[libmpv] Failed to create mpv instance")
                return
            }

            do {
                // See `MpvMetalLayer`. `wid` is the CAMetalLayer pointer;
                // MPVKit's moltenvk context bridges it back and creates the
                // Vulkan surface on it. All of this must precede
                // mpv_initialize, after which the vo already exists.
                // The layer is not Sendable, so only its address leaves
                // the main-actor block; that address is all mpv wants.
                let layerAddress: Int64? = MainActor.assumeIsolated {
                    view.metalView.map { Int64(Int(bitPattern: Unmanaged.passUnretained($0.metalLayer).toOpaque())) }
                }
                guard var wid = layerAddress else {
                    print("[libmpv] metal backend without a metal layer")
                    mpv_destroy(handle)
                    return
                }
                MainActor.assumeIsolated {
                    // Seeded from the layer as it is now: the first size was
                    // applied before this closure existed, and a check that
                    // knows no size checks nothing.
                    self.lastDrawableSize = view.metalView?.metalLayer.drawableSize ?? .zero
                    PlayerLog.write(String(format: "[libmpv] surface attached, layer %.0fx%.0f", self.lastDrawableSize.width, self.lastDrawableSize.height))
                    view.metalView?.onDrawableSizeChanged = { [weak self] size in
                        self?.drawableSizeChanged(to: size)
                    }
                    #if os(macOS)
                    self.fullScreenObserver = NotificationCenter.default.addObserver(
                        forName: FullScreenGuard.transitionEndedNotification, object: nil, queue: .main
                    ) { [weak self, weak view] _ in
                        guard let self, let view else { return }
                        MainActor.assumeIsolated { self.fullScreenTransitionEnded(view: view) }
                    }
                    #endif
                    if let layer = view.metalView?.metalLayer,
                       let device = layer.device ?? MTLCreateSystemDefaultDevice(),
                       let sampler = AmbientMetalSampler(device: device) {
                        sampler.videoAspect = { [weak self] in self?.controller.videoAspectRatio }
                        sampler.playbackPosition = { [weak self] in self?.controller.currentTime ?? -1 }
                        sampler.onThumbnail = { [weak self] image, inset in
                            guard let self else { return }
                            // Sideways for the same reason the view drops the
                            // glow there: the picture is rotated inside the
                            // window, so an edge of the frame is no longer the
                            // edge of the window it would be painted into.
                            // Gated here as well so the sampled frames are not
                            // handed over to be thrown away.
                            guard UserDefaults.standard.object(forKey: "anicat_ambient_glow") as? Bool ?? true,
                                  self.controller.sidewaysState == 0,
                                  !self.controller.awaitingNewFile else { return }
                            self.controller.setAmbientFrame(image, inset: inset)
                        }
                        layer.ambientSampler = sampler
                        self.usesMetalAmbientSampler = true
                        // Which of the two sampling paths this machine ended
                        // up on, in the log rather than behind a debug env
                        // var: the fallback's own symptom (a glow that lags
                        // or freezes) is the same shape as several other
                        // reports, and nothing in a sent-in log said which
                        // path was running.
                        PlayerLog.write("[glow] sampling the presented drawable")
                    } else {
                        PlayerLog.write("[glow] no Metal sampler; falling back to screenshot-raw")
                    }
                }
                mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
                mpv_set_option_string(handle, "vo", "gpu-next")
                mpv_set_option_string(handle, "gpu-api", "vulkan")
                mpv_set_option_string(handle, "gpu-context", "moltenvk")
                // None of mpv's own input: the event catcher hears the
                // pointer and the app owns the keyboard.
                mpv_set_option_string(handle, "input-cursor", "no")
                mpv_set_option_string(handle, "input-vo-keyboard", "no")
                mpv_set_option_string(handle, "input-media-keys", "no")
                // mpv's own warnings to stderr: a vo that fails to come up
                // says why there and nowhere else, and libmpv is silent by
                // default.
                mpv_set_option_string(handle, "terminal", "yes")
                mpv_set_option_string(handle, "msg-level", "all=warn")
            }
            mpv_set_option_string(handle, "keep-open", "yes")

            // High-performance Apple Silicon settings.
            // "Hardware Decoding" in Settings was decorative until this read
            // it back — re-wire on every mpv rewrite that touches this line.
            let hwdecEnabled = UserDefaults.standard.object(forKey: "anicat_hardware_decoding") == nil
                || UserDefaults.standard.bool(forKey: "anicat_hardware_decoding")
            mpv_set_option_string(handle, "hwdec", hwdecEnabled ? "videotoolbox" : "no")
            mpv_set_option_string(handle, "osc", "no")
            mpv_set_option_string(handle, "osd-level", "0")
            mpv_set_option_string(handle, "input-default-bindings", "no")
            mpv_set_option_string(handle, "demuxer-max-bytes", "128M")
            mpv_set_option_string(handle, "demuxer-readahead-secs", "15")
            mpv_set_option_string(handle, "demuxer-seekable-cache", "yes")
            mpv_set_option_string(handle, "cache", "yes")
            mpv_set_option_string(handle, "cache-pause", "yes")
            mpv_set_option_string(handle, "force-seekable", "yes")
            mpv_set_option_string(handle, "hr-seek", "default")
            mpv_set_option_string(handle, "ytdl", "no")
            mpv_set_option_string(handle, "sub-auto", "fuzzy")
            mpv_set_option_string(handle, "slang", "en,eng,English")
            // Pinned rather than inherited from whatever this build of mpv
            // defaults to: the other settings of this option make mpv drop
            // to a forced/signs track, or to none at all, once the audio it
            // picks is English too, which is exactly the file a dub release
            // opens as. `applySubtitlePreference` is then the only thing
            // narrowing subtitles, and only when Dub was actually asked for.
            mpv_set_option_string(handle, "subs-with-matching-audio", "yes")
            // A dual-audio release carries both tracks and mpv defaults to
            // the file's own flagged one (Japanese, on every release that
            // has one), so "Dubbed" played in Japanese no matter what the
            // resolve picked. `alang` is read at file load, which is why the
            // mid-episode switch goes through `selectAudioLanguage` instead.
            mpv_set_option_string(handle, "alang", Self.audioLanguages(preferDub: Self.preferDubSetting()))
            mpv_set_option_string(handle, "subs-fallback", "yes")
            #if os(macOS)
            // macOS 27 answers mpv 0.41's kAudioOutputUnitProperty_ChannelMap
            // with -50 when the unit was given a planar format, and FFmpeg
            // decodes AAC to planar float, so ao_coreaudio's init failed on
            // nearly every file ("requested format: ... floatp", then "unable
            // to set the input channel layout"). mpv fell back to
            // avfoundation, and the failed init left its CoreAudio hotplug
            // listener registered on the ao it had just freed: the next
            // device change ran hotplug_cb on freed memory, SIGSEGV in
            // mp_msg_va off a HAL listener queue, four reports 2026-09-16.
            // Interleaved float makes the init succeed, so there is no
            // fallback and no dangling listener. Forcing `ao=avfoundation`
            // was tried first and stopped the crash, but that output takes
            // seconds to follow AirPods going in or out (it froze outright
            // without an `ao-reload` of our own); coreaudio follows the
            // default device within ~40ms, measured in the same session.
            // Stereo is forced because mono was recorded drawing the same -50
            // (2026-09-16 notes; not re-measured), and one mono file falling
            // back is the crash again. Upstream:
            // mpv#18384 (the -50) and mpv#18382 (the listener); drop this
            // once MPVKit ships an mpv with both.
            if ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 27 {
                mpv_set_option_string(handle, "audio-format", "float")
                mpv_set_option_string(handle, "audio-channels", "stereo")
            }
            #endif

            let initStatus = mpv_initialize(handle)
            if initStatus < 0 {
                print("[libmpv] Failed to initialize mpv: \(initStatus)")
                mpv_destroy(handle)
                return
            }


            self.mpv = handle
            self.isRunning = true
            // Verbose, filtered to the `ao` prefixes in the event loop. At
            // `all=warn` the log showed that coreaudio's init failed and
            // nothing about why: the "requested format: ... floatp" line that
            // named the cause is a verbose one.
            mpv_request_log_messages(handle, "v")

            controller.onSeek = { [weak self] seconds in
                self?.seek(to: seconds)
            }
            controller.onSetPause = { [weak self] paused in
                self?.setPaused(paused)
            }
            controller.onSelectAudioLanguage = { [weak self] preferDub, completion in
                // Off the main thread: `selectAudioLanguage` walks
                // `track-list/N/...` with blocking property reads.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let switched = self.flatMap { s in s.withHandle { _ in s.selectAudioLanguage(preferDub: preferDub) } } ?? false
                    Task { @MainActor in completion(switched) }
                }
            }
            controller.onFetchTracks = { [weak self] completion in
                // Same reason as above, more so: this reads five
                // sub-properties per track over the whole list.
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let tracks = self.flatMap { s in s.withHandle { _ in s.trackList() } } ?? (audio: [], subtitle: [])
                    Task { @MainActor in completion(tracks.audio, tracks.subtitle) }
                }
            }
            controller.onFetchMpvDetails = { [weak self] completion in
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    let rows = self.flatMap { s in s.withHandle { _ in s.streamDetailRows() } } ?? []
                    Task { @MainActor in completion(rows) }
                }
            }
            controller.onSelectAudioTrack = { [weak self] id in
                self?.selectAudioTrack(id: id)
            }
            controller.onSelectSubtitleTrack = { [weak self] id in
                self?.selectSubtitleTrack(id: id)
            }
            controller.onSetVolume = { [weak self] volume in
                self?.setVolume(volume)
            }
            controller.onSetMuted = { [weak self] muted in
                self?.setMuted(muted)
            }
            controller.onSetSpeed = { [weak self] rate in
                self?.setSpeed(rate)
            }
            controller.onSetVideoEnabled = { [weak self] enabled in
                self?.setVideoEnabled(enabled)
            }
            controller.onSetSubtitleScale = { [weak self] scale in
                self?.setSubtitleScale(scale)
            }
            controller.onSetSubtitleStyle = { [weak self] style in
                self?.setSubtitleStyle(style)
            }
            controller.onCycleSideways = { [weak self] in
                self?.cycleSideways()
            }
            controller.onSetFillScreen = { [weak self] fill, crop in
                self?.setFillScreen(fill, crop: crop)
            }

            mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
            mpv_observe_property(handle, 4, "paused-for-cache", MPV_FORMAT_FLAG)
            mpv_observe_property(handle, 5, "cache-buffering-state", MPV_FORMAT_INT64)
            // NONE: a notification only. The ranges are read back as
            // sub-properties, the way the track list is, rather than by
            // walking the MPV_FORMAT_NODE map.
            mpv_observe_property(handle, 10, "demuxer-cache-state", MPV_FORMAT_NONE)
            // The end of the file as mpv sees it, not as `duration` says.
            // Every end-of-episode rule keys on `duration - time-pos`, and
            // `duration` is not always the file's: a reopened episode asked
            // AniSkip with 1407s for a 1380s file (anicat.log, 2026-09-11),
            // and against 1407 the last tick sits 27s short of every mark,
            // so neither the card nor auto-next ever fired. With keep-open
            // this goes true on the last frame. It never fires on a torrent
            // whose tail is not downloaded, so it is a backstop
            // for the position rules, not a replacement.
            mpv_observe_property(handle, 11, "eof-reached", MPV_FORMAT_FLAG)
            // The ASS header of whichever subtitle track is showing, so a
            // style's sizes can be put into that file's own units: changes
            // with every file and every track switch.
            mpv_observe_property(handle, 12, "sub-ass-extradata", MPV_FORMAT_NONE)
            // Which decoder mpv actually settled on, into the log: whether a
            // file plays on VideoToolbox or falls back to software decoding
            // is invisible otherwise, and a software fallback costs about 20
            // CPU points for as long as the file plays. Fires once per file
            // once the decoder is up, and again if mpv switches.
            mpv_observe_property(handle, 13, "hwdec-current", MPV_FORMAT_NONE)
            // Displayed size — what the overlay chrome needs to know where
            // the letterboxed video rect actually sits, as opposed to the
            // window's own size.
            //
            // `video-out-params`, not `video-params`: the latter is the
            // decoder's output, before the filter chain. Sideways mode
            // rotates the picture with a `vf` transpose, so under
            // `video-params` a 16:9 file still reported 16:9 while a 9:16
            // picture was on screen -- the chrome laid its bars out across
            // the middle of the turned picture and called the tall black
            // margins beside it part of the frame.
            mpv_observe_property(handle, 6, "video-out-params/dw", MPV_FORMAT_INT64)
            mpv_observe_property(handle, 7, "video-out-params/dh", MPV_FORMAT_INT64)
            mpv_observe_property(handle, 8, "video-params/dw", MPV_FORMAT_INT64)
            mpv_observe_property(handle, 9, "video-params/dh", MPV_FORMAT_INT64)

            startEventLoop()

            applyAnime4K(enabled: controller.isAnime4KEnabled)
            setPaused(!controller.isPlaying)
            setVolume(controller.volume)
            setMuted(controller.isMuted)
            setSpeed(controller.playbackRate)
            setSubtitleScale(PlayerController.subtitleScaleSetting)
            setSubtitleStyle(SubtitleStyle.current)
            if controller.isFillingScreen {
                setFillScreen(true, crop: controller.fillCrop)
            }

            if let pending = pendingStreamURL {
                loadFile(url: pending)
            }
        }

        /// Makes the vo reconfigure so the MoltenVK context re-reads the
        /// layer's drawable size (see `MpvMetalView.onDrawableSizeChanged`).
        ///
        /// mpv reconfigures the vo only when the output image parameters
        /// change, and only when a frame next passes through the filter
        /// chain. The first version of this set the aspect override to a
        /// detour and straight back, two commands in one frame interval,
        /// and mpv, seeing the same parameters at the next frame, did
        /// nothing at all: the player log shows three "forcing a reconfig"
        /// lines in a row with the vo still at the windowed size, and the
        /// picture at 72% in the top-left of the window. So the detour is
        /// held until the vo has actually reconfigured (or 250 ms, whichever
        /// is first) and then the original is restored, which is a second
        /// reconfig at the same drawable size.
        ///
        /// The detour is the picture's own aspect widened by one part in two
        /// thousand: a different rational for mpv, one pixel across a 1920
        /// wide picture for the eye. The 1.0 / 1.5 detour it replaces was a
        /// visible squeeze for however long it lasted.
        /// Returns whether a detour went out now; false when there is no
        /// handle or the nudge was deferred behind one still held.
        @discardableResult
        /// `reason` names the caller in the log line. A nudge is the one
        /// thing in the player that makes mpv reconfigure the output
        /// mid-stream, and a reconfig is a one-frame black; the owner
        /// reported the picture "blinking" mid-episode and the log had no
        /// line for the nudges the layout path sends, so it could not say
        /// whether they were the cause. Rare enough to log always.
        func nudgeVideoReconfig(reason: String = "size check") -> Bool {
            let debug = DebugHooks.env("ANICAT_PLAYER_DEBUG") != nil
            guard mpv != nil else {
                if debug { PlayerLog.write("[nudge] skipped: no handle") }
                return false
            }
            nudgeLock.lock()
            defer { nudgeLock.unlock() }
            guard restoreAspectOverride == nil else {
                // Deferred, not dropped: `scheduleNudgeRestore` runs it once
                // the pending detour is back. The mini-player restore that
                // left the picture at 320x180 in the top-left of the full
                // player logged the drawable applied about thirty times in
                // 600ms (640x360 up to 2521x1574 and back down to 2501x1561,
                // a step every 30-40ms on a loaded main thread), so most of
                // the size changes landed inside another nudge's window, and
                // the ones that did were skipped.
                nudgeRequestedWhilePending = true
                if debug { PlayerLog.write("[nudge] deferred: restore pending") }
                return false
            }
            let current = stringProperty("video-aspect-override") ?? "-1"
            // Written as steps: the one-expression version of this chain
            // took the CI toolchain past its type-check budget.
            var aspect: Double = 16.0 / 9.0
            if let reported = stringProperty("video-params/aspect").flatMap(Double.init), reported > 0 {
                aspect = reported
            } else if let overridden = Double(current), overridden > 0 {
                aspect = overridden
            }
            // Away from whatever is set now, and never restored to a detour.
            // The player log had `video-aspect-override` parked at 1.778667
            // (16:9 times 1.0005, the detour itself) for minutes: a nudge had
            // read the previous nudge's detour as the value to restore, so
            // every nudge after it set the value already in place, mpv saw
            // no change and never reconfigured, and the 320x180 mini-player
            // showed the top-left of a 1673x941 picture. Nothing in the app
            // sets a real override, so anything positive here is a leftover
            // detour and goes back to mpv 0.41's default of -2 (container
            // aspect) rather than being preserved.
            let up = aspect * 1.0005, down = aspect * 0.9995
            let detour = abs((Double(current) ?? -1) - up) < 0.0001 ? down : up
            restoreAspectOverride = (Double(current) ?? 1) <= 0 ? current : "-2"
            nudgeOSDBefore = stringProperty("osd-dimensions/w")
            // Paused, no frame is coming, so mpv carries the detour to the vo
            // with a refresh seek that re-decodes from a keyframe over the
            // stream. Restored at 250ms, the original went back before that
            // frame arrived and nothing reconfigured: a paused minimize at
            // 2:05 logged three nudges "reconfigured no" and gave up with the
            // vo at 3024x1898 in a 640x360 layer. Held up to 2s, the same
            // minimize reconfigured on the first nudge.
            nudgeTimeout = stringProperty("pause") == "yes" ? 2.0 : 0.25
            PlayerLog.write(String(format: "[nudge] %@: override %@ -> %.6f, osd/w %@, layer %.0fx%.0f, paused %@", reason, current, detour, nudgeOSDBefore ?? "-", lastDrawableSize.width, lastDrawableSize.height, stringProperty("pause") ?? "-"))
            runCommand(["set", "video-aspect-override", String(format: "%.6f", detour)])
            scheduleNudgeRestore(after: 0.03)
            return true
        }

        /// Presents the paused frame again: an exact seek to where playback
        /// already is. mpv has no redraw command (`--input-cmdlist` on 0.41).
        /// Caller holds `handleLock`.
        private func refreshPausedFrame() {
            guard let position = stringProperty("time-pos") else { return }
            runCommand(["seek", position, "absolute+exact"])
        }

        private let nudgeLock = NSLock()
        private var nudgeRequestedWhilePending = false
        private var restoreAspectOverride: String?
        private var nudgeOSDBefore: String?
        private var nudgeWaitedFor: Double = 0
        private var nudgeTimeout: Double = 0.25

        /// Polls for the reconfig the detour was meant to cause, then puts
        /// the original override back. Polling rather than waiting for
        /// `MPV_EVENT_VIDEO_RECONFIG`: that event also fires for the restore
        /// itself and for every file load, and telling them apart is more
        /// state than a 30 ms check needs.
        private func scheduleNudgeRestore(after delay: Double) {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // handleLock outside nudgeLock, the only place both are
                // held; nothing takes them the other way round.
                self.handleLock.lock()
                defer { self.handleLock.unlock() }
                guard self.mpv != nil else { return }
                self.nudgeLock.lock()
                guard let original = self.restoreAspectOverride else {
                    self.nudgeLock.unlock()
                    return
                }
                self.nudgeWaitedFor += delay
                let reconfigured = self.stringProperty("osd-dimensions/w") != self.nudgeOSDBefore
                    || self.nudgeOSDBefore == nil
                if !reconfigured && self.nudgeWaitedFor < self.nudgeTimeout {
                    self.nudgeLock.unlock()
                    self.scheduleNudgeRestore(after: 0.03)
                    return
                }
                self.restoreAspectOverride = nil
                let waited = self.nudgeWaitedFor
                self.nudgeWaitedFor = 0
                let again = self.nudgeRequestedWhilePending
                self.nudgeRequestedWhilePending = false
                self.nudgeLock.unlock()
                if DebugHooks.env("ANICAT_PLAYER_DEBUG") != nil {
                    PlayerLog.write(String(format: "[nudge] restore to %@ after %.2fs, reconfigured %@%@", original, waited, reconfigured ? "yes" : "no", again ? ", running the deferred one" : ""))
                }
                self.runCommand(["set", "video-aspect-override", original])
                // Paused, the reconfigure resized the swapchain and nothing
                // drew into it again: back from the mini-player the log had
                // "vo is 2598x1623, layer is 3024x1898; forcing a reconfig",
                // the size check passed after it, and the paused frame stayed
                // at 86% in the top-left of the window. An exact seek to
                // where playback already is decodes and presents that frame
                // at the new size without moving the position.
                if !again, self.stringProperty("pause") == "yes" {
                    self.refreshPausedFrame()
                }
                if again {
                    // Off this block: `nudgeVideoReconfig` reads properties
                    // through the handle lock this closure is still holding.
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.03) { [weak self] in
                        self?.nudgeVideoReconfig(reason: "deferred")
                    }
                }
            }
        }

        /// The layer size the view last applied, so the vo's own idea of
        /// its size (`osd-dimensions`) can be checked against it.
        private var lastDrawableSize: CGSize = .zero
        private var fullScreenObserver: NSObjectProtocol?
        private var reconfigAttemptsForSize = 0

        func drawableSizeChanged(to size: CGSize) {
            PlayerLog.write(String(format: "[nudge] drawable now %.0fx%.0f (was %.0fx%.0f)", size.width, size.height, lastDrawableSize.width, lastDrawableSize.height))
            lastDrawableSize = size
            reconfigAttemptsForSize = 0
            nudgeVideoReconfig(reason: "drawable changed")
            // And once more after the size has held still. A nudge only
            // reconfigures when a frame next passes through mpv's filters,
            // and `verifyVideoSizeIfDue` cannot catch a nudge that did
            // nothing: `osd-dimensions` already read the new size on the
            // restore that worked ("osd/w 2500" before its nudge) and on the
            // one that did not, so the check matched while the swapchain
            // stayed small.
            settleNudge?.cancel()
            let settle = DispatchWorkItem { [weak self] in self?.nudgeVideoReconfig(reason: "drawable settled") }
            settleNudge = settle
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: settle)
        }

        private var settleNudge: DispatchWorkItem?

        /// A fullscreen transition just ended. Whatever the debounced layout
        /// path did or did not deliver during the animation, this is the one
        /// moment the layer is certainly at its final size: re-read it,
        /// then check mpv against it twice, once now and once after the
        /// stream has had a second to configure. Belt and braces for the
        /// case the report kept showing: the windowed-size picture in the
        /// top-left of a fullscreen window.
        #if os(macOS)
        @MainActor
        func fullScreenTransitionEnded(view: MpvHostView) {
            view.metalView?.syncDrawableSize()
            let layer = view.metalView?.metalLayer
            let size = layer?.drawableSize ?? .zero
            if size.width > 1 { lastDrawableSize = size }
            reconfigAttemptsForSize = 0
            nudgeVideoReconfig(reason: "fullscreen ended")
            for delay in [0.3, 1.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak layer] in
                    guard let self else { return }
                    MainActor.assumeIsolated {
                        if let current = layer?.drawableSize, current.width > 1 { self.lastDrawableSize = current }
                    }
                    self.verifyVideoSizeIfDue(force: true)
                }
            }
        }
        #endif

        /// Runs on the event-loop thread after a file loads and on its idle
        /// tick: if mpv still reports the old size, nudge again. The first
        /// nudge from the size change can land while the file is still
        /// loading (a cached episode resolves in under a second, inside the
        /// fullscreen transition) and the configure that follows reads a
        /// stale size; the screenshot that motivated this showed a windowed
        /// 1280x820 picture in the top-left of a 1512x982 fullscreen window.
        private var lastSizeCheckAt: CFAbsoluteTime = 0
        func verifyVideoSizeIfDue(force: Bool = false) {
            let now = CFAbsoluteTimeGetCurrent()
            guard force || now - lastSizeCheckAt >= 0.5 else { return }
            lastSizeCheckAt = now
            let wanted = lastDrawableSize
            if force {
                // Before any guard: a forced check that logs nothing when a
                // guard fails is what left the owner's report empty.
                let osdW = stringProperty("osd-dimensions/w") ?? "-", osdH = stringProperty("osd-dimensions/h") ?? "-"
                PlayerLog.write(String(format: "[libmpv] forced size check: osd %@x%@ layer %.0fx%.0f attempts %d", osdW, osdH, wanted.width, wanted.height, reconfigAttemptsForSize))
            }
            guard wanted.width > 1, reconfigAttemptsForSize < 3,
                  let w = stringProperty("osd-dimensions/w").flatMap(Double.init),
                  let h = stringProperty("osd-dimensions/h").flatMap(Double.init),
                  w > 0, h > 0 else { return }
            if DebugHooks.env("ANICAT_PLAYER_DEBUG") != nil || force {
                // Forced checks are rare (file load, fullscreen change), so
                // they always log: the line is what a report needs and the
                // owner cannot be asked to relaunch from a terminal for it.
                let dw = stringProperty("dwidth") ?? "-", dh = stringProperty("dheight") ?? "-"
                let mt = stringProperty("osd-dimensions/mt") ?? "-", mb = stringProperty("osd-dimensions/mb") ?? "-"
                let ml = stringProperty("osd-dimensions/ml") ?? "-", mr = stringProperty("osd-dimensions/mr") ?? "-"
                let aspect = stringProperty("video-aspect-override") ?? "-"
                PlayerLog.write(String(format: "[libmpv] size check: osd %.0fx%.0f margins t%@ b%@ l%@ r%@ dwidth/dheight %@x%@ aspect-override %@ layer %.0fx%.0f", w, h, mt, mb, ml, mr, dw, dh, aspect, wanted.width, wanted.height))
            }
            if abs(w - wanted.width) > 1 || abs(h - wanted.height) > 1 {
                // Counted only when a detour went out. A check that lands
                // while one is still held only defers, and counting those is
                // how the paused fullscreen restore ran out of attempts with
                // the vo still at 640x360 in a 3024x1898 layer.
                guard nudgeVideoReconfig(reason: force ? "forced size check" : "idle size check") else { return }
                reconfigAttemptsForSize += 1
                PlayerLog.write(String(format: "[libmpv] vo is %.0fx%.0f, layer is %.0fx%.0f; forcing a reconfig (%d)", w, h, wanted.width, wanted.height, reconfigAttemptsForSize))
            }
        }

        func runCommand(_ args: [String]) {
            guard let mpv = mpv else { return }
            var cArgs = args.map { UnsafePointer<CChar>?(strdup($0)) }
            cArgs.append(nil)
            defer {
                for arg in cArgs {
                    if let a = arg { free(UnsafeMutableRawPointer(mutating: a)) }
                }
            }
            cArgs.withUnsafeMutableBufferPointer { ptr in
                let res = mpv_command(mpv, ptr.baseAddress)
                if res < 0 {
                    let errStr = String(cString: mpv_error_string(res))
                    print("[libmpv] mpv_command(\(args.joined(separator: " "))) error: \(errStr) (\(res))")
                }
            }
        }

        @MainActor
        func loadFile(url: String) {
            // Not the place to touch `awaitingNewFile`: `updateNSView` calls
            // this on every SwiftUI update, so during a resolve it arrives
            // repeatedly with the *outgoing* file's URL, and clearing the
            // gate here let the old file's ticks through (and started the
            // next episode at the previous one's position).
            guard url != lastLoadedURL else { return }
            pendingStreamURL = url
            guard let mpv = mpv else { return }
            lastLoadedURL = url
            // Below the guard above, never over it: `updateNSView` calls
            // this on every SwiftUI update with the URL already playing,
            // and clearing there would drop the viewer's subtitle pick on
            // the next unrelated redraw.
            explicitSubtitleTrackId = nil
            didApplyTrackMemory = false
            // paused-for-cache stays false until mpv has actually started
            // decoding, so the initial "resolving the first frame" stretch
            // has no property to key off — set it optimistically here and
            // let the first time-pos update (proof a frame decoded) clear it.
            controller.isBuffering = true
            controller.bufferingPercent = nil
            // The outgoing file's cache map drawn over the new file's
            // timeline is the wrong bar for a beat; both sources refill.
            controller.mpvBufferedRanges = []
            controller.torrentBufferedFractions = []
            if controller.currentTime > 0 {
                let startSec = String(format: "%.2f", controller.currentTime)
                mpv_set_property_string(mpv, "start", startSec)
            } else {
                mpv_set_property_string(mpv, "start", "none")
            }
            // Re-read per file, not only at mpv creation: the preference can
            // change (Settings, the detail page, the player's own Sub/Dub
            // row) while one long-lived mpv instance plays a whole binge
            // through `loadfile ... replace`, and `alang` is consumed at
            // load time.
            mpv_set_property_string(mpv, "alang", Coordinator.audioLanguages(preferDub: Coordinator.preferDubSetting()))
            runCommand(["loadfile", url, "replace"])
            print("[libmpv] Playing stream: \(url)")
        }

        func clearLoadedURL() {
            lastLoadedURL = nil
            pendingStreamURL = nil
        }

        func setPaused(_ paused: Bool) {
            guard let mpv = mpv else { return }
            var flag: Int32 = paused ? 1 : 0
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        }

        func seek(to seconds: Double) {
            runCommand(["seek", String(format: "%.2f", seconds), "absolute"])
        }

        func setVolume(_ volume: Double) {
            guard let mpv = mpv else { return }
            var value = volume * 100
            mpv_set_property(mpv, "volume", MPV_FORMAT_DOUBLE, &value)
        }

        func setMuted(_ muted: Bool) {
            guard let mpv = mpv else { return }
            var flag: Int32 = muted ? 1 : 0
            mpv_set_property(mpv, "mute", MPV_FORMAT_FLAG, &flag)
        }

        func setSpeed(_ rate: Double) {
            guard let mpv = mpv else { return }
            var value = rate
            mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &value)
        }

        /// `sub-scale`, which mpv applies to ASS as well under the default
        /// `sub-ass-override=yes`. Scale only, no colour or border: those
        /// need `force`, which throws away the release's typesetting.
        func setSubtitleScale(_ scale: Double) {
            guard let mpv = mpv else { return }
            var value = scale
            mpv_set_property(mpv, "sub-scale", MPV_FORMAT_DOUBLE, &value)
        }

        /// ASS places dialogue against the video, and filled, the video runs
        /// past the screen: the bottom line was cut in half on the 17 Pro.
        /// `sub-ass-use-margins` does not help, because mpv clamps the
        /// overhang to zero before libass sees it. So the dialogue styles'
        /// `MarginV` is raised by the crop instead; signs with their own
        /// position still crop with the picture, as in the system player.
        func setFillScreen(_ fill: Bool, crop: Double) {
            guard let mpv = mpv else { return }
            var value: Double = fill ? 1 : 0
            mpv_set_property(mpv, "panscan", MPV_FORMAT_DOUBLE, &value)
            fillCrop = crop
            setSubtitleStyle(SubtitleStyle.current)
        }

        /// ASS releases through named-style overrides, text subtitles through
        /// the `sub-*` options; `SubtitleStyle` says why not `force`. A
        /// failed set (an option this libmpv does not know) is ignored: the
        /// rest of the look still applies, and a subtitle is not worth an
        /// error in the middle of an episode.
        func setSubtitleStyle(_ style: SubtitleStyle) {
            guard let mpv = mpv else { return }
            mpv_set_property_string(mpv, "sub-ass-style-overrides", style.assOverrides(playResY: scriptHeight, liftingBy: fillCrop))
            for (name, value) in style.textOptions {
                mpv_set_property_string(mpv, name, value)
            }
        }

        /// Cycles off / 90 CW / 90 CCW, same three states and same reasoning
        /// as the Lua script's `toggle_sideways` in the Tauri build: `vf`
        /// with the `sub` filter ahead of `lavfi=[transpose=...]` bakes
        /// subtitles into the frame before the rotation (so they turn with
        /// the picture) rather than leaving them on the unrotated OSD like a
        /// bare `--video-rotate` would. Hardware decode is turned off first
        /// — with videotoolbox frames the `sub` filter silently renders
        /// nothing and lavfi fails to configure at all ("Impossible to
        /// convert between the formats"), verified against mpv/macOS in the
        /// Tauri build — and restored once back to the off state.
        @MainActor
        func cycleSideways() {
            guard let mpv = mpv else { return }
            let next = (controller.sidewaysState + 1) % 3
            controller.sidewaysState = next

            if next == 1 && sidewaysSavedHwdec == nil {
                if let cstr = mpv_get_property_string(mpv, "hwdec") {
                    sidewaysSavedHwdec = String(cString: cstr)
                    mpv_free(cstr)
                }
                mpv_set_option_string(mpv, "hwdec", "no")
            }

            switch next {
            case 0:
                runCommand(["vf", "clr", ""])
                if let saved = sidewaysSavedHwdec {
                    mpv_set_option_string(mpv, "hwdec", saved)
                    sidewaysSavedHwdec = nil
                }
            case 1:
                runCommand(["vf", "set", "sub,lavfi=[transpose=clock]"])
            default:
                runCommand(["vf", "set", "sub,lavfi=[transpose=cclock]"])
            }
        }

        @MainActor
        func applyAnime4K(enabled: Bool) {
            #if !os(macOS)
            // iOS does not upscale, by decision: the shader chain is tuned
            // for a MacBook's thermals and the setting is not offered there,
            // so nothing on iOS ever sends `glsl-shaders`.
            _ = enabled
            #else
            // The toggle is the user's wish; anime-only is the file's say.
            // Compared after both so a film following an episode clears the
            // chain even though the toggle never moved.
            let wanted = enabled && !controller.isLiveAction
            guard let mpv = mpv, wanted != lastAnime4KState else { return }
            lastAnime4KState = wanted

            let shaderString: String
            if wanted {
                shaderString = Anime4KPreset.on.resolveMpvShaderString()
            } else {
                shaderString = ""
            }

            mpv_set_property_string(mpv, "glsl-shaders", shaderString)
            if shaderString.isEmpty {
                print(enabled ? "[libmpv] Anime4K off: live action" : "[libmpv] Anime4K disabled")
            } else {
                print("[libmpv] Applied Anime4K 6-shader pipeline")
            }
            #endif
        }

        // Backward compatibility overload
        @MainActor
        func applyAnime4K(preset: Anime4KPreset) {
            applyAnime4K(enabled: preset != .off)
        }

        /// Selects the loaded file's audio track whose language matches the
        /// Sub/Dub choice, and the subtitle track that goes with it. Walks
        /// `track-list/N/...` sub-properties rather than parsing the whole
        /// MPV_FORMAT_NODE list, same reason as `trackList` below. A file
        /// with no track in the wanted language is left alone — a
        /// single-audio sub release has nothing to switch to, and forcing
        /// `aid` there would only mute it. Returns whether a matching audio
        /// track was found, so the caller can say so instead of reporting a
        /// switch that did not happen.
        @discardableResult
        func selectAudioLanguage(preferDub: Bool) -> Bool {
            guard let mpv else { return false }
            defer { applySubtitlePreference(preferDub: preferDub) }
            // Re-applied on the next file too: `alang` is a load-time option,
            // so setting it here is what makes the choice stick across an
            // auto-next transition within the same mpv instance.
            mpv_set_property_string(mpv, "alang", Coordinator.audioLanguages(preferDub: preferDub))
            guard let countString = stringProperty("track-list/count"),
                  let count = Int(countString) else { return false }
            let wanted = preferDub ? ["en", "eng", "english"] : ["ja", "jp", "jpn", "japanese"]
            // Says what the release actually carries: "dub doesn't work" is
            // two different bugs depending on whether the file has a second
            // audio track at all, and nothing else in the app prints it.
            let audioTracks = (0..<count)
                .filter { stringProperty("track-list/\($0)/type") == "audio" }
                .map { "\(stringProperty("track-list/\($0)/id") ?? "?"):\(stringProperty("track-list/\($0)/lang") ?? "-")/\(stringProperty("track-list/\($0)/title") ?? "-")" }
            print("[libmpv] audio tracks: \(audioTracks.joined(separator: ", "))")
            for index in 0..<count {
                guard stringProperty("track-list/\(index)/type") == "audio" else { continue }
                let lang = (stringProperty("track-list/\(index)/lang") ?? "").lowercased()
                let title = (stringProperty("track-list/\(index)/title") ?? "").lowercased()
                let matches = wanted.contains(lang)
                    || wanted.contains(where: { title.contains($0) })
                    // A dub-only release often labels neither, so the
                    // English word in the title is the only signal left.
                    || (preferDub && title.contains("dub"))
                guard matches, let id = stringProperty("track-list/\(index)/id") else { continue }
                mpv_set_property_string(mpv, "aid", id)
                return true
            }
            return false
        }

        /// Puts `sid` where the new audio language wants it: a full English
        /// track for Sub, a signs-and-songs one for Dub, and whatever the
        /// viewer picked from the subtitle list over both.
        ///
        /// Nothing on this path used to write `sid`, so the track mpv chose
        /// when the file loaded was the track the viewer kept for the rest
        /// of the episode however many times the audio changed under it —
        /// which is how a Sub, Dub, Sub round trip ended up on the signs
        /// track the dub had been given.
        private func applySubtitlePreference(preferDub: Bool) {
            guard let mpv else { return }
            let subtitles = trackList().subtitle
            guard let wanted = PlayerTrack.preferredSubtitle(
                preferDub: preferDub,
                tracks: subtitles,
                explicit: explicitSubtitleTrackId
            ) else { return }
            // Written even when the list says that track is already
            // selected: this runs microseconds after the `aid` write above,
            // and mpv's track reconfig has not finished by the time
            // `mpv_set_property` returns, so those flags are the ones from
            // before the audio switch. Setting `sid` to the track already
            // showing costs nothing; trusting a stale flag costs the pick.
            mpv_set_property_string(mpv, "sid", wanted)
        }

        /// Puts back the audio and subtitle languages this title was last
        /// watched with, over whatever mpv's own load-time `alang` selection
        /// landed on. Runs once per file and only for a title that has a
        /// remembered pick, so a title with no memory is still governed by
        /// the global Sub/Dub choice exactly as before.
        ///
        /// Called from the event loop's own thread, which is the one thread
        /// allowed to make the blocking property reads `trackList` is built
        /// out of.
        func applyTrackMemory(_ memory: PlayerController.TrackMemory?) {
            guard mpv != nil, let memory, !didApplyTrackMemory else { return }
            didApplyTrackMemory = true
            let tracks = trackList()
            if let lang = memory.audioLang,
               let match = Self.matchTrack(in: tracks.audio, lang: lang, title: nil) {
                selectAudioTrack(id: match.id)
            }
            if let lang = memory.subtitleLang,
               let match = Self.matchTrack(in: tracks.subtitle, lang: lang, title: memory.subtitleTitle) {
                // Through `selectSubtitleTrack`, so the remembered id lands
                // in `explicitSubtitleTrackId` too: a remembered pick is a
                // pick made by hand, one episode earlier, and without that a
                // Sub/Dub toggle later in this file would run the language
                // rule straight over the top of it.
                selectSubtitleTrack(id: match.id)
            }
        }

        /// The track a remembered language names. The stored title decides
        /// between two tracks of one language and is only ever a tiebreak —
        /// a release that dropped the "Full Subtitles" track still gets its
        /// English one rather than nothing.
        static func matchTrack(in tracks: [PlayerTrack], lang: String, title: String?) -> PlayerTrack? {
            let sameLanguage = tracks.filter {
                ($0.lang ?? "").caseInsensitiveCompare(lang) == .orderedSame
            }
            if let title,
               let named = sameLanguage.first(where: {
                   ($0.title ?? "").caseInsensitiveCompare(title) == .orderedSame
               }) {
                return named
            }
            return sameLanguage.first
        }

        /// The Sub/Dub preference, in the one vocabulary `anicat_sub_dub` is
        /// stored in by both Settings and the detail page's AUDIO toggle.
        static func preferDubSetting() -> Bool {
            UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        }

        static func audioLanguages(preferDub: Bool) -> String {
            preferDub ? "en,eng,English" : "ja,jpn,Japanese,en,eng,English"
        }

        /// The loaded file's audio and subtitle tracks, for the info
        /// popover's pickers. Walks `track-list/N/...` sub-properties for
        /// the same reason `selectAudioLanguage` does: reading them one
        /// string at a time needs no MPV_FORMAT_NODE parsing, and the
        /// alternative would be the only place in this file that does.
        func trackList() -> (audio: [PlayerTrack], subtitle: [PlayerTrack]) {
            guard let countString = stringProperty("track-list/count"),
                  let count = Int(countString) else { return (audio: [], subtitle: []) }
            var audio: [PlayerTrack] = []
            var subtitle: [PlayerTrack] = []
            for index in 0..<count {
                guard let type = stringProperty("track-list/\(index)/type"),
                      type == "audio" || type == "sub",
                      let id = stringProperty("track-list/\(index)/id") else { continue }
                let track = PlayerTrack(
                    id: id,
                    lang: stringProperty("track-list/\(index)/lang"),
                    title: stringProperty("track-list/\(index)/title"),
                    isSelected: stringProperty("track-list/\(index)/selected") == "yes",
                    isForced: stringProperty("track-list/\(index)/forced") == "yes"
                )
                if type == "audio" { audio.append(track) } else { subtitle.append(track) }
            }
            return (audio: audio, subtitle: subtitle)
        }

        func selectAudioTrack(id: String) {
            guard let mpv else { return }
            mpv_set_property_string(mpv, "aid", id)
        }

        /// `vid=no` stops the decoder and the vo without touching the audio
        /// pipeline; `auto` picks the file's default video track back up.
        /// Off the main thread like the track walks: `vid` on a 1080p
        /// H.264 stream blocks for the decoder teardown, and this is called
        /// from the background transition where the main thread has a few
        /// seconds before iOS snapshots and suspends.
        func setVideoEnabled(_ enabled: Bool) {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                _ = self?.withHandle { mpv in
                    mpv_set_property_string(mpv, "vid", enabled ? "auto" : "no")
                }
            }
        }

        /// `nil` is the Off row. The id is remembered so a later Sub/Dub
        /// toggle re-applies it instead of overruling a choice the viewer
        /// made by hand — see `PlayerTrack.preferredSubtitle`.
        func selectSubtitleTrack(id: String?) {
            guard let mpv else { return }
            let value = id ?? PlayerTrack.off
            explicitSubtitleTrackId = value
            mpv_set_property_string(mpv, "sid", value)
        }

        /// One mpv string property, or `nil` when it is unset — mpv returns
        /// an empty string for a track with no language tag, and every
        /// caller here wants that to read as "absent".
        /// When `demuxer-cache-state` was last read back; see the observer.
        var lastCacheStateRead: CFTimeInterval = 0
        /// When `paused-for-cache` last went true, nil while playing.
        var cacheStallBegan: CFTimeInterval?
        /// The last `[decoder]` line written; see the `hwdec-current` event.
        var lastDecoderLine: String?
        /// The current ASS track's script height (PlayResY), which a
        /// subtitle style's sizes and widths are scaled into. Written from
        /// the event loop, read from the main actor's style callback.
        private let scriptHeightLock = NSLock()
        private var _scriptHeight: Double = 360
        var scriptHeight: Double {
            get { scriptHeightLock.lock(); defer { scriptHeightLock.unlock() }; return _scriptHeight }
            set { scriptHeightLock.lock(); _scriptHeight = newValue; scriptHeightLock.unlock() }
        }
        /// Read by `setSubtitleStyle`, which the event loop calls off the main
        /// thread when a new file's script height arrives.
        private var _fillCrop: Double = 0
        var fillCrop: Double {
            get { scriptHeightLock.lock(); defer { scriptHeightLock.unlock() }; return _fillCrop }
            set { scriptHeightLock.lock(); _fillCrop = newValue; scriptHeightLock.unlock() }
        }

        /// mpv's `demuxer-cache-state/seekable-ranges` as spans in seconds.
        func cachedSeekableRanges() -> [BufferedSpan] {
            guard let countString = stringProperty("demuxer-cache-state/seekable-ranges/count"),
                  let count = Int(countString), count > 0 else { return [] }
            return (0..<count).compactMap { index in
                guard let start = stringProperty("demuxer-cache-state/seekable-ranges/\(index)/start").flatMap(Double.init),
                      let end = stringProperty("demuxer-cache-state/seekable-ranges/\(index)/end").flatMap(Double.init),
                      end > start else { return nil }
                return BufferedSpan(start: start, end: end)
            }
        }

        /// What mpv itself knows about the stream, as panel rows. Called
        /// inside `withHandle`, off the main thread.
        func streamDetailRows() -> [StreamDetailRow] {
            func prop(_ name: String) -> String? { stringProperty(name) }
            var rows: [StreamDetailRow] = []
            let codec = prop("video-codec") ?? prop("video-format")
            let w = prop("video-params/w"), h = prop("video-params/h")
            let size = (w != nil && h != nil) ? "\(w!)x\(h!)" : nil
            let fps = prop("container-fps").flatMap(Double.init).map { String(format: "%.3f fps", $0) }
            rows.append(StreamDetailRow("Video", [codec, size, fps].compactMap { $0 }.joined(separator: ", ")))
            if let out = prop("video-out-params/dw"), let outH = prop("video-out-params/dh") {
                rows.append(StreamDetailRow("Displayed", "\(out)x\(outH)"))
            }
            rows.append(StreamDetailRow("Decoder", prop("hwdec-current").map { $0 == "no" ? "software" : $0 } ?? "software"))
            if let pix = prop("video-params/pixelformat") {
                rows.append(StreamDetailRow("Pixel format", [pix, prop("video-params/colormatrix"), prop("video-params/primaries")].compactMap { $0 }.joined(separator: ", ")))
            }
            let audio = [prop("audio-codec-name"), prop("audio-params/hr-channels"), prop("audio-params/samplerate").map { "\($0) Hz" }]
                .compactMap { $0 }.joined(separator: ", ")
            if !audio.isEmpty { rows.append(StreamDetailRow("Audio", audio)) }
            let vbr = prop("video-bitrate").flatMap(Double.init).map { String(format: "%.1f Mbps video", $0 / 1_000_000) }
            let abr = prop("audio-bitrate").flatMap(Double.init).map { String(format: "%.0f kbps audio", $0 / 1000) }
            let bitrate = [vbr, abr].compactMap { $0 }.joined(separator: ", ")
            if !bitrate.isEmpty { rows.append(StreamDetailRow("Bitrate", bitrate)) }
            if let cached = prop("demuxer-cache-duration").flatMap(Double.init) {
                rows.append(StreamDetailRow("Read ahead", String(format: "%.1fs", cached)))
            }
            let drops = [prop("frame-drop-count").map { "\($0) vo" }, prop("decoder-frame-drop-count").map { "\($0) decoder" }]
                .compactMap { $0 }.joined(separator: ", ")
            if !drops.isEmpty { rows.append(StreamDetailRow("Dropped frames", drops)) }
            if let vf = prop("vf"), !vf.isEmpty { rows.append(StreamDetailRow("Filters", vf)) }
            if let shaders = prop("glsl-shaders"), !shaders.isEmpty {
                let count = shaders.split(separator: ":").count
                rows.append(StreamDetailRow("Shaders", "\(count) loaded"))
            }
            rows.append(StreamDetailRow("Container", [prop("file-format"), prop("file-size").flatMap(Double.init).map { String(format: "%.0f MB", $0 / 1_048_576) }].compactMap { $0 }.joined(separator: ", ")))
            rows.append(StreamDetailRow("Source", prop("path") ?? "none"))
            return rows
        }

        func stringProperty(_ name: String) -> String? {
            guard let mpv else { return nil }
            guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
            defer { mpv_free(cstr) }
            let value = String(cString: cstr)
            return value.isEmpty ? nil : value
        }

        /// Samples a frame if one is due and it is a sane moment to ask for
        /// one, and publishes the result. Nothing is asked of mpv during a
        /// resolve or a cache stall: `screenshot-raw` blocks on a core that
        /// is itself waiting on the swarm, which is the one situation where a
        /// slow screenshot would be the player's own fault.
        /// True once the drawable-side sampler is installed; the
        /// `screenshot-raw` path below then stays idle and only serves the
        /// iOS Simulator, whose drawables have no presented handler.
        nonisolated(unsafe) var usesMetalAmbientSampler = false

        func sampleAmbientIfDue() async {
            guard !usesMetalAmbientSampler else { return }
            // Checked before the main-actor hop below, not after: this runs
            // on every 50ms idle tick, and hopping twenty times a second to
            // read three booleans that matter once a second is the whole
            // cost of the feature in the steady state.
            guard ambientGate.isDue(at: CFAbsoluteTimeGetCurrent()) else { return }
            let ready = await MainActor.run {
                !self.controller.awaitingNewFile && !self.controller.isBuffering && self.controller.isPlaying
            }
            guard ready, let frame = sampleAmbientFrame() else {
                if ambientGate.gaveUp {
                    await MainActor.run { self.controller.ambientSamplingStopped() }
                }
                return
            }
            // Same bar detection the Metal sampler does, so the escape
            // hatch does not quietly lose the encoded-letterbox case that
            // `AmbientContentInset` exists for.
            let inset = AmbientGlow.centredBars(AmbientGlow.contentInset(of: frame) ?? .zero)
            let crop = inset.apply(to: CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            let cropped = crop.width >= 1 && crop.height >= 1 ? (frame.cropping(to: crop) ?? frame) : frame
            await MainActor.run {
                self.controller.setAmbientFrame(cropped, inset: inset)
            }
        }

        /// The interval, the 15ms budget and the give-up rule. See
        /// `AmbientSampleGate`.
        private var ambientGate = AmbientSampleGate()
        /// How many samples have had their cost printed. The timing line is
        /// the only way to see what this feature costs on a given machine,
        /// and printing it once a second for a 24-minute episode would bury
        /// every other line in the log.
        private var ambientSamplesLogged = 0
        private static let ambientSamplesToLog = 3

        /// One `screenshot-raw` downscaled to a thumbnail, or nil when it is
        /// not due, not possible, or has been given up on.
        ///
        /// Called from the event loop rather than from a timer of its own.
        /// `stop()` blocks on `eventLoopStopped` before it frees anything,
        /// precisely because a second thread touching `mpv` at the same
        /// moment was a crash; a sampling queue would be exactly that second
        /// thread, and nothing in `stop()` waits for one.
        func sampleAmbientFrame() -> CGImage? {
            guard let mpv else { return nil }
            let now = CFAbsoluteTimeGetCurrent()
            guard ambientGate.isDue(at: now) else { return nil }
            ambientGate.begin(at: now)
            guard UserDefaults.standard.object(forKey: "anicat_ambient_glow") as? Bool ?? true else { return nil }

            var result = mpv_node()
            var status: Int32 = -1
            "screenshot-raw".withCString { command in
                "video".withCString { flags in
                    // Built by zero-init and member assignment rather than
                    // through the imported union's initialiser: the name
                    // Swift generates for an anonymous C union is not
                    // something to pin a build to.
                    var values = [mpv_node(), mpv_node()]
                    values[0].format = MPV_FORMAT_STRING
                    values[0].u.string = UnsafeMutablePointer(mutating: command)
                    values[1].format = MPV_FORMAT_STRING
                    values[1].u.string = UnsafeMutablePointer(mutating: flags)
                    values.withUnsafeMutableBufferPointer { buffer in
                        var list = mpv_node_list()
                        list.num = 2
                        list.values = buffer.baseAddress
                        withUnsafeMutablePointer(to: &list) { listPointer in
                            var args = mpv_node()
                            args.format = MPV_FORMAT_NODE_ARRAY
                            args.u.list = listPointer
                            status = mpv_command_node(mpv, &args, &result)
                        }
                    }
                }
            }
            guard status >= 0 else {
                // "video" is refused by a build without the screenshot code,
                // and by an audio-only file. Neither is worth retrying every
                // second for the rest of the episode.
                PlayerLog.write("[glow] screenshot-raw unavailable (\(status)); falling back to the episode still")
                ambientGate.giveUp()
                return nil
            }
            defer { mpv_free_node_contents(&result) }
            let captured = CFAbsoluteTimeGetCurrent()
            let frame = Self.thumbnail(fromScreenshot: result)
            let finished = CFAbsoluteTimeGetCurrent()
            let elapsed = finished - now
            if ambientSamplesLogged < Self.ambientSamplesToLog {
                ambientSamplesLogged += 1
                PlayerLog.write(String(format: "[glow] screenshot-raw %.1fms + downscale %.1fms = %.1fms",
                                       (captured - now) * 1000, (finished - captured) * 1000, elapsed * 1000))
            }
            if elapsed > AmbientSampleGate.budget {
                PlayerLog.write(String(format: "[glow] sample took %.1fms (over budget %d/%d in a row)",
                                       elapsed * 1000, ambientGate.slowStreak + 1, AmbientSampleGate.slowSampleLimit))
            }
            let before = ambientGate.currentInterval
            ambientGate.record(elapsed: elapsed)
            if ambientGate.currentInterval != before {
                PlayerLog.write(String(format: "[glow] sampling every %.0fms now", ambientGate.currentInterval * 1000))
            }
            return frame
        }

        /// Walks the map `screenshot-raw` answers with (`w`, `h`, `stride`,
        /// `format`, `data`) down to a thumbnail.
        private static func thumbnail(fromScreenshot node: mpv_node) -> CGImage? {
            guard node.format == MPV_FORMAT_NODE_MAP, let list = node.u.list else { return nil }
            var width = 0, height = 0, stride = 0
            var order: AmbientGlow.PixelOrder?
            var data: UnsafeMutableRawPointer?
            var size = 0
            for index in 0..<Int(list.pointee.num) {
                guard let keyPointer = list.pointee.keys?[index],
                      let value = list.pointee.values?[index] else { continue }
                switch String(cString: keyPointer) {
                case "w": width = Int(value.u.int64)
                case "h": height = Int(value.u.int64)
                case "stride": stride = Int(value.u.int64)
                case "format":
                    order = value.u.string.map { AmbientGlow.PixelOrder.named(String(cString: $0)) } ?? nil
                case "data":
                    if let bytes = value.u.ba {
                        data = bytes.pointee.data
                        size = bytes.pointee.size
                    }
                default: continue
                }
            }
            guard let order, let data, size >= stride * height else { return nil }
            return AmbientGlow.thumbnail(
                bytes: data, width: width, height: height, stride: stride, order: order
            )
        }

        /// mpv's `chapter-list` for the loaded file, read through the string
        /// property form rather than `MPV_FORMAT_NODE`: the node form hands
        /// back a map that has to be walked and freed with
        /// `mpv_free_node_contents`, for a list this file already has a
        /// two-line idiom for reading (see `trackList`).
        func readChapters() -> [PlayerChapter] {
            guard let countString = stringProperty("chapter-list/count"),
                  let count = Int(countString), count > 0 else { return [] }
            var chapters: [PlayerChapter] = []
            // Two blocking property reads each. A sane release has a handful
            // of chapters; the cap is only so a malformed file cannot hold
            // the event loop for the length of its list.
            chapters.reserveCapacity(min(count, 500))
            for index in 0..<min(count, 500) {
                guard let timeString = stringProperty("chapter-list/\(index)/time"),
                      let time = Double(timeString) else { continue }
                chapters.append(PlayerChapter(
                    title: stringProperty("chapter-list/\(index)/title") ?? "",
                    time: time
                ))
            }
            return chapters
        }

        private func startEventLoop() {
            guard let mpv = mpv else { return }
            let eventLoopStopped = eventLoopStopped

            Task.detached(priority: .userInitiated) { [weak self, mpv] in
                while true {
                    let event = mpv_wait_event(mpv, 0.05)
                    guard let ev = event?.pointee else { continue }

                    if ev.event_id == MPV_EVENT_SHUTDOWN {
                        break
                    }
                    // Every iteration, not only the timeout branch below:
                    // during playback the property observers deliver an
                    // event many times a second, so the 50 ms timeout almost
                    // never fires and a sampler that rode it alone managed
                    // two samples in 25 s of playback while the bars sat on
                    // the episode still. Both calls are gated by their own
                    // intervals, so this costs a comparison per event.
                    if ev.event_id != MPV_EVENT_NONE, let self, self.isRunning {
                        await self.sampleAmbientIfDue()
                        self.verifyVideoSizeIfDue()
                    }
                    if ev.event_id == MPV_EVENT_NONE {
                        guard let self = self, self.isRunning else {
                            break
                        }
                        // The 50ms idle tick is where the ambient glow's
                        // frame sampling rides: no timer, no second thread on
                        // the handle, and `sampleAmbientFrame` does nothing
                        // until a second has passed.
                        await self.sampleAmbientIfDue()
                        self.verifyVideoSizeIfDue()
                        continue
                    }
                    guard let self = self, self.isRunning else {
                        break
                    }

                    if ev.event_id == MPV_EVENT_LOG_MESSAGE, let data = ev.data {
                        let msg = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
                        if let prefix = msg.prefix.map({ String(cString: $0) }), prefix.hasPrefix("ao"),
                           let text = msg.text.map({ String(cString: $0) }) {
                            PlayerLog.write("[mpv/\(prefix)] \(text.trimmingCharacters(in: .newlines))")
                        }
                        continue
                    }
                    if ev.event_id == MPV_EVENT_AUDIO_RECONFIG {
                        PlayerLog.write("[libmpv] audio reconfig: ao \(self.stringProperty("current-ao") ?? "-") device \(self.stringProperty("audio-device") ?? "-") time-pos \(self.stringProperty("time-pos") ?? "-")")
                    }
                    if ev.event_id == MPV_EVENT_VIDEO_RECONFIG {
                        PlayerLog.write(String(format: "[libmpv] video reconfig: out %@x%@ osd %@x%@ time-pos %@", self.stringProperty("video-out-params/dw") ?? "-", self.stringProperty("video-out-params/dh") ?? "-", self.stringProperty("osd-dimensions/w") ?? "-", self.stringProperty("osd-dimensions/h") ?? "-", self.stringProperty("time-pos") ?? "-"))
                        // Read here as well as from the property observer.
                        // `resolveAndPlay` clears the displayed size for every
                        // episode, and mpv only reports `video-out-params`
                        // when the value changes: a sideways episode after a
                        // sideways episode came out 1080x1920 both times, no
                        // report arrived, and the chrome fell back to the
                        // decoder's unrotated 16:9 and laid its opaque bars
                        // over the top and bottom of the turned picture.
                        let w = self.stringProperty("video-out-params/dw").flatMap(Double.init) ?? 0
                        let h = self.stringProperty("video-out-params/dh").flatMap(Double.init) ?? 0
                        if w > 0, h > 0 {
                            await MainActor.run {
                                guard self.controller.videoDisplayWidth != w || self.controller.videoDisplayHeight != h else { return }
                                self.controller.videoDisplayWidth = w
                                self.controller.videoDisplayHeight = h
                            }
                        }
                        continue
                    }

                    if ev.event_id == MPV_EVENT_END_FILE, let data = ev.data {
                        let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
                        PlayerLog.write("[libmpv] end-file reason \(end.reason.rawValue) error \(end.error) time-pos \(self.stringProperty("time-pos") ?? "-")")
                        // Never observed before: a URL mpv could not open
                        // (a range server that answered 404, an
                        // undecodable container) ended in no file-loaded
                        // and no error, so `awaitingNewFile` held the
                        // spinner until the opening watchdog's 20s window
                        // or the viewer closed the player.
                        if end.reason == MPV_END_FILE_REASON_ERROR {
                            let text = String(cString: mpv_error_string(end.error))
                            await MainActor.run {
                                self.controller.awaitingNewFile = false
                                self.controller.reportPlaybackFailure("Could not play this stream: \(text).")
                            }
                        } else if end.reason == MPV_END_FILE_REASON_EOF {
                            // `keep-open` makes `eof-reached` the usual
                            // path; this is the fallback for a file mpv
                            // dropped instead of holding, and the report
                            // gate keeps the two from doubling up.
                            await MainActor.run {
                                guard !self.controller.awaitingNewFile else { return }
                                self.controller.handleEndOfFile()
                            }
                        }
                        continue
                    }

                    if ev.event_id == MPV_EVENT_FILE_LOADED {
                        self.reconfigAttemptsForSize = 0
                        self.verifyVideoSizeIfDue(force: true)
                        // Read here, on the event loop's own thread: these
                        // are blocking property reads that wait on mpv's core
                        // lock, and this is the one thread already allowed to
                        // do that (`trackList` is dispatched off main for the
                        // same reason, because main is what calls it).
                        let chapters = self.readChapters()
                        let duration = self.stringProperty("duration").flatMap(Double.init)
                        let memory = await MainActor.run {
                            self.controller.awaitingNewFile = false
                            self.controller.playbackFailureReported = false
                            self.controller.resetPlayedSpan()
                            // Unconditional, empty list included: a release
                            // without chapters must not inherit the previous
                            // episode's windows.
                            self.controller.setChapters(chapters, duration: duration)
                            return self.controller.titleTrackMemory
                        }
                        // Last writer of `aid`/`sid` for this file, after
                        // mpv's own load-time selection has settled.
                        self.applyTrackMemory(memory)
                        continue
                    }

                    if ev.event_id == MPV_EVENT_PROPERTY_CHANGE {
                        let prop = ev.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                        guard let name = prop.name.map({ String(cString: $0) }) else { continue }

                        // `awaitingNewFile` is read in the same main-actor
                        // hop as the write it gates. Read in a hop of its
                        // own, `resolveAndPlay` could set it between the
                        // two and the outgoing file's last tick was applied
                        // to the new episode anyway: the bug the gate exists
                        // for. See `PlayerController.awaitingNewFile`.
                        if name == "time-pos", let data = prop.data {
                            let pos = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run {
                                guard !self.controller.awaitingNewFile else { return }
                                self.controller.notePlayedPosition(pos)
                                if !self.controller.isScrubbing {
                                    // mpv reports time-pos on every video
                                    // frame and `currentTime` is observed:
                                    // written each time, the bottom bar (time
                                    // label, scrubber, and every button in
                                    // the same body) was rebuilt 24+ times a
                                    // second whenever the controls were up.
                                    // Visible controls cost 12.4 CPU points
                                    // (release, fullscreen, 47.3% up vs 34.9%
                                    // hidden, 2026-09-23), and a `sample`
                                    // put PlayerBottomBar.body at the top of
                                    // the app's own frames. A quarter second
                                    // is finer than the scrubber (about a
                                    // point a second) or the seconds label
                                    // can show, and a seek jumps further and
                                    // lands at once. The exact position still
                                    // goes to `onPositionChange` every time.
                                    if abs(pos - self.controller.currentTime) >= 0.25 {
                                        self.controller.currentTime = pos
                                    }
                                    self.controller.checkIntroStatus()
                                    self.controller.onPositionChange?(pos, self.controller.duration)
                                }
                                // Only on a change: this runs once per video
                                // frame, `@Observable` announces every write,
                                // and `PlayerView` reads it (see
                                // `PlayerController.checkIntroStatus`).
                                if self.controller.isBuffering {
                                    self.controller.isBuffering = false
                                }
                            }
                        } else if name == "eof-reached", let data = prop.data {
                            let reached = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            guard reached else { continue }
                            await MainActor.run {
                                guard !self.controller.awaitingNewFile else { return }
                                self.controller.handleEndOfFile()
                            }
                        } else if name == "paused-for-cache", let data = prop.data {
                            let buffering = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            // The property's own edges, not `isBuffering`,
                            // which every time-pos tick also clears. Nothing
                            // logged a stall before: "is there a buffering
                            // problem?" had only the engine's download rate
                            // to go on, never when or how long mpv waited.
                            let now = CACurrentMediaTime()
                            let at = self.stringProperty("time-pos") ?? "-"
                            if buffering, self.cacheStallBegan == nil {
                                self.cacheStallBegan = now
                                PlayerLog.write("[buffer] paused for cache at time-pos \(at)")
                            } else if !buffering, let began = self.cacheStallBegan {
                                self.cacheStallBegan = nil
                                PlayerLog.write(String(format: "[buffer] resumed after %.1fs at time-pos %@", now - began, at))
                            }
                            await MainActor.run {
                                self.controller.isBuffering = buffering
                            }
                        } else if name == "hwdec-current" {
                            // mpv announces this far more often than it
                            // changes (every decoder reinit, several a
                            // second around a seek), so only a different
                            // answer is written.
                            let decoder = self.stringProperty("hwdec-current") ?? "no"
                            let codec = self.stringProperty("video-codec") ?? "?"
                            let line = "\(decoder == "no" ? "software" : decoder) (hwdec=\(self.stringProperty("hwdec") ?? "?"), codec=\(codec))"
                            if line != self.lastDecoderLine {
                                self.lastDecoderLine = line
                                PlayerLog.write("[decoder] \(line)")
                            }
                        } else if name == "sub-ass-extradata" {
                            // A plain-text track has no header; the style
                            // then goes through the `sub-*` options and the
                            // script height does not matter.
                            let height = self.stringProperty("sub-ass-extradata")
                                .map(SubtitleStyle.playResY(fromHeader:)) ?? 360
                            if height != self.scriptHeight {
                                self.scriptHeight = height
                                self.setSubtitleStyle(SubtitleStyle.current)
                            }
                        } else if name == "demuxer-cache-state" {
                            // mpv fires this on every cache write, tens of
                            // times a second while a swarm delivers; the bar
                            // cannot show a difference finer than this.
                            let now = CACurrentMediaTime()
                            if now - self.lastCacheStateRead >= 0.5 {
                                self.lastCacheStateRead = now
                                let ranges = self.cachedSeekableRanges()
                                await MainActor.run {
                                    self.controller.mpvBufferedRanges = ranges
                                }
                            }
                        } else if name == "cache-buffering-state", let data = prop.data {
                            let percent = Int(data.assumingMemoryBound(to: Int64.self).pointee)
                            await MainActor.run {
                                self.controller.bufferingPercent = percent
                            }
                        } else if name == "duration", let data = prop.data {
                            let dur = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run {
                                guard !self.controller.awaitingNewFile else { return }
                                self.controller.duration = dur
                                self.controller.onPositionChange?(self.controller.currentTime, dur)
                            }
                        } else if name == "video-out-params/dw" || name == "video-out-params/dh", prop.data != nil {
                            // Both read now, as one pair, whichever of the two
                            // fired. mpv reports them as two events, and between
                            // them the aspect was the new width over the old
                            // height: the letterbox gap recomputed from that and
                            // the controls' scrim jumped onto the picture for a
                            // frame ("de fade springt omhoog", a tester's words).
                            let w = self.stringProperty("video-out-params/dw").flatMap(Double.init) ?? 0
                            let h = self.stringProperty("video-out-params/dh").flatMap(Double.init) ?? 0
                            if w > 0, h > 0 {
                                await MainActor.run {
                                    self.controller.videoDisplayWidth = w
                                    self.controller.videoDisplayHeight = h
                                }
                            }
                        } else if name == "video-params/dw", let data = prop.data {
                            let w = data.assumingMemoryBound(to: Int64.self).pointee
                            await MainActor.run { self.controller.decodedDisplayWidth = Double(w) }
                        } else if name == "video-params/dh", let data = prop.data {
                            let h = data.assumingMemoryBound(to: Int64.self).pointee
                            await MainActor.run { self.controller.decodedDisplayHeight = Double(h) }
                        } else if name == "pause", let data = prop.data {
                            let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            await MainActor.run {
                                guard !self.controller.awaitingNewFile else { return }
                                self.controller.isPlaying = !paused
                                if paused {
                                    self.controller.onPositionChange?(self.controller.currentTime, self.controller.duration)
                                }
                            }
                        }
                    }
                }
                // The loop no longer destroys anything here — see `stop()`
                // for why. It only signals that it is done touching `mpv`.
                eventLoopStopped.signal()
            }
        }

        @MainActor
        func stop() {
            guard isRunning else { return }
            isRunning = false
            controller.onSeek = nil
            controller.onSetPause = nil
            controller.onSelectAudioLanguage = nil
            controller.onFetchTracks = nil
            controller.onFetchMpvDetails = nil
            controller.onSelectAudioTrack = nil
            controller.onSelectSubtitleTrack = nil
            controller.onSetVolume = nil
            controller.onSetMuted = nil
            controller.onSetSpeed = nil
            controller.onSetVideoEnabled = nil
            controller.onSetSubtitleScale = nil
            controller.onCycleSideways = nil
            controller.sidewaysState = 0
            controller.onSetFillScreen = nil
            controller.isFillingScreen = false
            sidewaysSavedHwdec = nil
            lastLoadedURL = nil
            pendingStreamURL = nil
            lastAnime4KState = nil
            controller.isBuffering = false
            controller.bufferingPercent = nil
            controller.mpvBufferedRanges = []
            controller.torrentBufferedFractions = []
            controller.onPlaybackStopped?()

            // The event-loop task (`startEventLoop`) polls `mpv` on its own
            // thread and used to `mpv_destroy` it independently once it
            // noticed `isRunning` go false, immediately above — a second
            // thread able to touch `mpv`/the render context at the same moment this
            // function does, with nothing ordering the two. Waiting here for
            // that task to signal it's done fixed the resulting crash, but
            // `stop()` runs synchronously on the main thread (SwiftUI calls
            // it directly from `dismantleNSView`), and blocking the main
            // thread for the wait's full ~50ms window stalled whatever
            // Core Animation transaction was mid-flight at the same
            // moment — the player's own `.transition(.opacity)` fade-out,
            // almost always racing the native fullscreen-exit animation this
            // same state change triggers. The visible result was the last
            // composited frame (controls, gradient scrim, whatever was on
            // screen) freezing in place instead of clearing. So the wait
            // still has to happen before anything touches mpv again, but off
            // the thread that owns the transaction, not on it.
            let eventLoopStopped = eventLoopStopped
            // `OpaquePointer` isn't `Sendable`, so it can't cross into the
            // `@Sendable` closure below directly — boxed the same way the
            // rest of this file already hands mpv handles to a detached
            // task (see `startEventLoop`), except that closure gets away
            // without a box because its capture list is inferred, not a
            // plain `DispatchQueue.global().async` closure's stricter one.
            handleLock.lock()
            let handle = UnsafeSendableBox(self.mpv)
            self.mpv = nil
            handleLock.unlock()
            // Plain GCD, not a Swift `Task`: `DispatchSemaphore.wait()` is a
            // real thread block, and Swift's concurrency checker refuses to
            // compile it inside an `async` closure (blocking a cooperative
            // thread-pool thread can starve the pool) — a plain dispatch
            // queue thread has no such rule.
            DispatchQueue.global(qos: .userInitiated).async {
                eventLoopStopped.wait()
                if let mpv = handle.value {
                    mpv_destroy(mpv)
                }
            }
        }
    }
}

#if os(macOS)
extension MpvSurface: NSViewRepresentable {
    public func makeNSView(context: Context) -> MpvHostView {
        makeHostView(coordinator: context.coordinator)
    }

    public func updateNSView(_ nsView: MpvHostView, context: Context) {
        updateHostView(nsView, coordinator: context.coordinator)
    }

    public static func dismantleNSView(_ nsView: MpvHostView, coordinator: Coordinator) {
        // The other half of "surface attached". A remount stops mpv and
        // reopens the stream at the stored resume point, and a log with the
        // attach but not the teardown cannot say whether the player was
        // rebuilt or merely restarted: an owner report of the picture drawn
        // at the old size in the corner had one attach mid-episode and no
        // way to tell what had unmounted the view.
        PlayerLog.write("[libmpv] surface dismantled")
        coordinator.stop()
    }
}
#else
extension MpvSurface: UIViewRepresentable {
    public func makeUIView(context: Context) -> MpvHostView {
        makeHostView(coordinator: context.coordinator)
    }

    public func updateUIView(_ uiView: MpvHostView, context: Context) {
        updateHostView(uiView, coordinator: context.coordinator)
    }

    public static func dismantleUIView(_ uiView: MpvHostView, coordinator: Coordinator) {
        coordinator.stop()
    }
}
#endif
