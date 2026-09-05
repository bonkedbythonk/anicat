import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct PlayerView: View {
    @Bindable public var controller: PlayerController
    public let streamURL: URL?
    public let onClose: () -> Void
    /// Backgrounds this view without stopping playback — see
    /// `AppModel.isPlayerMinimized`. Distinct from `onClose`, which actually
    /// tears playback down.
    public let onMinimize: () -> Void
    /// Whether this view is currently shrunk to the corner mini-player.
    /// `MpvMetalSurface` must stay mounted at the exact same call site
    /// regardless of this — SwiftUI tears down (and, per `dismantleNSView`'s
    /// `stop()`, actually stops playback) an `NSViewRepresentable` that
    /// moves between different branches of an `if`/`else`, even when both
    /// branches look the same on screen. Minimizing used to wrap the whole
    /// player in `if !isPlayerMinimized` at the call site, which is exactly
    /// that mistake: it looked like "hide the player" but was actually
    /// "destroy and recreate mpv every time", which is why minimizing read
    /// as the stream just exiting. Only the *frame* (size/position/corner
    /// radius) and the surrounding chrome change here; the video surface
    /// itself is unconditional.
    public let isMinimized: Bool
    public let onRestore: () -> Void
    @State private var showInfoMenu = false
    @State private var showEpisodeList = false
    @State private var audioTrackLabel = "-"
    @State private var subtitleTrackLabel = "-"
    @AppStorage("anicat_sub_dub") private var storedSubDub: String = "Subtitled"
    /// Set when the loaded release has no track in the language just asked
    /// for. The preference still changed — it is what the next resolve
    /// searches with — but this episode's audio did not, and saying nothing
    /// is how the old control read as broken.
    @State private var audioSwitchNote: String?

    private static let miniSize = CGSize(width: 320, height: 180)

    public init(
        controller: PlayerController,
        streamURL: URL? = nil,
        onClose: @escaping () -> Void,
        onMinimize: @escaping () -> Void = {},
        isMinimized: Bool = false,
        onRestore: @escaping () -> Void = {}
    ) {
        self.controller = controller
        self.streamURL = streamURL
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.isMinimized = isMinimized
        self.onRestore = onRestore
    }

    /// The video's actual on-screen rect once letterboxed/pillarboxed to fit
    /// `container` — a MacBook's screen aspect ratio essentially never
    /// matches the video's, so the visible frame is a sub-rect of the window,
    /// not the window itself. Overlay chrome padded from the window's own
    /// edges instead of this rect's used to sit half over a black bar.
    /// `nil` aspect ratio (mpv hasn't reported the decoded size yet) falls
    /// back to the full container rather than leaving the overlay collapsed.
    static func aspectFitRect(in container: CGSize, aspectRatio: Double?) -> CGRect {
        guard let aspectRatio, aspectRatio > 0, container.width > 0, container.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let containerAspect = container.width / container.height
        let size: CGSize
        if aspectRatio > containerAspect {
            // Video is relatively wider than the window — letterboxed
            // (bars top/bottom), full width.
            size = CGSize(width: container.width, height: container.width / aspectRatio)
        } else {
            // Pillarboxed (bars left/right), full height.
            size = CGSize(width: container.height * aspectRatio, height: container.height)
        }
        let origin = CGPoint(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Minimum chrome heights, used only when the natural letterbox gap is
    /// smaller than this (most obviously: zero, an exactly 16:9 video on an
    /// exactly 16:9 window/display — a MacBook's own screen is taller than
    /// 16:9 so this never bites there, but an external monitor or a resized
    /// window can genuinely match). Below this the video's height (and, to
    /// keep its aspect ratio, its width too — an unavoidable side effect,
    /// not a bug) shrinks by just the deficit so the chrome still has room:
    /// "prefer the free letterbox space, only take from the video when
    /// there truly isn't any" rather than either always reserving fixed
    /// space (shrinks the video needlessly on the common MacBook case) or
    /// never reserving any (chrome disappears entirely at exactly 16:9).
    private static let minTopBarHeight: CGFloat = 48
    private static let minBottomBarHeight: CGFloat = 64

    public var body: some View {
        GeometryReader { windowGeo in
        let windowSize = windowGeo.size
        // What the video would render at if given the *whole* window with
        // no chrome reservation at all — this is what tells us how big the
        // natural letterbox gap actually is, independent of whatever we end
        // up constraining `MpvMetalSurface` to below.
        let naturalRect = Self.aspectFitRect(in: windowSize, aspectRatio: controller.videoAspectRatio)
        let topGap = max(naturalRect.minY, Self.minTopBarHeight)
        let bottomGap = max(windowSize.height - naturalRect.maxY, Self.minBottomBarHeight)
        let videoBandHeight = max(0, windowSize.height - topGap - bottomGap)
        // The video's actual rect once it's letterboxed/pillarboxed a second
        // time *within* the reduced band (only different from `naturalRect`
        // when the band's own aspect ratio no longer matches the video's —
        // i.e. exactly the deficit case above) — this, not `naturalRect`, is
        // where things actually laid out against the video (the AniSkip
        // pill) need to sit.
        let videoRect = Self.aspectFitRect(
            in: CGSize(width: windowSize.width, height: videoBandHeight),
            aspectRatio: controller.videoAspectRatio
        ).offsetBy(dx: 0, dy: topGap)
        let miniCenter = CGPoint(
            x: windowSize.width - Self.miniSize.width / 2 - 24,
            y: windowSize.height - Self.miniSize.height / 2 - 24
        )
        ZStack {
            // Background Canvas (Black) — only when full-size. Painting this
            // unconditionally would black out the entire window even while
            // minimized, defeating the whole point of minimizing: seeing and
            // using the rest of the app behind the small mini-player box.
            if !isMinimized {
                Color.black
                    .ignoresSafeArea()
            }

            #if os(macOS)
            // Click handling lives in MpvRenderView.mouseDown, not a SwiftUI
            // tap gesture — stacking onTapGesture(count: 1) alongside
            // onTapGesture(count: 2) makes SwiftUI hold every single click
            // for ~300ms to see whether a second one is coming before it
            // fires, which read as exactly the "click has a lot of delay"
            // lag reported against this screen. AppKit's mouseDown already
            // carries `clickCount` with no such wait.
            //
            // Frame/position/corner-radius vary with `isMinimized`, but this
            // is always the same call site — see the doc comment on
            // `isMinimized` for why that distinction is exactly what keeps
            // mpv alive across a minimize/restore instead of restarting it.
            MpvMetalSurface(controller: controller, streamURL: streamURL)
                .ignoresSafeArea(isMinimized ? [] : .all)
                .frame(
                    width: isMinimized ? Self.miniSize.width : windowSize.width,
                    height: isMinimized ? Self.miniSize.height : videoBandHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: isMinimized ? 12 : 0))
                .shadow(color: .black.opacity(isMinimized ? 0.45 : 0), radius: isMinimized ? 18 : 0, y: isMinimized ? 8 : 0)
                .position(isMinimized ? miniCenter : CGPoint(x: windowSize.width / 2, y: topGap + videoBandHeight / 2))
                .animation(.easeInOut(duration: 0.28), value: isMinimized)
            #else
            VStack {
                Spacer()
                Image(systemName: "film")
                    .font(.system(size: 64))
                    .foregroundColor(SumiTheme.muted.opacity(0.4))
                Text(controller.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground.opacity(0.7))
                    .padding(.top, 8)
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                controller.togglePlayPause()
            }
            #endif

            if !isMinimized {
                // Buffering Spinner — covers both the initial resolve-to-first-frame
                // stretch and any mid-playback stall, so the black canvas never
                // sits with nothing on screen while mpv is still working.
                if controller.isBuffering {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.4)
                            .tint(SumiTheme.indigo)
                        Text(bufferingLabel)
                            .sumiTabularMono(size: 12)
                            .foregroundColor(SumiTheme.muted)
                    }
                    .transition(.opacity)
                }

                // Paused Overlay Icon
                if !controller.isBuffering && !controller.isPlaying && controller.areControlsVisible {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 72))
                        .foregroundColor(SumiTheme.indigo.opacity(0.9))
                        .transition(.scale.combined(with: .opacity))
                }

                // Top/bottom chrome, fit exactly to `topGap`/`bottomGap`
                // (computed above, already `max(natural, minimum)`) rather
                // than a fixed guessed height or a plain edge-pinned overlay
                // — a MacBook's screen is taller than 16:9 content, so a
                // natural gap usually already exists and this puts the
                // chrome inside it precisely instead of approximately; the
                // minimum floor is what keeps it visible at all on a window
                // whose aspect ratio happens to exactly match the video's,
                // where the natural gap is zero.
                // The gap's own size doesn't depend on whether controls are
                // shown (the video's letterboxing is constant) — only the
                // content drawn inside it does, so the height is reserved
                // unconditionally and the bar/scrubber just fades in and out.
                VStack(spacing: 0) {
                    Group {
                        if controller.areControlsVisible {
                            topBar.padding(.horizontal, SumiTheme.spaceLg)
                        }
                    }
                    .frame(height: topGap)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)

                    Spacer(minLength: 0)

                    Group {
                        if controller.areControlsVisible {
                            PlayerBottomBar(controller: controller).padding(.horizontal, SumiTheme.spaceLg)
                        }
                    }
                    .frame(height: bottomGap)
                    .frame(maxWidth: .infinity)
                    .background(Color.black)
                }
                .animation(.smooth, value: controller.areControlsVisible)

                // AniSkip Floating Action Pill (Bottom Right). Kept floating
                // over the video itself, unlike the rest of the chrome — it's a
                // contextual action tied to what's playing right now, meant to
                // be seen right where the eye already is, the way
                // Netflix/Crunchyroll place it.
                if controller.isIntroActive {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button(action: {
                                withAnimation(.snappy) {
                                    controller.skipIntro()
                                }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 12))
                                    Text("Skip Opening")
                                        .sumiTabularMono(size: 12, weight: .bold)
                                }
                                .foregroundColor(SumiTheme.background)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(SumiTheme.indigo)
                                .clipShape(Capsule())
                                .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                            }
                            .buttonStyle(.sumiPressable)
                            .padding(.trailing, 24)
                            .padding(.bottom, controller.areControlsVisible ? 100 : 24)
                        }
                    }
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .animation(.smooth, value: controller.isIntroActive)
                }
            } else {
                // Mini-player chrome: a transparent tap-to-restore catcher
                // over the whole small video (it sits above `MpvMetalSurface`
                // in this ZStack, so it intercepts clicks before AppKit's own
                // mouseDown-toggles-play/pause reaches the view underneath —
                // exactly what should happen while minimized, not another
                // play/pause toggle) plus a small close button.
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture(perform: onRestore)
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(.white)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                }
                .frame(width: Self.miniSize.width, height: Self.miniSize.height)
                .position(miniCenter)
            }
        }
        .background(isMinimized ? Color.clear : Color.black)
        .ignoresSafeArea(isMinimized ? [] : .all)
        #if os(macOS)
        .toolbar(.hidden, for: .windowToolbar)
        .onContinuousHover { _ in
            controller.showControlsBriefly()
        }
        .onDisappear {
            controller.cancelAutohide()
        }
        .onChange(of: showEpisodeList || showInfoMenu) { _, isOpen in
            controller.isMenuOpen = isOpen
            if isOpen {
                controller.areControlsVisible = true
                NSCursor.setHiddenUntilMouseMoves(false)
            } else {
                controller.showControlsBriefly()
            }
        }
        #endif
        .animation(.smooth, value: controller.areControlsVisible)
        .animation(.snappy, value: controller.isBuffering)
        }
    }

    // The torrent pre-buffer gate this waits on is a seconds-scale step in
    // core, not something the player can shorten — showing a percentage
    // (once mpv has reported one) is what keeps that wait from reading as hung.
    private var bufferingLabel: String {
        if let percent = controller.bufferingPercent, percent > 0 {
            return "Buffering \(percent)%"
        }
        return "Buffering…"
    }

    // MARK: - Top Bar
    //
    // A plain flat row, not a floating capsule: this bar sits in the video's
    // own natural letterbox gap (see `PlayerView.body`'s `topGap`), which is
    // already solid black — a translucent "glass" pill blurring pure black
    // is indistinguishable from a flat one, so the capsule/shadow treatment
    // this used to have was pure dead weight once the chrome moved off the
    // video and into the gap. A single hairline at the bottom is what
    // separates it from the picture instead.
    private var topBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Button(action: onClose) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.sumiPressable)

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Text("Episode \(controller.episodeNumber)")
                        .sumiTabularMono(size: 10, weight: .medium)
                        .foregroundColor(SumiTheme.indigo)
                    if !controller.episodeTitle.isEmpty {
                        Text("·")
                            .foregroundColor(SumiTheme.muted.opacity(0.5))
                        Text(controller.episodeTitle)
                            .font(.system(size: 10.5))
                            .foregroundColor(SumiTheme.muted)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: 420, alignment: .leading)

            Spacer(minLength: 12)

            HStack(spacing: 2) {
                // Minimize — backgrounds playback so the rest of the app is
                // reachable again, rather than the player sitting over
                // everything until it's stopped outright.
                Button(action: onMinimize) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help("Minimize Player")

                // Auto-Play Next
                Button(action: { controller.toggleAutoPlayNext() }) {
                    Image(systemName: controller.autoPlayNextEnabled ? "play.square.stack.fill" : "play.square.stack")
                        .font(.system(size: 13))
                        .foregroundColor(controller.autoPlayNextEnabled ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help(controller.autoPlayNextEnabled ? "Auto-Play Next: On" : "Auto-Play Next: Off")

                // Auto-Skip Intro/Outro — Settings has had a toggle for this
                // since AniSkip was built, but nothing in the player itself
                // did, which read as "the feature doesn't have a switch" even
                // though one existed a page away.
                Button(action: { controller.toggleAutoSkip() }) {
                    Image(systemName: controller.autoSkipEnabled ? "forward.circle.fill" : "forward.circle")
                        .font(.system(size: 13))
                        .foregroundColor(controller.autoSkipEnabled ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help(controller.autoSkipEnabled ? "Auto-Skip Intro/Outro: On" : "Auto-Skip Intro/Outro: Off")

                // Episode List
                if !controller.episodeList.isEmpty {
                    Button(action: { showEpisodeList = true }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground.opacity(0.85))
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.sumiPressable)
                    .help("Episodes")
                    .popover(isPresented: $showEpisodeList, arrowEdge: .bottom) {
                        episodeListMenu
                    }
                }

                // Info / More Options
                Button(action: {
                    refreshTrackLabels()
                    showInfoMenu = true
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help("Info & Options")
                .popover(isPresented: $showInfoMenu, arrowEdge: .bottom) {
                    infoMenu
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(SumiTheme.border.opacity(0.6))
                .frame(height: 1)
        }
    }

    // MARK: - Episode List Menu
    private var episodeListMenu: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(controller.episodeList, id: \.number) { episode in
                        let isCurrent = episode.number == controller.episodeNumber
                        Button(action: {
                            showEpisodeList = false
                            controller.selectEpisode(episode.number)
                        }) {
                            HStack(spacing: 10) {
                                Text("\(episode.number)")
                                    .sumiTabularMono(size: 12, weight: isCurrent ? .bold : .regular)
                                    .foregroundColor(isCurrent ? SumiTheme.indigo : SumiTheme.muted)
                                    .frame(width: 28, alignment: .trailing)
                                Text(episode.title.isEmpty ? "Episode \(episode.number)" : episode.title)
                                    .font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                                    .foregroundColor(isCurrent ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.8))
                                    .lineLimit(1)
                                Spacer()
                                if episode.isWatched {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10))
                                        .foregroundColor(SumiTheme.muted)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(isCurrent ? SumiTheme.indigo.opacity(0.12) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.sumiPressable)
                        .id(episode.number)
                    }
                }
                .padding(8)
            }
            .frame(width: 280, height: 360)
            .onAppear {
                proxy.scrollTo(controller.episodeNumber, anchor: .center)
            }
        }
    }

    // MARK: - Info Menu
    private var infoMenu: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title)
                    .font(.system(size: 13, weight: .semibold))
                Text("Episode \(controller.episodeNumber) · \(controller.formattedCurrentTime) / \(controller.formattedDuration)")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
            }

            Divider()

            infoMenuRow(label: "Audio", value: audioTrackLabel) {
                controller.onCycleAudioTrack?()
                refreshTrackLabels()
            }
            infoMenuRow(label: "Subtitles", value: subtitleTrackLabel) {
                controller.onCycleSubtitleTrack?()
                refreshTrackLabels()
            }

            // The cycle button above steps to whatever track is next, which
            // on a dual-audio release is not a way to ask for a language.
            // This row is the actual Sub/Dub choice, shared with Settings
            // and the detail page through `anicat_sub_dub`.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Sub / Dub")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.muted)
                    Spacer()
                    ForEach(["Subtitled", "Dubbed"], id: \.self) { option in
                        Button {
                            let wantsDub = option == "Dubbed"
                            storedSubDub = option
                            let switched = controller.onSelectAudioLanguage?(wantsDub) ?? false
                            audioSwitchNote = switched
                                ? nil
                                : "No \(wantsDub ? "English" : "Japanese") audio track in this release — applies from the next episode."
                            refreshTrackLabels()
                        } label: {
                            Text(option == "Dubbed" ? "Dub" : "Sub")
                                .sumiTabularMono(size: 11, weight: storedSubDub == option ? .bold : .regular)
                                .foregroundColor(storedSubDub == option ? SumiTheme.indigo : SumiTheme.foreground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(storedSubDub == option ? SumiTheme.indigo.opacity(0.15) : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
                if let audioSwitchNote {
                    Text(audioSwitchNote)
                        .font(.system(size: 10.5))
                        .foregroundColor(SumiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Speed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SumiTheme.muted)
                HStack(spacing: 6) {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button(action: { controller.setPlaybackRate(rate) }) {
                            Text(speedLabel(rate))
                                .sumiTabularMono(size: 11, weight: controller.playbackRate == rate ? .bold : .regular)
                                .foregroundColor(controller.playbackRate == rate ? SumiTheme.indigo : SumiTheme.foreground)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(controller.playbackRate == rate ? SumiTheme.indigo.opacity(0.15) : Color.clear)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%.2gx", rate)
    }

    private func infoMenuRow(label: String, value: String, onCycle: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(SumiTheme.muted)
            Spacer()
            Text(value)
                .sumiTabularMono(size: 12)
            Button(action: onCycle) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
            }
            .buttonStyle(.sumiPressable)
            .help("Cycle \(label.lowercased())")
        }
    }

    /// Read once now and once after a beat: `mpv_command` returning is not
    /// the track reconfig having finished, so the immediate read reports the
    /// track that was playing *before* the switch and the row looked stuck
    /// on the old language.
    private func refreshTrackLabels() {
        readTrackLabels()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            readTrackLabels()
        }
    }

    private func readTrackLabels() {
        guard let info = controller.onFetchTrackInfo?() else { return }
        audioTrackLabel = info.audio
        subtitleTrackLabel = info.subtitle
    }
}

private struct PlayerBottomBar: View {
    @Bindable var controller: PlayerController

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
    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
                Capsule()
                    .fill(SumiTheme.indigo)
                    .frame(width: geo.size.width * CGFloat(controller.progressFraction), height: 4)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        controller.isScrubbing = true
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        controller.currentTime = Double(fraction) * controller.duration
                    }
                    .onEnded { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        let target = Double(fraction) * controller.duration
                        controller.isScrubbing = false
                        controller.seek(to: target)
                    }
            )
        }
    }

    var body: some View {
        HStack(spacing: 16) {
            // Previous Episode
            Button(action: { controller.previousEpisode() }) {
                Image(systemName: "backward.end.fill")
                .font(.system(size: 14))
                .foregroundColor(controller.hasPreviousEpisode ? SumiTheme.foreground.opacity(0.8) : SumiTheme.muted.opacity(0.4))
            }
            .buttonStyle(.sumiPressable)
            .disabled(!controller.hasPreviousEpisode)
            .help("Previous Episode (P)")

            // Play / Pause — the one filled, colored control in the row:
            // everything else here is a bare icon, and a transport bar
            // with no visual hierarchy at all read as flatter than the
            // rest of the app, which always gives its one primary action
            // real weight (the detail page's "Play Episode" button, the
            // AniSkip pill).
            Button(action: { controller.togglePlayPause() }) {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(SumiTheme.background)
                    .frame(width: 30, height: 30)
                    .background(SumiTheme.indigo)
                    .clipShape(Circle())
            }
            .buttonStyle(.sumiPressable)

            // Seek -10s
            Button(action: { controller.seekRelative(by: -10) }) {
                Image(systemName: "gobackward.10")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
            }
            .buttonStyle(.sumiPressable)

            // Seek +10s
            Button(action: { controller.seekRelative(by: 10) }) {
                Image(systemName: "goforward.10")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
            }
            .buttonStyle(.sumiPressable)

            // Next Episode
            Button(action: { controller.nextEpisode() }) {
                Image(systemName: "forward.end.fill")
                .font(.system(size: 14))
                .foregroundColor(controller.hasNextEpisode ? SumiTheme.foreground.opacity(0.8) : SumiTheme.muted.opacity(0.4))
            }
            .buttonStyle(.sumiPressable)
            .disabled(!controller.hasNextEpisode)
            .help("Next Episode (N)")

            // Time Display
            HStack(spacing: 4) {
                Text(controller.formattedCurrentTime)
                .foregroundColor(SumiTheme.foreground)
                Text("/")
                .foregroundColor(SumiTheme.muted)
                Text(controller.formattedDuration)
                .foregroundColor(SumiTheme.muted)
            }
            .sumiTabularMono(size: 11.5)
            .fixedSize()

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
                        .foregroundColor(SumiTheme.foreground.opacity(0.8))
                        .frame(width: 16)
                    }
                    .buttonStyle(.sumiPressable)
                    .help(controller.isMuted ? "Unmute (M)" : "Mute (M)")

                    Slider(value: Binding(
                            get: { controller.isMuted ? 0 : controller.volume },
                            set: { controller.setVolume($0) }
                        ), in: 0...1)
                    .frame(width: 80)
                    .tint(SumiTheme.indigo)
                }

                // Upscaling (Anime4K)
                Button(action: { controller.toggleAnime4K() }) {
                    Image(systemName: "sparkles")
                    .font(.system(size: 14))
                    .foregroundColor(controller.isAnime4KEnabled ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.sumiPressable)
                .help(controller.isAnime4KEnabled ? "Upscaling: On" : "Upscaling: Off")

                // Rotate 90 degrees (off / CW / CCW)
                Button(action: { controller.cycleSideways() }) {
                    Image(systemName: "rotate.right")
                    .font(.system(size: 14))
                    .foregroundColor(controller.sidewaysState != 0 ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.sumiPressable)
                .help(rotateHelpText)

                // Fullscreen
                Button(action: {
                        #if os(macOS)
                        if let window = AppWindow.main ?? NSApp.keyWindow {
                            AppWindow.setToolbarVisible(false)
                            window.toggleFullScreen(nil)
                        }
                        #endif
                }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 14))
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
                }
                .buttonStyle(.sumiPressable)
                .help("Toggle Fullscreen (F)")
        }
        // Flat, not a floating panel — same reasoning as `topBar`: this bar
        // sits in the video's own bottom letterbox gap (already solid
        // black), so the material/shadow "panel" treatment it used to have
        // added nothing but a border and padding. A single top hairline is
        // what actually separates it from the picture.
        .padding(.horizontal, 4)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(SumiTheme.border.opacity(0.6))
                .frame(height: 1)
        }
    }
}
