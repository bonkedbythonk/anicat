import SwiftUI
import Observation
import QuartzCore
#if os(macOS)
import AppKit
#endif

// MARK: - FPSMonitor

/// Measures two independent signals:
///
/// 1. **Frame rate** — via `NSScreen.displayLink` (compositor thread). This tells
///    you whether the GPU is keeping up. If FPS stays at 120 but scrolling still
///    feels "jumpy", frames are composited on time but…
///
/// 2. **Main-thread stalls** — a background thread pings the main queue every 4ms
///    and records how long the main thread took to respond. When the main thread is
///    busy evaluating SwiftUI bodies / layout / hit-testing, it can't respond to
///    scroll events promptly, causing the scroll *position* to update in large jumps
///    even though the compositor keeps rendering at 120 Hz. This is the "120 fps
///    but still feels sluggish" scenario.
@Observable
@MainActor
public final class FPSMonitor: NSObject {
    public static let shared = FPSMonitor()

    // MARK: Frame rate (display link)
    public private(set) var currentFPS: Double = 120.0
    public private(set) var targetFPS: Double = 120.0
    public private(set) var frameTimeMs: Double = 8.3
    public private(set) var minFPS: Double = 120.0
    public private(set) var maxFrameTimeMs: Double = 8.3
    public private(set) var droppedFrames: Int = 0
    public private(set) var recentFrameTimes: [Double] = Array(repeating: 8.3, count: 40)

    // MARK: Main-thread stalls
    /// Number of times the main thread took >16ms to respond to a 4ms ping.
    public private(set) var mainThreadStalls: Int = 0
    /// Worst main-thread response latency seen this session (ms).
    public private(set) var worstStallMs: Double = 0
    /// The most recent stall duration in ms (0 if no stall in the last window).
    public private(set) var lastStallMs: Double = 0
    /// Rolling window of the 40 most recent main-thread ping response times (ms).
    public private(set) var recentMainThreadMs: [Double] = Array(repeating: 0, count: 40)

    public var isExpanded: Bool = false
    public var logHitchesToConsole: Bool = true

    #if os(macOS)
    private var displayLink: CADisplayLink?
    #endif

    private var lastTimestamp: CFTimeInterval = 0
    private var lastUIUpdateTime: CFTimeInterval = 0
    private var isRunning: Bool = false

    // Rolling window for frame-rate min/max
    private var windowFrameTimes: [Double] = []
    private let windowCapacity = 120

    // Same role as `windowFrameTimes` but for the main-thread watcher: a
    // plain local buffer the ping loop can append to every 8ms for free,
    // published to the @Observable `recentMainThreadMs` only at the ~5Hz
    // throttle below instead of on every ping.
    private var windowMainThreadMs: [Double] = []
    private var lastMainThreadUIUpdateTime: CFTimeInterval = 0

    // Main-thread watcher
    private var watcherThread: Thread?
    // Polled from the watcher thread, set from the main actor. A plain flag
    // is what this wants (a stale read costs one extra 8ms ping); the
    // annotation says so instead of routing every poll through the actor.
    nonisolated(unsafe) private var watcherShouldStop = false

    override private init() {
        super.init()
    }

    // MARK: - Lifecycle

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastTimestamp = 0
        lastUIUpdateTime = 0
        lastMainThreadUIUpdateTime = 0
        windowFrameTimes.removeAll(keepingCapacity: true)
        windowMainThreadMs.removeAll(keepingCapacity: true)
        watcherShouldStop = false

        #if os(macOS)
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let link = screen.displayLink(target: self, selector: #selector(onFrame(_:)))
        // Pin to the display's max refresh rate. Without this, ProMotion treats
        // an unpinned link as adaptive and throttles it during "low motion"
        // stretches, then ramps back up when scrolling resumes — the ramp is
        // itself visible as a stutter, with zero app-side CPU cost to show for
        // it (confirmed via `sample`: main thread is ~98% idle in mach_msg2_trap
        // during scroll, so the drops aren't SwiftUI body/layout work).
        let maxFPS = Float(screen.maximumFramesPerSecond)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: maxFPS, maximum: maxFPS, preferred: maxFPS)
        link.add(to: .main, forMode: .common)
        self.displayLink = link
        #endif

