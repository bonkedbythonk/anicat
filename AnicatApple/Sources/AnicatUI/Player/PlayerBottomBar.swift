import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PlayerBottomBar: View {
    @Bindable var controller: PlayerController
    @AppStorage("anicat_ambient_glow") private var ambientGlowEnabled: Bool = true
    /// The hairline exists to separate a bar sitting in solid letterbox
    /// black from the picture above it. When the bar overlays the picture
    /// (a 16:9 window, gradient scrim) the same line reads as a white
    /// stripe across the video at the top of the fade, so it is drawn only
    /// when the bar is fully inside the letterbox gap.
    var showsHairline: Bool = true

    private var volumeIcon: String {
        if controller.isMuted || controller.volume == 0 { return "speaker.slash.fill" }
        if controller.volume < 0.5 { return "speaker.wave.1.fill" }
        return "speaker.wave.2.fill"
    }

    private var rotateHelpText: String {
        switch controller.sidewaysState {
            case 1: return "Rotate: 90 CW (Shift+V)"
            case 2: return "Rotate: 90 CCW (Shift+V)"
            default: return "Rotate Video (Shift+V)"
        }
    }

    /// The scrubber, extracted so it can sit in the middle of the single
    /// transport row below instead of its own stacked row above it — the
    /// two-row layout this used to be needed more vertical height than the
    /// video's own letterbox gap reliably has, and got clipped at the
    /// bottom in windowed sizes with a smaller gap.
    /// Where the pointer is along the bar, 0...1, or nil when it is not over
    /// it. The tooltip is the whole of what this drives; scrubbing has its
    /// own drag state and does not read this.
    @State private var hoverFraction: Double?

    /// Where the last scrub tick put the playhead, so the next one can tell
    /// which boundaries it swept over. Nil outside a drag: a stale value
    /// from the previous scrub would fire against every boundary between
    /// the two, which is most of them.
    @State private var lastScrubTime: Double?

    @State private var tooltipWidth: CGFloat = 0

    /// Time, and the chapter that time is inside. There is no frame preview
    /// here and deliberately so: the only way to render one without seeking
    /// the instance that is playing is a second libmpv on the same stream
    /// URL, which is a second HTTP client pulling pieces from the range
    /// server. Core pins exactly one playing file and keeps two selected
    /// files at a time (`SELECTED_FILES_KEPT`), already spent on the playing
    /// episode and the N+1 preload; a preview client requesting pieces
    /// nobody is watching is the mid-playback eviction that pin exists to
    /// prevent, and core cannot tell those reads are speculative.
    @ViewBuilder
    private func seekTooltip(width: CGFloat) -> some View {
        if let hoverFraction, controller.duration > 0 {
            let time = hoverFraction * controller.duration
            let chapter = PlayerChapters.chapter(at: time, in: controller.chapters)
            VStack(spacing: 2) {
                Text(PlayerController.formatTimestamp(time))
                    .sumiTabularMono(size: 11, weight: .semibold)
                    .foregroundColor(PlayerChrome.foreground)
                if let chapter, !chapter.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(chapter.title)
                        .font(.system(size: 10))
                        .foregroundColor(PlayerChrome.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .fixedSize()
            // Sized to its text and drawn as glass: the fixed-width
            // near-black slab read as a bar sitting on the picture.
            .playerScrim(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .allowsHitTesting(false)
            // Clamped to the bar rather than centred on the pointer at the
            // ends, where centring would hang it off the window.
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { tooltipWidth = $0 }
            // Centred on the pointer by the tooltip's real width. It used a
            // fixed 150 after the tooltip became sized to its text (~50 pt
            // for "04:21"), so it sat well left of the mouse.
            .offset(
                x: min(max(hoverFraction * width - tooltipWidth / 2, 0), max(width - tooltipWidth, 0)),
                y: -46
            )
        }
    }

    /// Whether a scrub from `from` to `to` swept over a chapter mark or the
    /// edge of a skip window — the marks the bar already draws, so the tick
    /// lands on something the viewer can see. Direction-agnostic: dragging
    /// back over the opening is the same boundary as dragging forward over
    /// it.
    private func crossesBoundary(from: Double, to: Double) -> Bool {
        guard controller.duration > 0, from != to else { return false }
        let lower = min(from, to)
        let upper = max(from, to)
        let boundaries = controller.chapters.map(\.time)
            + controller.skipWindows.flatMap { [$0.start, $0.end] }
        return boundaries.contains { $0 > lower && $0 <= upper }
    }

    /// The bar is 4 pt at rest and 6 pt with a knob while the pointer is
    /// over it or a scrub is in progress, so the thing about to be dragged
    /// announces itself before the drag; a constant 4 pt line gave no cue
    /// that it was live at all.
    private var scrubberIsLive: Bool {
        hoverFraction != nil || controller.isScrubbing
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let thickness: CGFloat = scrubberIsLive ? 6 : 4
            let playhead = geo.size.width * CGFloat(controller.progressFraction)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: thickness)
                // What is already fetched, under the played part: the
                // viewer can see how far a seek can land without a stall.
                if controller.duration > 0 {
                    ForEach(Array(controller.bufferedRanges.enumerated()), id: \.offset) { _, span in
                        let x0 = geo.size.width * CGFloat(min(max(span.start / controller.duration, 0), 1))
                        let x1 = geo.size.width * CGFloat(min(max(span.end / controller.duration, 0), 1))
                        Capsule()
                            .fill(Color.white.opacity(0.28))
                            .frame(width: max(x1 - x0, 0), height: thickness)
                            .offset(x: x0)
                    }
                    .allowsHitTesting(false)
                    .animation(.sumi(.tab), value: controller.bufferedRanges)
                }
                Capsule()
                    .fill(SumiTheme.indigo)
                    .frame(width: playhead, height: thickness)
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                    .scaleEffect(scrubberIsLive ? 1 : 0.01)
                    .opacity(scrubberIsLive ? 1 : 0)
                    .offset(x: playhead - 6)
                    .allowsHitTesting(false)
                // Chapter marks. 1pt, over the track rather than notched out
                // of it: a gap in the filled bar would read as buffering
                // rather than as a boundary. Drawn only where mpv reported
                // chapters, so nothing changes for a release without them.
                if controller.duration > 0 {
                    ForEach(controller.chapters) { chapter in
                        Rectangle()
                            .fill(Color.white.opacity(0.55))
                            .frame(width: 1, height: 8)
                            .offset(x: geo.size.width * CGFloat(min(max(chapter.time / controller.duration, 0), 1)))
                    }
                    .allowsHitTesting(false)
                }
            }
            .frame(maxHeight: .infinity)
            .animation(.snappy(duration: 0.22), value: scrubberIsLive)
            .contentShape(Rectangle())
            // No drag on tvOS; `TVPlayerView` seeks from the remote's ring
            // and never mounts this scrubber.
            #if !os(tvOS)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.isScrubbing = true
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        let target = Double(fraction) * controller.duration
                        if let previous = lastScrubTime, crossesBoundary(from: previous, to: target) {
                            AppHaptics.seekSnap()
                        }
                        lastScrubTime = target
                        controller.currentTime = target
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        let target = Double(fraction) * controller.duration
                        controller.isScrubbing = false
                        lastScrubTime = nil
                        controller.seek(to: target)
                    }
            )
            #endif
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    hoverFraction = min(max(point.x / geo.size.width, 0), 1)
                case .ended:
                    hoverFraction = nil
                }
            }
            #endif
            .overlay(alignment: .topLeading) {
                seekTooltip(width: geo.size.width)
            }
        }
    }

    var body: some View {
        // 40 pt hit targets on every icon, glyphs still 14 pt. At 28 pt the
        // owner still had to "be very precise"; the row spacing drops to 2 so
        // the bar is barely wider than it was, and 40 fits the 48 pt minimum
        // bar height with room to spare.
        HStack(spacing: 2) {
            // Previous Episode
            Button(action: { controller.previousEpisode() }) {
                Image(systemName: "backward.end.fill")
                .font(.system(size: 14))
                .foregroundColor(controller.hasPreviousEpisode ? PlayerChrome.foreground.opacity(0.8) : PlayerChrome.muted.opacity(0.4))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .disabled(!controller.hasPreviousEpisode)
            .help("Previous Episode (P)")
            .accessibilityLabel("Previous Episode (P)")

            // Play / Pause — the one filled, colored control in the row:
            // everything else here is a bare icon, and a transport bar
            // with no visual hierarchy at all read as flatter than the
            // rest of the app, which always gives its one primary action
            // real weight (the detail page's "Play Episode" button, the
            // AniSkip pill).
            Button(action: { controller.togglePlayPause() }) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.snappy(duration: 0.25), value: controller.isPlaying)
                    // White on a faint disc, not a filled indigo circle: with
                    // the big paused glyph and the volume slider also indigo
                    // the bar read as "a bit too much" blue (owner).
                    .foregroundColor(PlayerChrome.foreground)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Color.white.opacity(0.16)))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help(controller.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            // Seek -5s
            Button(action: { controller.seekRelative(by: -5) }) {
                Image(systemName: "gobackward.5")
                .font(.system(size: 15))
                .foregroundColor(PlayerChrome.foreground.opacity(0.8))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Back 5 seconds")
            .accessibilityLabel("Back 5 seconds")

            // Seek +5s
            Button(action: { controller.seekRelative(by: 5) }) {
                Image(systemName: "goforward.5")
                .font(.system(size: 15))
                .foregroundColor(PlayerChrome.foreground.opacity(0.8))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help("Forward 5 seconds")
            .accessibilityLabel("Forward 5 seconds")

            // Next Episode
            Button(action: { controller.nextEpisode() }) {
                Image(systemName: "forward.end.fill")
                .font(.system(size: 14))
                .foregroundColor(controller.hasNextEpisode ? PlayerChrome.foreground.opacity(0.8) : PlayerChrome.muted.opacity(0.4))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .disabled(!controller.hasNextEpisode)
            .help("Next Episode (N)")
            .accessibilityLabel("Next Episode (N)")

            // Time Display
            HStack(spacing: 4) {
                Text(controller.formattedCurrentTime)
                .foregroundColor(PlayerChrome.foreground)
                Text("/")
                .foregroundColor(PlayerChrome.muted)
                Text(controller.formattedDuration)
                .foregroundColor(PlayerChrome.muted)
            }
            .sumiTabularMono(size: 11.5)
            .fixedSize()
            // The row packs at 2pt for the icons' sake, which left the
            // duration touching the start of the bar.
            .padding(.leading, 4)
            .padding(.trailing, 12)

            // Progress bar fills the middle, between the transport cluster
            // (left) and the options cluster (right) rather than a whole
            // separate row of its own.
            scrubber
                .frame(height: 12)
                .frame(maxWidth: .infinity)

            // Volume
                HStack(spacing: 6) {
                    Button(action: { controller.toggleMute() }) {
                        Image(systemName: volumeIcon)
                        .font(.system(size: 14))
                        .foregroundColor(PlayerChrome.foreground.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                    .help(controller.isMuted ? "Unmute (M)" : "Mute (M)")
                    .accessibilityLabel(controller.isMuted ? "Unmute (M)" : "Mute (M)")

                    // `Slider` is not in the tvOS SDK; the TV's volume is
                    // the television's own.
                    #if !os(tvOS)
                    Slider(value: Binding(
                            get: { controller.isMuted ? 0 : controller.volume },
                            set: { controller.setVolume($0) }
                        ), in: 0...1)
                    .frame(width: 80)
                    .tint(PlayerChrome.foreground.opacity(0.85))
                    #endif
                }

                // Upscaling (Anime4K)
                Button(action: { controller.toggleAnime4K() }) {
                    Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(controller.isAnime4KEnabled ? SumiTheme.indigo : PlayerChrome.foreground.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(controller.isAnime4KEnabled ? "Upscaling: On" : "Upscaling: Off")
                .accessibilityLabel(controller.isAnime4KEnabled ? "Upscaling: On" : "Upscaling: Off")

                // Ambient glow. The same key Settings writes; the player is
                // where the effect is judged, so the switch lives here too.
                Button(action: {
                    ambientGlowEnabled.toggle()
                    controller.flashHUD(ambientGlowEnabled ? "Ambient glow on" : "Ambient glow off", symbol: "light.max")
                }) {
                    Image(systemName: ambientGlowEnabled ? "light.max" : "light.min")
                    .font(.system(size: 14))
                    .foregroundColor(ambientGlowEnabled ? SumiTheme.indigo : PlayerChrome.foreground.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(ambientGlowEnabled ? "Ambient glow: On" : "Ambient glow: Off")
                .accessibilityLabel(ambientGlowEnabled ? "Ambient glow: On" : "Ambient glow: Off")

                // Rotate 90 degrees (off / CW / CCW)
                Button(action: { controller.cycleSideways() }) {
                    Image(systemName: "rotate.right")
                    .font(.system(size: 14))
                    .foregroundColor(controller.sidewaysState != 0 ? SumiTheme.indigo : PlayerChrome.foreground.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(rotateHelpText)
                .accessibilityLabel(rotateHelpText)

                // Fullscreen. The whole control is compiled out on iOS
                // rather than guarding only its action: there is no window
                // to toggle there, and a button that reliably does nothing
                // reads as a broken player rather than a missing feature.
                #if os(macOS)
                Button(action: {
                        if let window = AppWindow.main ?? NSApp.keyWindow {
                            AppWindow.setToolbarVisible(false)
                            FullScreenGuard.toggle(on: window)
                        }
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14))
                    .foregroundColor(PlayerChrome.foreground.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help("Toggle Fullscreen (F)")
                .accessibilityLabel("Toggle Fullscreen (F)")
                #endif
        }
        // Flat, not a floating panel — same reasoning as `topBar`: this bar
        // sits in the video's own bottom letterbox gap (already solid
        // black), so the material/shadow "panel" treatment it used to have
        // added nothing but a border and padding. A single top hairline is
        // what actually separates it from the picture.
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            if showsHairline {
                Rectangle()
                    .fill(SumiTheme.border.opacity(0.6))
                    .frame(height: 1)
            }
        }
    }
}
