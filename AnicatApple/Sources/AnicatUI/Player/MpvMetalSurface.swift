import SwiftUI
import AppKit
import Cmpv

#if os(macOS)
public struct MpvMetalSurface: NSViewRepresentable {
    @Bindable public var controller: PlayerController
    public let streamURL: URL?

    public init(controller: PlayerController, streamURL: URL?) {
        self.controller = controller
        self.streamURL = streamURL
    }

    public func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor

        let coordinator = context.coordinator
        coordinator.setupMpv(for: view, controller: controller)

        if let streamURL = streamURL {
            coordinator.loadFile(url: streamURL.absoluteString)
        }

        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator

        // Update playback state
        coordinator.setPaused(!controller.isPlaying)

        // Update Anime4K shaders
        coordinator.applyAnime4K(preset: controller.activeAnime4KPreset)
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    public final class Coordinator: NSObject, @unchecked Sendable {
        private var mpv: OpaquePointer?
        private var isRunning = false
        private var controller: PlayerController
        private var lastLoadedURL: String?
        private var lastPreset: Anime4KPreset?

        init(controller: PlayerController) {
            self.controller = controller
            super.init()
        }

        deinit {
            stop()
        }

        func setupMpv(for view: NSView, controller: PlayerController) {
            guard mpv == nil else { return }

            guard let handle = mpv_create() else {
                print("[libmpv] Failed to create mpv instance")
                return
            }

            // High-performance Apple Silicon settings
            mpv_set_option_string(handle, "vo", "gpu-next")
            mpv_set_option_string(handle, "hwdec", "videotoolbox")
            mpv_set_option_string(handle, "keep-open", "yes")
            mpv_set_option_string(handle, "osc", "no")
            mpv_set_option_string(handle, "osd-level", "0")
            mpv_set_option_string(handle, "input-default-bindings", "no")

            // Attach directly to the NSView layer
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

            // Observe playback properties
            mpv_observe_property(handle, 1, "time-pos", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 2, "duration", MPV_FORMAT_DOUBLE)
            mpv_observe_property(handle, 3, "pause", MPV_FORMAT_FLAG)

            // Start background event loop
            startEventLoop()
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
            _ = cArgs.withUnsafeMutableBufferPointer { ptr in
                mpv_command(mpv, ptr.baseAddress)
            }
        }

        func loadFile(url: String) {
            guard url != lastLoadedURL else { return }
            lastLoadedURL = url
            runCommand(["loadfile", url])
            print("[libmpv] Playing stream: \(url)")
        }

        func setPaused(_ paused: Bool) {
            guard let mpv = mpv else { return }
            var flag: Int32 = paused ? 1 : 0
            mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag)
        }

        func seek(to seconds: Double) {
            runCommand(["seek", String(format: "%.2f", seconds), "absolute"])
        }

        func applyAnime4K(preset: Anime4KPreset) {
            guard let mpv = mpv, preset != lastPreset else { return }
            lastPreset = preset

            let shaderString = preset.resolveMpvShaderString()
            mpv_set_property_string(mpv, "glsl-shaders", shaderString)
            if shaderString.isEmpty {
                print("[libmpv] Anime4K disabled")
            } else {
                print("[libmpv] Applied Anime4K preset: \(preset.displayName)")
            }
        }

        private func startEventLoop() {
            guard let mpv = mpv else { return }

            Task.detached(priority: .userInitiated) { [weak self, mpv] in
                while let self = self, self.isRunning {
                    let event = mpv_wait_event(mpv, 0.05)
                    guard let ev = event?.pointee, ev.event_id != MPV_EVENT_NONE else {
                        continue
                    }

                    if ev.event_id == MPV_EVENT_PROPERTY_CHANGE {
                        let prop = ev.data.assumingMemoryBound(to: mpv_event_property.self).pointee
                        guard let name = prop.name.map({ String(cString: $0) }) else { continue }

                        if name == "time-pos", let data = prop.data {
                            let pos = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run {
                                self.controller.currentTime = pos
                                self.controller.checkIntroStatus()
                            }
                        } else if name == "duration", let data = prop.data {
                            let dur = data.assumingMemoryBound(to: Double.self).pointee
                            await MainActor.run {
                                self.controller.duration = dur
                            }
                        } else if name == "pause", let data = prop.data {
                            let paused = data.assumingMemoryBound(to: Int32.self).pointee != 0
                            await MainActor.run {
                                self.controller.isPlaying = !paused
                            }
                        }
                    }
                }
            }
        }

        func stop() {
            isRunning = false
            if let handle = mpv {
                mpv_destroy(handle)
                self.mpv = nil
            }
        }
    }
}
#endif
