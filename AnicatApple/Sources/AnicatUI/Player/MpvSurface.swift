import SwiftUI
#if os(macOS)
import AppKit
import OpenGL.GL
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

/// How mpv's frames reach the screen.
///
/// `.metal` is where both platforms are going: mpv's own `gpu-next` output
/// through Vulkan, which MoltenVK maps onto Metal, drawing into a
/// `CAMetalLayer` we own and hand over as `wid`. That needs MPVKit's
/// libmpv, whose `moltenvk` context (their patch 0001) takes the layer
/// pointer and creates a Vulkan surface on it: no window, no view of mpv's
/// own, no render context or render thread of ours. Stock mpv has no such
/// context; its macOS backend only knows how to open its own window
/// (tried 2026-09-06 with `macvk`: "[vo/gpu-next] Window size: 1920x1080"
/// and a fullscreen window nobody asked for).
///
/// `.openGL` is the previous path, libmpv's render API into an
/// `NSOpenGLView` from `MpvRenderTarget`'s thread. MPVKit's macOS build
/// keeps `gl` enabled, so it still works; it is the escape hatch
/// (`anicat_render_backend = "opengl"`) if Metal misbehaves on some
/// machine, and it goes once a release has shipped without needing it.
/// Anime4K's `glsl-shaders` run inside gpu-next either way.
///
/// Verified on an M4 Pro, macOS 26: video, subtitles, Anime4K, two
/// open/close cycles, no window of mpv's own, zero libmpv frames on the
/// main thread under `sample`.
public enum MpvRenderBackend: String, Sendable {
    // Declared only on macOS, so every `switch` over this enum elsewhere in
    // the file is exhaustive on iOS with the Metal case alone — there is no
    // OpenGL on iOS at all, so an `.openGL` branch there would be a dead
    // arm the compiler still demands a body for.
    #if os(macOS)
    case openGL = "opengl"
    #endif
    case metal = "metal"

    static var configured: MpvRenderBackend {
        #if os(macOS)
        // The environment wins over defaults so a second process can be
        // started on the other backend without touching the running
        // app's setting.
        let raw = ProcessInfo.processInfo.environment["ANICAT_RENDER_BACKEND"]
            ?? UserDefaults.standard.string(forKey: "anicat_render_backend")
            ?? ""
        return MpvRenderBackend(rawValue: raw) ?? .metal
        #else
        // Not a lookup that happens to fail: the escape hatch does not exist
        // on iOS, so the setting has nothing to select and is ignored.
        return .metal
        #endif
    }
}

/// The layer mpv draws into on the `.metal` path.
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

    /// The ambient sampler, when the `.metal` backend is active. Every
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
        if ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil || metalLayer.drawableSize != CGSize(width: bounds.width * scale, height: bounds.height * scale) {
            PlayerLog.write(String(format: "[metal] bounds %@ scale %.0f drawable %@ superview %@", NSStringFromRect(bounds), scale, NSStringFromSize(metalLayer.drawableSize), superview.map { NSStringFromRect($0.frame) } ?? "-"))
        }
        pendingDrawableSync?.cancel()
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
            let fullScreen = self.window?.styleMask.contains(.fullScreen) ?? false
            if fullScreen && self.lastReportedDrawableSize.width > 1 {
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
        let isFullScreen = window?.styleMask.contains(.fullScreen) ?? false
        if metalLayer.drawableSize == .zero || metalLayer.drawableSize.width <= 1 || isFullScreen {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }
}

/// The view SwiftUI hosts. It owns pointer handling and reports its size to
/// the controller; a backend-specific child does the drawing
/// (`MpvMetalView` or `MpvRenderView`). The iOS twin puts a UIKit
/// `CAMetalLayer` view in the same slot under the same coordinator.
///
/// Pointer events live on a transparent topmost subview rather than on the
/// render child, so a child that handles events itself (mpv's own view
/// subclass, in a backend that inserts one) cannot swallow the click.
@MainActor
public final class MpvHostView: NSView {
    public weak var coordinator: MpvSurface.Coordinator?
    /// Immutable after init, so safe to read from the coordinator's setup
    /// path without a hop.
    public nonisolated let backend: MpvRenderBackend
    /// Present for `.openGL` only.
    public private(set) var glView: MpvRenderView?
    /// Present for `.metal` only.
    public private(set) var metalView: MpvMetalView?
    private let eventCatcher = MpvEventCatcherView(frame: .zero)

