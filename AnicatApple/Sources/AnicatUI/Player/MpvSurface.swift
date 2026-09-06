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

    private func syncDrawableSize() {
        let scale = window?.backingScaleFactor ?? 2
        metalLayer.contentsScale = scale
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
                window.toggleFullScreen(nil)
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
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }
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

    public init(controller: PlayerController, streamURL: URL?) {
        self.controller = controller
        self.streamURL = streamURL
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
            stop()
        }

        func setPendingStreamURL(_ url: String) {
            pendingStreamURL = url
        }

        func attachMpv(to view: MpvHostView) {
            guard mpv == nil else { return }
            setupMpv(for: view, controller: controller)
        }

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
            controller.onCycleAudioTrack = { [weak self] in
                self?.runCommand(["cycle", "audio"])
            }
            controller.onSelectAudioLanguage = { [weak self] preferDub, completion in
                // Off the main thread: `selectAudioLanguage` walks
                // `track-list/N/...` with blocking property reads.
                DispatchQueue.global(qos: .userInitiated).async {
                    let switched = self?.selectAudioLanguage(preferDub: preferDub) ?? false
                    Task { @MainActor in completion(switched) }
                }
            }
            controller.onCycleSubtitleTrack = { [weak self] in
                self?.runCommand(["cycle", "sub"])
            }
            controller.onFetchTrackInfo = { [weak self] in
                self?.fetchTrackInfo() ?? (audio: "-", subtitle: "-")
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
            // Decoded display size (post-rotation, post-pixel-aspect-ratio) —
            // what the overlay chrome needs to know where the letterboxed
            // video rect actually sits, as opposed to the window's own size.
            mpv_observe_property(handle, 6, "video-params/dw", MPV_FORMAT_INT64)
            mpv_observe_property(handle, 7, "video-params/dh", MPV_FORMAT_INT64)

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

        func applyAnime4K(enabled: Bool) {
            #if !os(macOS)
            // iOS does not upscale, by decision: the shader chain is tuned
            // for a MacBook's thermals and the setting is not offered there,
            // so nothing on iOS ever sends `glsl-shaders`.
            _ = enabled
            #else
            guard let mpv = mpv, enabled != lastAnime4KState else { return }
            lastAnime4KState = enabled

            let shaderString: String
            if enabled {
                shaderString = Anime4KPreset.on.resolveMpvShaderString()
            } else {
                shaderString = ""
            }

            mpv_set_property_string(mpv, "glsl-shaders", shaderString)
            if shaderString.isEmpty {
                print("[libmpv] Anime4K disabled")
            } else {
                print("[libmpv] Applied Anime4K 6-shader pipeline")
            }
            #endif
        }

        // Backward compatibility overload
        func applyAnime4K(preset: Anime4KPreset) {
            applyAnime4K(enabled: preset != .off)
        }

        /// Selects the loaded file's audio track whose language matches the
        /// Sub/Dub choice. Walks `track-list/N/...` sub-properties rather
        /// than parsing the whole MPV_FORMAT_NODE list, same reason as
        /// `fetchTrackInfo` below. A file with no track in the wanted
        /// language is left alone — a single-audio sub release has nothing
        /// to switch to, and forcing `aid` there would only mute it. Returns
        /// whether a matching track was found, so the caller can say so
        /// instead of reporting a switch that did not happen.
        @discardableResult
        func selectAudioLanguage(preferDub: Bool) -> Bool {
            guard let mpv else { return false }
            func stringProperty(_ name: String) -> String? {
                guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
                defer { mpv_free(cstr) }
                let value = String(cString: cstr)
                return value.isEmpty ? nil : value
            }
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

        /// The Sub/Dub preference, in the one vocabulary `anicat_sub_dub` is
        /// stored in by both Settings and the detail page's AUDIO toggle.
        static func preferDubSetting() -> Bool {
            UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        }

        static func audioLanguages(preferDub: Bool) -> String {
            preferDub ? "en,eng,English" : "ja,jpn,Japanese,en,eng,English"
        }

        /// mpv exposes the currently-selected track's language/title as
        /// nested sub-properties (e.g. "current-tracks/audio/lang") — no
        /// need to pull and parse the full MPV_FORMAT_NODE track-list for
        /// just "what's playing right now".
        func fetchTrackInfo() -> (audio: String, subtitle: String) {
            guard let mpv else { return (audio: "-", subtitle: "-") }
            func stringProperty(_ name: String) -> String? {
                guard let cstr = mpv_get_property_string(mpv, name) else { return nil }
                defer { mpv_free(cstr) }
                let value = String(cString: cstr)
                return value.isEmpty ? nil : value
            }
            let audio = stringProperty("current-tracks/audio/lang")
                ?? stringProperty("current-tracks/audio/title")
                ?? "Off"
            let subtitle = stringProperty("current-tracks/sub/lang")
                ?? stringProperty("current-tracks/sub/title")
                ?? "Off"
            return (audio: audio, subtitle: subtitle)
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
                    if ev.event_id == MPV_EVENT_NONE {
                        guard let self = self, self.isRunning else {
                            break
                        }
                        continue
                    }
                    guard let self = self, self.isRunning else {
                        break
                    }

                    if ev.event_id == MPV_EVENT_FILE_LOADED {
                        await MainActor.run { self.controller.awaitingNewFile = false }
                        continue
                    }

                    if ev.event_id == MPV_EVENT_PROPERTY_CHANGE {
                        let prop = ev.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                        guard let name = prop.name.map({ String(cString: $0) }) else { continue }

                        // Still the previous file's numbers: see
                        // `PlayerController.awaitingNewFile`.
                        let stale = await MainActor.run { self.controller.awaitingNewFile }
                        if stale, ["time-pos", "duration", "pause"].contains(name) {
                            continue
                        }

                        if name == "time-pos", let data = prop.data {
                            let pos = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run {
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
                                self.controller.duration = dur
                                self.controller.onPositionChange?(self.controller.currentTime, dur)
                            }
                        } else if name == "video-params/dw", let data = prop.data {
                            let w = data.assumingMemoryBound(to: Int64.self).pointee
                            await MainActor.run { self.controller.videoDisplayWidth = Double(w) }
                        } else if name == "video-params/dh", let data = prop.data {
                            let h = data.assumingMemoryBound(to: Int64.self).pointee
                            await MainActor.run { self.controller.videoDisplayHeight = Double(h) }
                        } else if name == "pause", let data = prop.data {
                            let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            await MainActor.run {
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

        func stop() {
            guard isRunning else { return }
            isRunning = false
            controller.onSeek = nil
            controller.onSetPause = nil
            controller.onCycleAudioTrack = nil
            controller.onSelectAudioLanguage = nil
            controller.onCycleSubtitleTrack = nil
            controller.onFetchTrackInfo = nil
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
            let handle = UnsafeSendableBox(self.mpv)
            self.mpv = nil
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
