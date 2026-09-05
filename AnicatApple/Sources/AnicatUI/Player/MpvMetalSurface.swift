import SwiftUI
import AppKit
import OpenGL.GL
import Cmpv

#if os(macOS)
/// Carries a non-`Sendable` value across an explicit `@Sendable` closure
/// boundary. Safe here specifically because the receiving closure only ever
/// reads it once, after the sender has already stopped touching it — not a
/// general-purpose escape hatch.
private final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
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
    public weak var coordinator: MpvMetalSurface.Coordinator?

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

    private var trackingArea: NSTrackingArea?

    /// Every click toggles play/pause immediately, no waiting to see if a
    /// second click is coming — `clickCount` on this same event already
    /// tells us that. A double click also carries a fullscreen toggle, at
    /// the cost of two play/pause flips netting out to no state change
    /// (the same trade-off YouTube's own player makes) rather than making
    /// every single click wait ~300ms to find out whether it's a double.
    public override func mouseDown(with event: NSEvent) {
        coordinator?.controller.togglePlayPause()
        if event.clickCount >= 2 {
            if let window = AppWindow.main ?? NSApp.keyWindow {
                AppWindow.setToolbarVisible(false)
                window.toggleFullScreen(nil)
            }
        }
    }

    public override func updateTrackingAreas() {
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

    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        coordinator?.controller.showControlsBriefly()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        window?.acceptsMouseMovedEvents = true
        coordinator?.attachMpv(to: self)
        reportContainerSize()
        publishDrawableSize()
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

public struct MpvMetalSurface: NSViewRepresentable {
    @Bindable public var controller: PlayerController
    public let streamURL: URL?

    public init(controller: PlayerController, streamURL: URL?) {
        self.controller = controller
        self.streamURL = streamURL
    }

    public func makeNSView(context: Context) -> MpvRenderView {
        let view = MpvRenderView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.renderView = view
        context.coordinator.controller = controller

        if let streamURL {
            context.coordinator.setPendingStreamURL(streamURL.absoluteString)
        }

        return view
    }

    public func updateNSView(_ nsView: MpvRenderView, context: Context) {
        let coordinator = context.coordinator
        nsView.coordinator = coordinator
        coordinator.renderView = nsView
        coordinator.controller = controller

        if nsView.window != nil && coordinator.mpvHandle == nil {
            coordinator.attachMpv(to: nsView)
        }

        if let streamURL {
            coordinator.loadFile(url: streamURL.absoluteString)
        } else {
            coordinator.clearLoadedURL()
        }

        coordinator.setPaused(!controller.isPlaying)
        coordinator.applyAnime4K(enabled: controller.isAnime4KEnabled)
    }

    public static func dismantleNSView(_ nsView: MpvRenderView, coordinator: Coordinator) {
        coordinator.stop()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public final class Coordinator: NSObject, @unchecked Sendable {
        private var mpv: OpaquePointer?
        /// Everything render-context related lives here, on its own thread.
        /// Set once in `setupMpv`, released by the teardown worker in `stop()`.
        public private(set) var renderTarget: MpvRenderTarget?
        private var isRunning = false
        fileprivate var controller: PlayerController
        fileprivate weak var renderView: MpvRenderView?
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

        func attachMpv(to view: MpvRenderView) {
            guard mpv == nil else { return }
            setupMpv(for: view, controller: controller)
        }

        func setupMpv(for view: MpvRenderView, controller: PlayerController) {
            guard mpv == nil else { return }

            guard let handle = mpv_create() else {
                print("[libmpv] Failed to create mpv instance")
                return
            }

            // "libmpv" is the special vo name that opts into the render API
            // instead of a normal window-owning vo — no "wid" is set at all.
            mpv_set_option_string(handle, "vo", "libmpv")
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
            mpv_set_option_string(handle, "subs-fallback", "yes")

            let initStatus = mpv_initialize(handle)
            if initStatus < 0 {
                print("[libmpv] Failed to initialize mpv: \(initStatus)")
                mpv_destroy(handle)
                return
            }

            // `NSOpenGLContext` is explicitly non-Sendable, so the target
            // that owns it is built inside the main-actor block rather than
            // handing the context out of it.
            let target = MainActor.assumeIsolated { () -> MpvRenderTarget? in
                view.openGLContext.map { MpvRenderTarget(glContext: $0) }
            }
            guard let target else {
                print("[libmpv] No OpenGL context on render view")
                mpv_destroy(handle)
                return
            }

            // Created on the render thread, which is the only thread that
            // will ever touch it again.
            let createStatus = target.create(mpv: handle)
            if createStatus < 0 {
                print("[libmpv] Failed to create render context: \(createStatus)")
                mpv_destroy(handle)
                return
            }
            self.renderTarget = target
            MainActor.assumeIsolated {
                let px = view.convertToBacking(view.bounds).size
                target.setPixelSize(width: Int32(px.width), height: Int32(px.height))
            }

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
        }

        // Backward compatibility overload
        func applyAnime4K(preset: Anime4KPreset) {
            applyAnime4K(enabled: preset != .off)
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

                    if ev.event_id == MPV_EVENT_PROPERTY_CHANGE {
                        let prop = ev.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                        guard let name = prop.name.map({ String(cString: $0) }) else { continue }

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
            let handles = UnsafeSendableBox((target: self.renderTarget, mpv: self.mpv))
            self.renderTarget = nil
            self.mpv = nil
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
                handles.value.target?.destroy()
                if let mpv = handles.value.mpv {
                    mpv_destroy(mpv)
                }
            }
        }
    }
}
#endif