    public init(frame frameRect: NSRect, backend: MpvRenderBackend) {
        self.backend = backend
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        switch backend {
        case .openGL:
            let gl = MpvRenderView(frame: bounds)
            gl.autoresizingMask = [.width, .height]
            addSubview(gl)
            glView = gl
        case .metal:
            let metal = MpvMetalView(frame: bounds)
            metal.autoresizingMask = [.width, .height]
            addSubview(metal)
            metalView = metal
        }
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
        glView?.coordinator = coordinator
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

/// Renders mpv via libmpv's render API (`mpv_render_context`) into our own
/// `NSOpenGLView`, instead of handing mpv a `wid` and letting its cocoa-cb
/// backend own a real Cocoa window.
///
/// The `wid` approach (previous implementation) always spawns mpv's own
/// auxiliary NSWindow internally — embedding is done by mpv reparenting that
/// window's content view into ours after the fact, which is exactly the
/// "stray window" mpv's own docs warn about: "using the render API is
/// recommended, because window embedding can cause various issues" (render.h).
/// It's also the direct cause of every symptom hit in practice: the window
/// briefly visible in the wrong place before capture, its content view's
/// stale frame leaving the video pillarboxed, and cocoa-cb swapping the Dock
/// tile to mpv's own logo the moment its vo/window is created.
///
/// The render API has no window at all — mpv draws into an FBO we own on
/// demand, so none of that exists by construction. `OpenGL` (not Metal) is
/// used because it's the only accelerated backend `render.h`/`render_gl.h`
/// expose on macOS (`MPV_RENDER_API_TYPE_OPENGL` — there is no
/// `MPV_RENDER_API_TYPE_METAL` in libmpv's public API); this is the same
/// mechanism mpv's own macOS docs describe for hardware decoding via CGL, and
/// what embedders predating cocoa-cb (and IINA's advanced/embedded mode) use.
@MainActor
public final class MpvRenderView: NSOpenGLView {
    public weak var coordinator: MpvSurface.Coordinator?

    public override init(frame frameRect: NSRect) {
        let attrs: [NSOpenGLPixelFormatAttribute] = [
            UInt32(NSOpenGLPFAAccelerated),
            UInt32(NSOpenGLPFADoubleBuffer),
            UInt32(NSOpenGLPFAColorSize), 32,
            UInt32(NSOpenGLPFAOpenGLProfile), UInt32(NSOpenGLProfileVersion3_2Core),
            0
        ]
        guard let pixelFormat = NSOpenGLPixelFormat(attributes: attrs) else {
            fatalError("[libmpv] No OpenGL 3.2 core pixel format available")
        }
        // NSOpenGLView's real designated initializer is init(frame:pixelFormat:);
        // delegating to it (rather than the plain init(frame:) this override
        // shadows) is how every NSOpenGLView subclass picks its pixel format.
        super.init(frame: frameRect, pixelFormat: pixelFormat)!
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        wantsBestResolutionOpenGLSurface = true
        // Vsync on the swap. `flushBuffer` runs on the render thread (see
        // `MpvRenderTarget`), so the block it implies paces that thread to
        // the display and costs the main thread nothing. mpv gets the swap
        // time through `report_swap` and schedules the next frame off it.
        openGLContext?.setValues([1], for: .swapInterval)
    }

    /// The backing-pixel size mpv renders at, pushed to the render thread
    /// whenever it changes. Computed here because `convertToBacking` and
    /// `bounds` are main-thread properties the render thread must not read.
    private func publishDrawableSize() {
        let px = convertToBacking(bounds).size
        coordinator?.renderTarget?.setPixelSize(width: Int32(px.width), height: Int32(px.height))
    }

    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used — MpvRenderView is always constructed programmatically")
    }

    public override func reshape() {
        super.reshape()
        // `update()` touches the drawable while the render thread may be
        // mid-frame on the same context; CGL's context lock is the one
        // serialization AppKit documents for a multithreaded NSOpenGLView.
        if let context = openGLContext {
            CGLLockContext(context.cglContextObj!)
            context.update()
            CGLUnlockContext(context.cglContextObj!)
        }
        reportContainerSize()
        publishDrawableSize()
        needsDisplay = true
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        publishDrawableSize()
    }

    public override func layout() {
        super.layout()
        reportContainerSize()
        publishDrawableSize()
    }

    /// The chrome bars need to know exactly how large the video's own
    /// letterboxed rect is, and doing that math against a second, separate
    /// SwiftUI `GeometryReader` measurement invited a mismatch: this view's
    /// `.ignoresSafeArea()` lets it bleed to the window's true edges in a
    /// way a sibling `GeometryReader` reading the same hierarchy isn't
    /// guaranteed to agree with (sidebar-claimed HStack space, safe-area
    /// nesting) — the bars fit against a *different* rect than the one the
    /// video actually rendered into. Reporting this view's own real `bounds`
    /// (the same value `draw(_:)` already trusts for `renderFrame`) removes
    /// the second source of truth entirely.
    private func reportContainerSize() {
        coordinator?.controller.videoContainerSize = bounds.size
    }

    /// Video is not drawn here. Frames are rendered by `MpvRenderTarget` on
    /// its own thread, driven by mpv's update callback. Doing it here made
    /// every frame wait for the main run loop and every SwiftUI layout pass
    /// wait for the frame: `needsDisplay` coalesced 24fps content to
    /// AppKit's display cycle, `mpv_render_context_render` blocked the main
    /// thread until the frame's target time, and the FPS HUD counted the
    /// result as main-thread stalls during playback. AppKit still calls this
    /// on resize and first appearance, so it clears to black while no render
    /// context exists (the surface is undefined before the first frame) and
    /// otherwise asks the render thread to repaint the last frame at the new
    /// size.
    public override func draw(_ dirtyRect: NSRect) {
        guard let context = openGLContext else { return }
        if let target = coordinator?.renderTarget {
            target.requestRedraw()
            return
        }
        CGLLockContext(context.cglContextObj!)
        context.makeCurrentContext()
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))
        context.flushBuffer()
        CGLUnlockContext(context.cglContextObj!)
    }
}

