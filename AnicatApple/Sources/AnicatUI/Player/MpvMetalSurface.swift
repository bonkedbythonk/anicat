import SwiftUI
import AppKit
import Cmpv

#if os(macOS)
/// Dedicated NSView container for libmpv rendering.
/// Defers mpv initialization until attached to an active NSWindow (`self.window != nil`)
/// to prevent libmpv from spawning a standalone Cocoa window or switching to a new macOS desktop space.
@MainActor
public final class MpvVideoContainerView: NSView {
    public weak var coordinator: MpvMetalSurface.Coordinator?
    private var observerRegistered = false

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupWindowObserver()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        setupWindowObserver()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil && observerRegistered {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didUpdateNotification, object: nil)
            observerRegistered = false
        }
    }

    private func setupWindowObserver() {
        guard !observerRegistered else { return }
        observerRegistered = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowUpdate),
            name: NSWindow.didUpdateNotification,
            object: nil
        )
    }

    @objc private func handleWindowUpdate() {
        captureMpvWindowIfNeeded()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard self.window != nil else { return }
        coordinator?.attachMpv(to: self)
        captureMpvWindowIfNeeded()
    }

    public override func layout() {
        super.layout()
        if self.window != nil && coordinator?.mpvHandle == nil {
            coordinator?.attachMpv(to: self)
        }
        captureMpvWindowIfNeeded()
        subviews.forEach { $0.frame = self.bounds }
    }

    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        subview.frame = self.bounds
        subview.autoresizingMask = [.width, .height]
    }

    /// Intercepts any separate Cocoa window spawned by libmpv on macOS,
    /// reparents its content view directly inside this container view, and hides the external window.
    public func captureMpvWindowIfNeeded() {
        guard let myWindow = self.window else { return }
        for w in NSApp.windows {
            // Target auxiliary windows spawned by libmpv
            if w !== myWindow && !w.isKind(of: NSPanel.self) {
                if let cv = w.contentView, cv.superview !== self {
                    w.orderOut(nil)
                    w.setIsVisible(false)
                    cv.removeFromSuperview()
                    self.addSubview(cv)
                    cv.frame = self.bounds
                    cv.autoresizingMask = [.width, .height]
                    print("[libmpv] Successfully integrated mpv surface directly into AniCat window.")
                    break
                }
            }
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

    public func makeNSView(context: Context) -> MpvVideoContainerView {
        let view = MpvVideoContainerView(frame: .zero)
        view.coordinator = context.coordinator
        context.coordinator.containerView = view
        context.coordinator.controller = controller

        if let streamURL = streamURL {
            context.coordinator.setPendingStreamURL(streamURL.absoluteString)
        }

        return view
    }

    public func updateNSView(_ nsView: MpvVideoContainerView, context: Context) {
        let coordinator = context.coordinator
        nsView.coordinator = coordinator
        coordinator.containerView = nsView
        coordinator.controller = controller

        // If view is already attached to a window but mpv is not initialized yet
        if nsView.window != nil && coordinator.mpvHandle == nil {
            coordinator.attachMpv(to: nsView)
        }

        // Update stream URL if changed or new
        if let streamURL = streamURL {
            coordinator.loadFile(url: streamURL.absoluteString)
        } else {
            coordinator.clearLoadedURL()
        }

        // Update playback state
        coordinator.setPaused(!controller.isPlaying)

        // Update Anime4K shaders
        coordinator.applyAnime4K(enabled: controller.isAnime4KEnabled)
    }

    public static func dismantleNSView(_ nsView: MpvVideoContainerView, coordinator: Coordinator) {
        coordinator.stop()
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public final class Coordinator: NSObject, @unchecked Sendable {
        private var mpv: OpaquePointer?
        private var isRunning = false
        fileprivate var controller: PlayerController
        fileprivate weak var containerView: MpvVideoContainerView?
        private var lastLoadedURL: String?
        private var pendingStreamURL: String?
        private var lastAnime4KState: Bool?

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

        func attachMpv(to view: NSView) {
            guard mpv == nil else { return }
            setupMpv(for: view, controller: controller)
        }

        func setupMpv(for view: NSView, controller: PlayerController) {
            guard mpv == nil else { return }

            guard let handle = mpv_create() else {
                print("[libmpv] Failed to create mpv instance")
                return
            }

            // In-app window containment and minimalism: prevent creating external Cocoa window or entering fullscreen desktop space
            mpv_set_option_string(handle, "fullscreen", "no")
            mpv_set_option_string(handle, "border", "no")
            mpv_set_option_string(handle, "window-maximized", "no")
            mpv_set_option_string(handle, "keep-open", "yes")

            // High-performance Apple Silicon settings
            mpv_set_option_string(handle, "vo", "gpu-next")
            mpv_set_option_string(handle, "hwdec", "videotoolbox")
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

            // Attach directly to the hosted NSView layer
            var viewPtr = Int64(Int(bitPattern: Unmanaged.passUnretained(view).toOpaque()))
            mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &viewPtr)

            let initStatus = mpv_initialize(handle)
            if initStatus < 0 {
                print("[libmpv] Failed to initialize mpv: \(initStatus)")
                mpv_destroy(handle)
                return
            }

            self.mpv = handle
            self.isRunning = true

            // Wire controller actions directly to this mpv instance
            controller.onSeek = { [weak self] seconds in
                self?.seek(to: seconds)
            }
            controller.onSetPause = { [weak self] paused in
                self?.setPaused(paused)
            }

            // Observe playback properties
            mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)

            // Start background event loop
            startEventLoop()

            // Apply initial Anime4K state
            applyAnime4K(enabled: controller.isAnime4KEnabled)

            // Apply initial pause state
            setPaused(!controller.isPlaying)

            // Play pending stream if available
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
            if controller.currentTime > 0 {
                let startSec = String(format: "%.2f", controller.currentTime)
                mpv_set_property_string(mpv, "start", startSec)
            } else {
                mpv_set_property_string(mpv, "start", "none")
            }
            runCommand(["loadfile", url, "replace"])
            print("[libmpv] Playing stream: \(url)")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.containerView?.captureMpvWindowIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.containerView?.captureMpvWindowIfNeeded()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.containerView?.captureMpvWindowIfNeeded()
            }
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

        private func startEventLoop() {
            guard let mpv = mpv else { return }

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
                            }
                        } else if name == "duration", let data = prop.data {
                            let dur = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run {
                                self.controller.duration = dur
                                self.controller.onPositionChange?(self.controller.currentTime, dur)
                            }
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
                // Destroy mpv handle strictly after the wait loop has terminated
                mpv_destroy(mpv)
            }
        }

        func stop() {
            guard isRunning else { return }
            isRunning = false
            controller.onSeek = nil
            controller.onSetPause = nil
            lastLoadedURL = nil
            pendingStreamURL = nil
            lastAnime4KState = nil
            controller.onPlaybackStopped?()
            if let handle = mpv {
                self.mpv = nil
                mpv_command_string(handle, "stop")
                mpv_command_string(handle, "quit 0")
                mpv_wakeup(handle)
            }
        }
    }
}
#endif