        // Start the main-thread hitch watcher on a background thread
        let thread = Thread { [weak self] in self?.runWatcher() }
        thread.name = "FPSMonitor.MainThreadWatcher"
        thread.qualityOfService = .userInteractive
        thread.start()
        watcherThread = thread
    }

    public func stop() {
        isRunning = false
        watcherShouldStop = true
        #if os(macOS)
        displayLink?.invalidate()
        displayLink = nil
        #endif
        lastTimestamp = 0
    }

    public func reset() {
        droppedFrames = 0
        mainThreadStalls = 0
        worstStallMs = 0
        lastStallMs = 0
        minFPS = targetFPS
        maxFrameTimeMs = 1000.0 / max(1, targetFPS)
        windowFrameTimes.removeAll(keepingCapacity: true)
        recentFrameTimes = Array(repeating: 1000.0 / max(1, targetFPS), count: 40)
        recentMainThreadMs = Array(repeating: 0, count: 40)
    }

    // MARK: - Display link (frame rate)

    #if os(macOS)
    @objc private func onFrame(_ link: CADisplayLink) {
        let ts = link.timestamp
        let targetDuration = link.duration > 0 ? link.duration : (1.0 / 120.0)
        let nominalTargetFPS = round(1.0 / targetDuration)
        if targetFPS != nominalTargetFPS { targetFPS = nominalTargetFPS }

        guard lastTimestamp > 0 else { lastTimestamp = ts; return }

        let dt = ts - lastTimestamp
        lastTimestamp = ts

        guard dt > 0.0005 && dt < 1.0 else { return }

        let frameMs = dt * 1000.0
        let instantFPS = min(130.0, 1.0 / dt)

        if dt > targetDuration * 1.35 {
            let dropped = max(1, Int(round((dt - targetDuration) / targetDuration)))
            droppedFrames += dropped
            if logHitchesToConsole && frameMs > (targetDuration * 1000.0 + 7.0) {
                print(String(format: "[FPS] ⚠️ Frame hitch: %.1fms (dropped %d frames, target %.1fms / %dHz)", frameMs, dropped, targetDuration * 1000.0, Int(nominalTargetFPS)))
            }
        }

        // `windowFrameTimes` is a plain (non-@Observable-relevant-read) local
        // buffer, so appending to it every frame is free of AttributeGraph
        // cost. `recentFrameTimes` is what the HUD's sparkline actually reads
        // — appending to *that* every frame, unconditionally, previously
        // meant the expanded HUD forced ~120 AttributeGraph invalidations/sec
        // of its own, on top of whatever the rest of the app was doing. The
        // "throttle SwiftUI publishing to ~5Hz" comment below only ever
        // applied to frameTimeMs/currentFPS/maxFrameTimeMs/minFPS; this array
        // (and droppedFrames further up) bypassed it entirely. Confirmed via
        // `sample`: the app was ~63% busy on the main thread at genuine rest
        // with the HUD's drawer expanded, dominated by AttributeGraph/SwiftUI
        // diffing — the instrument was measuring itself.
        windowFrameTimes.append(frameMs)
        if windowFrameTimes.count > windowCapacity { windowFrameTimes.removeFirst() }

        // Throttle SwiftUI publishing to ~5Hz
        if ts - lastUIUpdateTime >= 0.20 {
            lastUIUpdateTime = ts
            self.frameTimeMs = frameMs
            self.currentFPS = instantFPS
            self.recentFrameTimes = Array(windowFrameTimes.suffix(40))
            if !windowFrameTimes.isEmpty {
                let maxMs = windowFrameTimes.max() ?? frameMs
                self.maxFrameTimeMs = maxMs
                self.minFPS = min(nominalTargetFPS, max(1.0, 1000.0 / maxMs))
            }
        }
    }
    #endif

    // MARK: - Main-thread watcher

    /// Runs on a background thread. Every 8ms it dispatches a tiny block to the
    /// main queue and measures how long it takes to execute. If the main thread
    /// is busy (SwiftUI body eval, layout pass, heavy closure), the response will
    /// be delayed — and that delay shows up here, not in the display-link FPS.
    ///
    /// Threshold: >16ms = 1 missed frame at 60Hz, logged as a stall.
    // `nonisolated`: this runs on its own Thread, off the main actor by
    // definition. The local toolchain let a plain method be called from the
    // Thread closure; the CI toolchain (Swift 6.1) rejects the call as a
    // main-actor method used from a nonisolated context, which is the more
    // accurate reading.
    nonisolated private func runWatcher() {
        let pingInterval: Double = 0.008  // 8ms between pings
        let stallThreshold: Double = 16.0 // ms before it counts as a stall
        // Posting on a fixed 8ms timer regardless of whether the previous ping
        // was serviced yet turns the watcher into its own confound: if the main
        // queue falls even slightly behind, pings queue up and each one reports
        // wait-time-behind-the-others rather than main-thread business. Waiting
        // for this semaphore (signaled from the main-queue completion) before
        // sending the next ping makes the watcher self-clocking instead.
        let pingDone = DispatchSemaphore(value: 0)

        while !watcherShouldStop {
            let sent = CACurrentMediaTime()
            // DispatchQueue rather than a Task so the measurement stays what
            // it claims to be: time for the main queue to service a block.
            // The block runs on the main thread, which is the main actor;
            // `assumeIsolated` states that for the compiler.
            DispatchQueue.main.async { [weak self] in
                defer { pingDone.signal() }
                guard let self else { return }
                MainActor.assumeIsolated {
                let responseMs = (CACurrentMediaTime() - sent) * 1000.0

                // Full-resolution local buffer, appended every ping — cheap,
                // nothing observes it directly.
                self.windowMainThreadMs.append(responseMs)
                if self.windowMainThreadMs.count > 40 { self.windowMainThreadMs.removeFirst() }

                let now = CACurrentMediaTime()
                if now - self.lastMainThreadUIUpdateTime >= 0.20 {
                    self.lastMainThreadUIUpdateTime = now
                    self.recentMainThreadMs = self.windowMainThreadMs
                }

                if responseMs >= stallThreshold {
                    self.mainThreadStalls += 1
                    if responseMs > self.worstStallMs { self.worstStallMs = responseMs }
                    self.lastStallMs = responseMs

                    if self.logHitchesToConsole {
                        print(String(format: "[FPS] main thread stall: %.0fms (stall #%d)", responseMs, self.mainThreadStalls))
                    }
                } else {
                    // Decay lastStallMs so the HUD doesn't show stale values forever
                    if self.lastStallMs > 0 { self.lastStallMs = 0 }
                }
                }
            }
            _ = pingDone.wait(timeout: .now() + 1.0)
            if watcherShouldStop { break }
            Thread.sleep(forTimeInterval: pingInterval)
        }
    }
}