/// Owns everything that touches `mpv_render_context`: a serial queue whose
/// single thread is the only one that ever calls create, update, render or
/// free, the `NSOpenGLContext` it makes current there, and the drawable's
/// pixel size as last published by the view on the main thread.
///
/// render.h's contract is that the OpenGL context is current on whichever
/// thread makes a render-context call and that, with `advanced_control` on,
/// `mpv_render_context_update` is called for every update callback. Keeping
/// all of it on one queue satisfies both without a lock around each call,
/// and `advanced_control` in turn lets mpv render videotoolbox frames
/// directly into GL textures instead of copying them.
///
/// The update callback (which mpv fires from its own threads) only enqueues;
/// the closure retains this object, so a callback that lands after the
/// coordinator has let go still has something valid to run against and
/// finds `renderCtx` nil once `destroy()` has run ahead of it on the same
/// serial queue.
public final class MpvRenderTarget: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.anicat.mpv.render", qos: .userInteractive)
    private let glContext: NSOpenGLContext
    /// Queue-confined after `create`.
    private var renderCtx: OpaquePointer?
    private let sizeLock = NSLock()
    private var pixelWidth: Int32 = 0
    private var pixelHeight: Int32 = 0

    init(glContext: NSOpenGLContext) {
        self.glContext = glContext
    }

    var isCreated: Bool { queue.sync { renderCtx != nil } }

    /// Creates the render context on the render thread. Blocks the caller
    /// (setup, on the main thread) for the one-time creation only.
    func create(mpv: OpaquePointer) -> Int32 {
        queue.sync {
            CGLLockContext(glContext.cglContextObj!)
            defer { CGLUnlockContext(glContext.cglContextObj!) }
            glContext.makeCurrentContext()

            var glInitParams = mpv_opengl_init_params(
                get_proc_address: { _, name in
                    guard let name else { return nil }
                    // render_gl.h: "macOS: CGL is required
                    // (CGLGetCurrentContext() returning non-NULL)". The
                    // OpenGL framework's symbols are already loaded into the
                    // process by NSOpenGLContext, so dlsym against the
                    // global namespace resolves them without linking CGL.
                    return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
                },
                get_proc_address_ctx: nil
            )
            var advanced: CInt = 1
            let apiType = strdup(MPV_RENDER_API_TYPE_OPENGL)
            defer { free(apiType) }

            var status: Int32 = -1
            withUnsafeMutablePointer(to: &glInitParams) { initPtr in
                withUnsafeMutablePointer(to: &advanced) { advPtr in
                    var params: [mpv_render_param] = [
                        mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiType),
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: UnsafeMutableRawPointer(initPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: UnsafeMutableRawPointer(advPtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    status = mpv_render_context_create(&renderCtx, mpv, &params)
                }
            }
            guard status >= 0, let renderCtx else {
                self.renderCtx = nil
                return status
            }
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            mpv_render_context_set_update_callback(renderCtx, { ctx in
                guard let ctx else { return }
                // Retained across the hop: see the type's doc comment.
                let target = Unmanaged<MpvRenderTarget>.fromOpaque(ctx).takeUnretainedValue()
                target.queue.async { target.handleUpdate() }
            }, selfPtr)
            return status
        }
    }

    /// Main thread. Stores the size for the render thread and repaints the
    /// current frame at it, so a live resize tracks the window instead of
    /// waiting for the next decoded frame.
    func setPixelSize(width: Int32, height: Int32) {
        sizeLock.lock()
        let changed = width != pixelWidth || height != pixelHeight
        pixelWidth = width
        pixelHeight = height
        sizeLock.unlock()
        if changed { requestRedraw() }
    }

    func requestRedraw() {
        queue.async { self.render() }
    }

    /// One update callback's worth of work. `mpv_render_context_update`
    /// must be called once per callback with `advanced_control` on, whether
    /// or not a frame follows.
    private func handleUpdate() {
        guard let renderCtx else { return }
        let flags = mpv_render_context_update(renderCtx)
        if flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 {
            render()
        }
    }

    private func render() {
        guard let renderCtx else { return }
        sizeLock.lock()
        let width = pixelWidth
        let height = pixelHeight
        sizeLock.unlock()
        guard width > 0, height > 0 else { return }

        CGLLockContext(glContext.cglContextObj!)
        defer { CGLUnlockContext(glContext.cglContextObj!) }
        glContext.makeCurrentContext()

        var fbo = mpv_opengl_fbo(fbo: 0, w: width, h: height, internal_format: 0)
        // The default framebuffer's origin is bottom-left; mpv's frames are
        // top-left. Without this the picture renders upside down.
        var flip: CInt = 1
        withUnsafeMutablePointer(to: &fbo) { fboPtr in
            withUnsafeMutablePointer(to: &flip) { flipPtr in
                var params: [mpv_render_param] = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: UnsafeMutableRawPointer(fboPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: UnsafeMutableRawPointer(flipPtr)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                mpv_render_context_render(renderCtx, &params)
            }
        }
        // Swap first, then report: `report_swap` is how mpv learns when the
        // frame actually hit the display, and it was previously called
        // before the swap so every timing sample it took was early by a
        // vsync.
        glContext.flushBuffer()
        mpv_render_context_report_swap(renderCtx)
    }

    /// Frees the render context on the render thread with the GL context
    /// current, as render.h requires, and detaches the update callback
    /// first so mpv stops enqueueing. Blocks the caller; call it from the
    /// teardown worker, never from the main thread, since a frame in flight
    /// may be blocking on its target time.
    func destroy() {
        queue.sync {
            guard let renderCtx else { return }
            mpv_render_context_set_update_callback(renderCtx, nil, nil)
            CGLLockContext(glContext.cglContextObj!)
            glContext.makeCurrentContext()
            mpv_render_context_free(renderCtx)
            CGLUnlockContext(glContext.cglContextObj!)
            self.renderCtx = nil
        }
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
    /// Immutable after init, so safe to read from the coordinator's setup
    /// path without a hop.
    public nonisolated let backend: MpvRenderBackend
    public private(set) var metalView: MpvMetalView?
    private let eventCatcher = MpvEventCatcherView(frame: .zero)

    public init(frame: CGRect, backend: MpvRenderBackend) {
        self.backend = backend
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
        let view = MpvHostView(frame: .zero, backend: MpvRenderBackend.configured)
        view.coordinator = coordinator
        coordinator.hostView = view
        #if os(macOS)
        coordinator.renderView = view.glView
        #endif
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
        #if os(macOS)
        coordinator.renderView = view.glView
        #endif
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
        #if os(macOS)
        /// Everything render-context related lives here, on its own thread.
        /// Set once in `setupMpv`, released by the teardown worker in `stop()`.
        public private(set) var renderTarget: MpvRenderTarget?
        fileprivate weak var renderView: MpvRenderView?
        #endif
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

            switch view.backend {
            #if os(macOS)
            case .openGL:
                // "libmpv" is the special vo name that opts into the render
                // API instead of a normal window-owning vo — no "wid" is set.
                mpv_set_option_string(handle, "vo", "libmpv")
            #endif
            case .metal:
                // See MpvRenderBackend. `wid` is the CAMetalLayer pointer;
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

            let initStatus = mpv_initialize(handle)
            if initStatus < 0 {
                print("[libmpv] Failed to initialize mpv: \(initStatus)")
                mpv_destroy(handle)
                return
            }

            #if os(macOS)
            if view.backend == .openGL {
                // `NSOpenGLContext` is explicitly non-Sendable, so the
                // target that owns it is built inside the main-actor block
                // rather than handing the context out of it.
                let target = MainActor.assumeIsolated { () -> MpvRenderTarget? in
                    view.glView?.openGLContext.map { MpvRenderTarget(glContext: $0) }
                }
                guard let target else {
                    print("[libmpv] No OpenGL context on render view")
                    mpv_destroy(handle)
                    return
                }

                // Created on the render thread, which is the only thread
                // that will ever touch it again.
                let createStatus = target.create(mpv: handle)
                if createStatus < 0 {
                    print("[libmpv] Failed to create render context: \(createStatus)")
                    mpv_destroy(handle)
                    return
                }
                self.renderTarget = target
                MainActor.assumeIsolated {
                    if let gl = view.glView {
                        let px = gl.convertToBacking(gl.bounds).size
                        target.setPixelSize(width: Int32(px.width), height: Int32(px.height))
                    }
                }
            }
            #endif

            self.mpv = handle
            self.isRunning = true

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
            controller.onCycleSideways = { [weak self] in
                self?.cycleSideways()
            }

            mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)
            mpv_observe_property(handle, 4, "paused-for-cache", MPV_FORMAT_FLAG)
            mpv_observe_property(handle, 5, "cache-buffering-state", MPV_FORMAT_INT64)
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
        func nudgeVideoReconfig() -> Bool {
            let debug = ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil
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
            if ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil {
                PlayerLog.write(String(format: "[nudge] override %@ -> %.6f, osd/w %@", current, detour, nudgeOSDBefore ?? "-"))
            }
            runCommand(["set", "video-aspect-override", String(format: "%.6f", detour)])
            scheduleNudgeRestore(after: 0.03)
            return true
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
                if ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil {
                    PlayerLog.write(String(format: "[nudge] restore to %@ after %.2fs, reconfigured %@%@", original, waited, reconfigured ? "yes" : "no", again ? ", running the deferred one" : ""))
                }
                self.runCommand(["set", "video-aspect-override", original])
                if again {
                    // Off this block: `nudgeVideoReconfig` reads properties
                    // through the handle lock this closure is still holding.
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.03) { [weak self] in
                        self?.nudgeVideoReconfig()
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
            if ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil {
                PlayerLog.write(String(format: "[nudge] drawable now %.0fx%.0f", size.width, size.height))
            }
            lastDrawableSize = size
            reconfigAttemptsForSize = 0
            nudgeVideoReconfig()
            // And once more after the size has held still. A nudge only
            // reconfigures when a frame next passes through mpv's filters,
            // and `verifyVideoSizeIfDue` cannot catch a nudge that did
            // nothing: `osd-dimensions` already read the new size on the
            // restore that worked ("osd/w 2500" before its nudge) and on the
            // one that did not, so the check matched while the swapchain
            // stayed small.
            settleNudge?.cancel()
            let settle = DispatchWorkItem { [weak self] in self?.nudgeVideoReconfig() }
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
            nudgeVideoReconfig()
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
            if ProcessInfo.processInfo.environment["ANICAT_PLAYER_DEBUG"] != nil || force {
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
                guard nudgeVideoReconfig() else { return }
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
        /// OpenGL escape hatch.
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
            let inset = AmbientGlow.contentInset(of: frame) ?? .zero
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
                NSLog("[ambient] screenshot-raw unavailable (%d); falling back to the episode still", status)
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
                NSLog("[ambient] screenshot-raw %.1fms + downscale %.1fms = %.1fms",
                      (captured - now) * 1000, (finished - captured) * 1000, elapsed * 1000)
            }
            if elapsed > AmbientSampleGate.budget {
                NSLog("[ambient] sample took %.1fms (over budget %d/%d in a row)",
                      elapsed * 1000, ambientGate.slowStreak + 1, AmbientSampleGate.slowSampleLimit)
            }
            let before = ambientGate.currentInterval
            ambientGate.record(elapsed: elapsed)
            if ambientGate.currentInterval != before {
                NSLog("[ambient] sampling every %.0fms now", ambientGate.currentInterval * 1000)
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
                                if !self.controller.isScrubbing {
                                    self.controller.currentTime = pos
                                    self.controller.checkIntroStatus()
                                    self.controller.onPositionChange?(pos, self.controller.duration)
                                }
                                self.controller.isBuffering = false
                            }
                        } else if name == "paused-for-cache", let data = prop.data {
                            let buffering = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            await MainActor.run {
                                self.controller.isBuffering = buffering
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
            controller.onSelectAudioTrack = nil
            controller.onSelectSubtitleTrack = nil
            controller.onSetVolume = nil
            controller.onSetMuted = nil
            controller.onSetSpeed = nil
            controller.onCycleSideways = nil
            controller.sidewaysState = 0
            sidewaysSavedHwdec = nil
            lastLoadedURL = nil
            pendingStreamURL = nil
            lastAnime4KState = nil
            controller.isBuffering = false
            controller.bufferingPercent = nil
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
            // `MpvRenderTarget` needs no box; it is `@unchecked Sendable`.
            handleLock.lock()
            let handle = UnsafeSendableBox(self.mpv)
            self.mpv = nil
            handleLock.unlock()
            #if os(macOS)
            let renderTarget = self.renderTarget
            self.renderTarget = nil
            #endif
            // Plain GCD, not a Swift `Task`: `DispatchSemaphore.wait()` is a
            // real thread block, and Swift's concurrency checker refuses to
            // compile it inside an `async` closure (blocking a cooperative
            // thread-pool thread can starve the pool) — a plain dispatch
            // queue thread has no such rule.
            DispatchQueue.global(qos: .userInitiated).async {
                eventLoopStopped.wait()
                // render.h: "You must free the context with
                // mpv_render_context_free() before the mpv core is
                // destroyed." `destroy()` does that on the render thread with
                // the GL context current there, so teardown no longer needs
                // the main thread at all: the old `DispatchQueue.main.sync`
                // hop here could land while the main thread was inside
                // `reshape()` holding the same CGL lock.
                #if os(macOS)
                renderTarget?.destroy()
                #endif
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
