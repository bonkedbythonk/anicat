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
    /// `MpvSurface` must stay mounted at the exact same call site
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
    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    /// Which of the two track lists is unfolded in the popover, at most one
    /// at a time: a release with a dozen subtitle tracks and both lists open
    /// is taller than the popover a 16:9 window has room for.
    @State private var expandedTrackList: TrackListKind?
    @State private var releases: [MediaDetailView.ReleaseCandidateItem] = []
    @State private var isLoadingReleases = false
    @State private var releaseError: String?
    /// What `releases` was fetched for, so reopening the popover does not
    /// search again — see `loadReleases`. Title and episode both, not the
    /// episode alone: episode 3 of the next show is a different list.
    @State private var loadedReleasesKey: String?
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

    /// Minimum chrome heights. On a MacBook the screen is taller than 16:9
    /// content, so the natural letterbox gap is bigger than these and the
    /// bars live entirely in black. On an exactly-16:9 display the gap is
    /// zero, and the bars overlay the picture by the shortfall instead,
    /// with a gradient scrim under the controls while they are shown and
    /// nothing at all while they are hidden. The video is never shrunk to
    /// make room: an earlier version did that, and a 16:9 monitor then
    /// never showed the picture full-screen even with the chrome faded out.
    // 48 for both, not 64 for the bottom: fullscreen on a 14-inch MacBook
    // Pro is 1512x949 under the notch, so a 16:9 picture leaves 49pt of
    // black above and below. The bottom bar is one row whose tallest item
    // is the 30pt play button; at 64 it overlapped the picture by 15pt and
    // showed a fade on the machine this app is mostly watched on, for
    // nothing but padding.
    static let minTopBarHeight: CGFloat = 48
    static let minBottomBarHeight: CGFloat = 48

    /// Where the picture lands and how tall each bar is for a window of
    /// `windowSize`. Pure so it can be checked for the two geometries that
    /// matter without a running player: a MacBook window, where both bars
    /// fit inside the letterbox, and a 16:9 window, where they overlay.
    struct ChromeGeometry: Equatable {
        var videoRect: CGRect
        /// Black above/below the picture, from letterboxing alone.
        var naturalTop: CGFloat
        var naturalBottom: CGFloat
        /// Bar heights: at least the minimums, never less than the gap.
        var topGap: CGFloat
        var bottomGap: CGFloat
        /// How far each bar extends over the picture. Zero on a MacBook.
        var topOverlay: CGFloat { max(0, topGap - naturalTop) }
        var bottomOverlay: CGFloat { max(0, bottomGap - naturalBottom) }
    }

    static func chromeGeometry(windowSize: CGSize, aspectRatio: Double?) -> ChromeGeometry {
        let videoRect = aspectFitRect(in: windowSize, aspectRatio: aspectRatio)
        let naturalTop = max(0, videoRect.minY)
        let naturalBottom = max(0, windowSize.height - videoRect.maxY)
        return ChromeGeometry(
            videoRect: videoRect,
            naturalTop: naturalTop,
            naturalBottom: naturalBottom,
            topGap: max(naturalTop, minTopBarHeight),
            bottomGap: max(naturalBottom, minBottomBarHeight)
        )
    }

    public var body: some View {
        GeometryReader { windowGeo in
        let windowSize = windowGeo.size
        // What the video would render at if given the *whole* window with
        // no chrome reservation at all — this is what tells us how big the
        // natural letterbox gap actually is, independent of whatever we end
        // up constraining `MpvSurface` to below.
        // The video always gets the whole window; this is where it lands
        // once letterboxed, and where the chrome and the AniSkip pill lay
        // out against.
        let geometry = Self.chromeGeometry(windowSize: windowSize, aspectRatio: controller.videoAspectRatio)
        let videoRect = geometry.videoRect
        let naturalTop = geometry.naturalTop
        let naturalBottom = geometry.naturalBottom
        let topGap = geometry.topGap
        let bottomGap = geometry.bottomGap
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

            // Tap handling lives in `MpvEventCatcherView`, not a SwiftUI tap
            // gesture — stacking onTapGesture(count: 1) alongside
            // onTapGesture(count: 2) makes SwiftUI hold every single click
            // for ~300ms to see whether a second one is coming before it
            // fires, which read as exactly the "click has a lot of delay"
            // lag reported against this screen. AppKit's mouseDown already
            // carries `clickCount` with no such wait, and the iOS catcher
            // installs one single-tap recognizer for the same reason.
            //
            // Frame/position/corner-radius vary with `isMinimized`, but this
            // is always the same call site — see the doc comment on
            // `isMinimized` for why that distinction is exactly what keeps
            // mpv alive across a minimize/restore instead of restarting it.
            // Corner radius goes to the host layer and the shadow to a shape
            // behind the video, never as modifiers on the surface itself: a
            // `.clipShape` or `.shadow` on a view whose layer changes every
            // frame makes Core Animation render the 60fps video offscreen
            // (mask, then shadow computed from the rendered alpha) on every
            // frame, for as long as the mini-player is up. That offscreen
            // pass was the app-wide lag while minimized.
            MpvSurface(controller: controller, streamURL: streamURL, cornerRadius: isMinimized ? 12 : 0)
                .ignoresSafeArea(isMinimized ? [] : .all)
                .frame(
                    width: isMinimized ? Self.miniSize.width : windowSize.width,
                    height: isMinimized ? Self.miniSize.height : windowSize.height
                )
                .background {
                    if isMinimized {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                    }
                }
                .position(isMinimized ? miniCenter : CGPoint(x: windowSize.width / 2, y: windowSize.height / 2))
                .animation(.easeInOut(duration: 0.28), value: isMinimized)

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

                // Top/bottom chrome, `topGap`/`bottomGap` tall. Where that
                // is natural letterbox the background is the same black the
                // picture is already framed in; where it exceeds the gap
                // (a 16:9 window) the excess is a gradient scrim that exists
                // only while the controls do, so a hidden chrome leaves the
                // picture untouched and a click there reaches the video.
                VStack(spacing: 0) {
                    Group {
                        if controller.areControlsVisible {
                            topBar(showsHairline: geometry.topOverlay == 0).padding(.horizontal, SumiTheme.spaceLg)
                        }
                    }
                    .frame(height: topGap)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .top) {
                        VStack(spacing: 0) {
                            Color.black.frame(height: naturalTop)
                            if topGap > naturalTop, controller.areControlsVisible {
                                LinearGradient(
                                    colors: [Color.black.opacity(0.78), Color.black.opacity(0)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: topGap - naturalTop)
                            }
                        }
                    }
                    .allowsHitTesting(controller.areControlsVisible)

                    Spacer(minLength: 0)

                    Group {
                        if controller.areControlsVisible {
                            PlayerBottomBar(controller: controller, showsHairline: geometry.bottomOverlay == 0).padding(.horizontal, SumiTheme.spaceLg)
                        }
                    }
                    .frame(height: bottomGap)
                    .frame(maxWidth: .infinity)
                    .background(alignment: .bottom) {
                        VStack(spacing: 0) {
                            if bottomGap > naturalBottom, controller.areControlsVisible {
                                LinearGradient(
                                    colors: [Color.black.opacity(0), Color.black.opacity(0.82)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                                .frame(height: bottomGap - naturalBottom)
                            }
                            Color.black.frame(height: naturalBottom)
                        }
                    }
                    .allowsHitTesting(controller.areControlsVisible)
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
                // over the whole small video (it sits above `MpvSurface`
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
        #endif
        // Not inside the guard above: the autohide timer and the menu-open
        // gate are the player's own state, and leaving them macOS-only would
        // fade the controls out from under an open sheet on iOS and leave a
        // cancelled-nowhere timer running after the view goes away.
        .onDisappear {
            controller.cancelAutohide()
        }
        .onChange(of: showEpisodeList || showInfoMenu) { _, isOpen in
            controller.isMenuOpen = isOpen
            if isOpen {
                controller.areControlsVisible = true
                #if os(macOS)
                NSCursor.setHiddenUntilMouseMoves(false)
                #endif
            } else {
                controller.showControlsBriefly()
            }
        }
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
    // A plain flat row, not a floating capsule: on a MacBook this bar sits
    // in the video's own natural letterbox gap (see `PlayerView.body`'s
    // `topGap`), which is already solid black — a translucent "glass" pill
    // blurring pure black is indistinguishable from a flat one, so the
    // capsule/shadow treatment this used to have was pure dead weight. On a
    // 16:9 window the same row sits on the gradient scrim the body draws
    // under it. A single hairline at the bottom separates it from the
    // picture either way.
    private func topBar(showsHairline: Bool) -> some View {
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
                .accessibilityLabel("Minimize Player")

                // Auto-Play Next
                Button(action: { controller.toggleAutoPlayNext() }) {
                    Image(systemName: controller.autoPlayNextEnabled ? "play.square.stack.fill" : "play.square.stack")
                        .font(.system(size: 13))
                        .foregroundColor(controller.autoPlayNextEnabled ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help(controller.autoPlayNextEnabled ? "Auto-Play Next: On" : "Auto-Play Next: Off")
                .accessibilityLabel(controller.autoPlayNextEnabled ? "Auto-Play Next: On" : "Auto-Play Next: Off")

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
                .accessibilityLabel(controller.autoSkipEnabled ? "Auto-Skip Intro/Outro: On" : "Auto-Skip Intro/Outro: Off")

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
                    .accessibilityLabel("Episodes")
                    .popover(isPresented: $showEpisodeList, arrowEdge: .bottom) {
                        episodeListMenu
                    }
                }

                // Info / More Options
                Button(action: {
                    refreshTracks()
                    loadReleases()
                    showInfoMenu = true
                }) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help("Info & Options")
                .accessibilityLabel("Info & Options")
                .popover(isPresented: $showInfoMenu, arrowEdge: .bottom) {
                    infoMenu
                }
            }
        }
        .frame(maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            // Same rule as PlayerBottomBar.showsHairline: only over black.
            if showsHairline {
                Rectangle()
                    .fill(SumiTheme.border.opacity(0.6))
                    .frame(height: 1)
            }
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

            trackPicker(kind: .audio, label: "Audio", rows: audioTracks) { track in
                controller.onSelectAudioTrack?(track.id)
                refreshTracks()
            }
            // An Off row in the list rather than a toggle beside it:
            // turning subtitles off is one of the values mpv takes for
            // `sid`, and a separate control would be a second place the
            // same state has to be read back from.
            trackPicker(kind: .subtitle, label: "Subtitles", rows: subtitleRows) { track in
                controller.onSelectSubtitleTrack?(track.id == PlayerTrack.off ? nil : track.id)
                refreshTracks()
            }

            // Picking a track above names one track in this release. This
            // row is the standing Sub/Dub choice, shared with Settings and
            // the detail page through `anicat_sub_dub`, and it is what the
            // next episode's resolve searches with.
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
                            guard let select = controller.onSelectAudioLanguage else {
                                audioSwitchNote = nil
                                return
                            }
                            select(wantsDub) { switched in
                                audioSwitchNote = switched
                                    ? nil
                                    : "No \(wantsDub ? "English" : "Japanese") audio track in this release — applies from the next episode."
                                refreshTracks()
                            }
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

            if controller.onListReleases != nil {
                Divider()
                releaseSection
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// The same releases the detail page's "Stream Servers" popover lists,
    /// for the episode playing rather than the page open. Picking one
    /// replays this episode from it, at the position it is at now.
    private var releaseSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Release")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SumiTheme.muted)
                Spacer(minLength: 8)
                if isLoadingReleases {
                    ProgressView().controlSize(.small)
                }
            }

            if isLoadingReleases {
                Text("Loading releases")
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
            } else if let releaseError {
                // Inline, never a sheet: the popover is over a playing
                // episode, and a modal over it would be a worse failure
                // than the one being reported.
                Text(releaseError)
                    .font(.system(size: 10.5))
                    .foregroundColor(SumiTheme.dangerLight)
                    .fixedSize(horizontal: false, vertical: true)
            } else if releases.isEmpty {
                Text("No releases found.")
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(releases) { release in
                            let isCurrent = release.name == controller.currentReleaseName
                            Button {
                                showInfoMenu = false
                                controller.onSelectRelease?(release.name)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(release.name)
                                            .font(.system(size: 11, weight: isCurrent ? .semibold : .regular))
                                            .foregroundColor(SumiTheme.foreground.opacity(isCurrent ? 1 : 0.8))
                                            // 4, not the detail page's 2:
                                            // the discriminator between two
                                            // releases (resolution, codec,
                                            // audio) sits at the end of the
                                            // name, and 2 lines at this
                                            // width truncates every one of
                                            // them before reaching it. The
                                            // section's own height cap is
                                            // what keeps the popover from
                                            // growing.
                                            .lineLimit(4)
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 6)
                                        if isCurrent {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundColor(SumiTheme.indigo)
                                        }
                                    }
                                    HStack(spacing: 6) {
                                        if release.isDub {
                                            Text("DUB")
                                                .sumiTabularMono(size: 9.5, weight: .bold)
                                                .foregroundColor(SumiTheme.indigo)
                                        }
                                        Text("\(release.seeders) seeders")
                                            .sumiTabularMono(size: 10)
                                            .foregroundColor(SumiTheme.muted)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(isCurrent ? SumiTheme.indigo.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    /// Fired when the popover opens, not when the player starts, and once
    /// per episode after that. The search behind it is a live wave across
    /// three indexers — the same one a resolve runs — and the popover is
    /// opened far more often for the speed row than for this list, so
    /// searching on every open would put a viewer nudging the speed up and
    /// down in competition with the episode's own resolve and the N+1
    /// preload for Nyaa's four-concurrent-query ceiling. A failed attempt
    /// is not remembered, so reopening retries it.
    private func loadReleases() {
        guard let list = controller.onListReleases else { return }
        let key = "\(controller.title)#\(controller.episodeNumber)"
        guard loadedReleasesKey != key || releaseError != nil else { return }
        loadedReleasesKey = key
        isLoadingReleases = true
        releaseError = nil
        list { found, failure in
            isLoadingReleases = false
            releases = found
            releaseError = failure
        }
    }

    private func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%.2gx", rate)
    }

    enum TrackListKind: Hashable {
        case audio
        case subtitle
    }

    /// The subtitle list plus its Off row. Off reads as current whenever no
    /// real track does, which is also the state a file with no subtitles at
    /// all is in — there is nothing else for the row to say there.
    private var subtitleRows: [PlayerTrack] {
        [PlayerTrack(
            id: PlayerTrack.off,
            lang: nil,
            title: nil,
            isSelected: !subtitleTracks.contains(where: \.isSelected),
            isForced: false
        )] + subtitleTracks
    }

    /// A label row that unfolds into the track list underneath it. Not a
    /// `Menu`: the styles that make one look like the rest of this popover
    /// (`.borderlessButton`) are macOS-only, and the popover has the height
    /// for an inline list at the widths the player runs at.
    private func trackPicker(
        kind: TrackListKind,
        label: String,
        rows: [PlayerTrack],
        onSelect: @escaping (PlayerTrack) -> Void
    ) -> some View {
        let isExpanded = expandedTrackList == kind
        let current = rows.first(where: \.isSelected)
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                expandedTrackList = isExpanded ? nil : kind
            } label: {
                HStack(spacing: 8) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.muted)
                    Spacer(minLength: 8)
                    Text(current?.label ?? "-")
                        .sumiTabularMono(size: 12)
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(SumiTheme.muted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .disabled(rows.isEmpty)

            if isExpanded, !rows.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { track in
                            Button {
                                expandedTrackList = nil
                                onSelect(track)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(track.label)
                                        .font(.system(size: 12, weight: track.isSelected ? .semibold : .regular))
                                        .foregroundColor(track.isSelected ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.8))
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer(minLength: 8)
                                    if track.isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundColor(SumiTheme.indigo)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .background(track.isSelected ? SumiTheme.indigo.opacity(0.12) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                        }
                    }
                }
                // A dual-audio release carries two or three audio tracks and
                // some carry a dozen subtitle ones; unbounded, the popover
                // grew past the window on the latter.
                .frame(maxHeight: 168)
            }
        }
    }

    /// Read once now and once after a beat: `mpv_set_property` returning is
    /// not the track reconfig having finished, so the immediate read still
    /// reports the track that was playing *before* the switch, and the
    /// checkmark sat on the row the viewer had just moved off.
    private func refreshTracks() {
        readTracks()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            readTracks()
        }
    }

    private func readTracks() {
        controller.onFetchTracks? { audio, subtitle in
            audioTracks = audio
            subtitleTracks = subtitle
        }
    }
}

private struct PlayerBottomBar: View {
    @Bindable var controller: PlayerController
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
                    .foregroundColor(SumiTheme.background)
                    .frame(width: 30, height: 30)
                    .background(SumiTheme.indigo)
                    .clipShape(Circle())
            }
            .buttonStyle(.sumiPressable)
            .help(controller.isPlaying ? "Pause (Space)" : "Play (Space)")
            .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")

            // Seek -10s
            Button(action: { controller.seekRelative(by: -10) }) {
                Image(systemName: "gobackward.10")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
            }
            .buttonStyle(.sumiPressable)
            .help("Back 10 seconds")
            .accessibilityLabel("Back 10 seconds")

            // Seek +10s
            Button(action: { controller.seekRelative(by: 10) }) {
                Image(systemName: "goforward.10")
                .font(.system(size: 15))
                .foregroundColor(SumiTheme.foreground.opacity(0.8))
            }
            .buttonStyle(.sumiPressable)
            .help("Forward 10 seconds")
            .accessibilityLabel("Forward 10 seconds")

            // Next Episode
            Button(action: { controller.nextEpisode() }) {
                Image(systemName: "forward.end.fill")
                .font(.system(size: 14))
                .foregroundColor(controller.hasNextEpisode ? SumiTheme.foreground.opacity(0.8) : SumiTheme.muted.opacity(0.4))
            }
            .buttonStyle(.sumiPressable)
            .disabled(!controller.hasNextEpisode)
            .help("Next Episode (N)")
            .accessibilityLabel("Next Episode (N)")

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
                    .accessibilityLabel(controller.isMuted ? "Unmute (M)" : "Mute (M)")

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
                .accessibilityLabel(controller.isAnime4KEnabled ? "Upscaling: On" : "Upscaling: Off")

                // Rotate 90 degrees (off / CW / CCW)
                Button(action: { controller.cycleSideways() }) {
                    Image(systemName: "rotate.right")
                    .font(.system(size: 14))
                    .foregroundColor(controller.sidewaysState != 0 ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.8))
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
                    .foregroundColor(SumiTheme.foreground.opacity(0.8))
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