// MARK: - FPSHUDView

public struct FPSHUDView: View {
    @State private var monitor = FPSMonitor.shared
    @AppStorage("anicat_show_fps_hud") private var isVisible: Bool = false

    public init() {}

    private var fpsColor: Color {
        let is120 = monitor.targetFPS >= 100
        let gThresh = is120 ? 114.0 : 57.0
        let yThresh = is120 ? 90.0  : 45.0
        let oThresh = is120 ? 60.0  : 30.0
        if monitor.currentFPS >= gThresh { return SumiTheme.successLight }
        if monitor.currentFPS >= yThresh { return Color.yellow }
        if monitor.currentFPS >= oThresh { return SumiTheme.warning }
        return SumiTheme.dangerLight
    }

    /// Stall indicator color: green = no recent stall, orange = moderate, red = bad
    private var stallColor: Color {
        let worst = monitor.worstStallMs
        if worst == 0    { return SumiTheme.successLight }
        if worst < 33    { return Color.yellow }
        if worst < 100   { return SumiTheme.warning }
        return SumiTheme.dangerLight
    }

    public var body: some View {
        if isVisible {
            VStack(alignment: .trailing, spacing: 6) {
                // Main Pill
                HStack(spacing: 8) {
                    Button(action: {
                        withAnimation(.snappy(duration: 0.2)) { monitor.isExpanded.toggle() }
                    }) {
                        HStack(spacing: 6) {
                            // FPS indicator
                            Circle().fill(fpsColor).frame(width: 7, height: 7)

                            Text("\(Int(round(monitor.currentFPS))) FPS")
                                .sumiTabularMono(size: 11.5, weight: .bold)
                                .foregroundColor(SumiTheme.foreground)

                            Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))

                            Text(String(format: "%.1f ms", monitor.frameTimeMs))
                                .sumiTabularMono(size: 11)
                                .foregroundColor(SumiTheme.muted)

                            // Main thread stall indicator — this is the KEY signal
                            // for "120fps but still feels laggy"
                            Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))

                            HStack(spacing: 3) {
                                Circle().fill(stallColor).frame(width: 5, height: 5)
                                if monitor.mainThreadStalls > 0 {
                                    Text("\(monitor.mainThreadStalls)s")
                                        .sumiTabularMono(size: 10, weight: .semibold)
                                        .foregroundColor(stallColor)
                                } else {
                                    Text("MT")
                                        .sumiTabularMono(size: 10)
                                        .foregroundColor(SumiTheme.muted)
                                }
                            }

                            if monitor.droppedFrames > 0 {
                                Text("·").foregroundColor(SumiTheme.muted.opacity(0.5))
                                HStack(spacing: 3) {
                                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5))
                                    Text("\(monitor.droppedFrames)")
                                        .sumiTabularMono(size: 10.5, weight: .semibold)
                                }
                                .foregroundColor(SumiTheme.warning)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button(action: {
                        withAnimation(.snappy(duration: 0.2)) { isVisible = false }
                    }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(SumiTheme.muted)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Hide FPS HUD (Press ⌘⇧D to show again)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(.ultraThinMaterial)
                .background(SumiTheme.card.opacity(0.75))
                .clipShape(Capsule())
                .overlay(Capsule().stroke(SumiTheme.border, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)

                // Expanded Drawer
                if monitor.isExpanded {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("PERFORMANCE HUD")
                                .sumiTabularMono(size: 10, weight: .bold)
                                .foregroundColor(SumiTheme.indigo)
                            Spacer()
                            Text("\(Int(monitor.targetFPS))Hz Display")
                                .sumiTabularMono(size: 10)
                                .foregroundColor(SumiTheme.muted)
                        }

                        // Frame time sparkline
                        sparkline(
                            label: "FRAME TIMES (40 frames)",
                            values: monitor.recentFrameTimes,
                            targetMs: 1000.0 / max(1, monitor.targetFPS),
                            maxHeight: 28,
                            scale: { ms, target in ms / target * 10.0 }
                        )

                        // Main thread latency sparkline
                        sparkline(
                            label: "MAIN THREAD LATENCY (ms)",
                            values: monitor.recentMainThreadMs,
                            targetMs: 16.0,
                            maxHeight: 28,
                            scale: { ms, _ in ms / 16.0 * 10.0 }
                        )

                        VStack(spacing: 4) {
                            statRow(label: "Current FPS", value: "\(Int(round(monitor.currentFPS)))")
                            statRow(label: "Frame Time", value: String(format: "%.1f ms", monitor.frameTimeMs))
                            statRow(label: "Min FPS (Window)", value: "\(Int(round(monitor.minFPS)))")
                            statRow(label: "Max Frame Time", value: String(format: "%.1f ms", monitor.maxFrameTimeMs))
                            Divider().background(SumiTheme.border.opacity(0.5))
                            statRow(
                                label: "Main Thread Stalls",
                                value: "\(monitor.mainThreadStalls)",
                                highlight: monitor.mainThreadStalls > 0,
                                helpText: ">16ms response to 8ms ping"
                            )
                            statRow(
                                label: "Worst Stall",
                                value: monitor.worstStallMs > 0 ? String(format: "%.0f ms", monitor.worstStallMs) : "—",
                                highlight: monitor.worstStallMs >= 33
                            )
                            Divider().background(SumiTheme.border.opacity(0.5))
                            statRow(label: "Frame Drops / Hitches", value: "\(monitor.droppedFrames)", highlight: monitor.droppedFrames > 0)
                        }

                        HStack(spacing: 8) {
                            Button(action: { monitor.reset() }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Reset Stats")
                                }
                                .sumiTabularMono(size: 10, weight: .medium)
                                .foregroundColor(SumiTheme.foreground)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(SumiTheme.card)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(SumiTheme.border, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                            Spacer()
                            Text("⌘⇧D to toggle")
                                .sumiTabularMono(size: 9.5)
                                .foregroundColor(SumiTheme.muted.opacity(0.6))
                        }
                    }
                    .padding(12)
                    .frame(width: 250)
                    .background(.ultraThinMaterial)
                    .background(SumiTheme.card.opacity(0.92))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusMd).stroke(SumiTheme.border, lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 12, y: 5)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onAppear { monitor.start() }
            .onDisappear { monitor.stop() }
        }
    }

    @ViewBuilder
    private func sparkline(
        label: String,
        values: [Double],
        targetMs: Double,
        maxHeight: Double,
        scale: @escaping (Double, Double) -> Double
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .sumiTabularMono(size: 9)
                .foregroundColor(SumiTheme.muted.opacity(0.7))

            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Array(values.enumerated()), id: \.offset) { _, ms in
                    let h = min(maxHeight, max(3.0, scale(ms, targetMs)))
                    let isDrop = ms > targetMs * 1.35
                    let isSevere = ms > targetMs * 2.0
                    RoundedRectangle(cornerRadius: 1)
                        .fill(isSevere ? SumiTheme.dangerLight : (isDrop ? SumiTheme.warning : SumiTheme.successLight.opacity(0.8)))
                        .frame(width: 3.5, height: h)
                }
            }
            .frame(height: maxHeight, alignment: .bottom)
            .padding(4)
            .background(SumiTheme.background.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    private func statRow(label: String, value: String, highlight: Bool = false, helpText: String? = nil) -> some View {
        HStack {
            if let helpText {
                Text(label).sumiTabularMono(size: 10).foregroundColor(SumiTheme.muted)
                Text(helpText).sumiTabularMono(size: 8.5).foregroundColor(SumiTheme.muted.opacity(0.55))
            } else {
                Text(label).sumiTabularMono(size: 10).foregroundColor(SumiTheme.muted)
            }
            Spacer()
            Text(value)
                .sumiTabularMono(size: 10.5, weight: .semibold)
                .foregroundColor(highlight ? SumiTheme.warning : SumiTheme.foreground)
        }
    }
}
