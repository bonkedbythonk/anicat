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
    /// The `matchedGeometryEffect` pair naming the episode still this play
    /// was started from, so the placeholder below can grow out of that row's
    /// real on-screen frame. Nil for a play with no row behind it (menu-bar
    /// Resume, Handoff, auto-next) — then the placeholder is skipped
    /// entirely and the player's existing 0.32s fade is the whole entrance.
    public let morphSource: EpisodeMorphSource?
    public let morphThumbnailURL: URL?
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
    /// Latched once per playback session, never reset: neither signal behind
    /// it is one-shot on its own. `isBuffering` goes true again on every
    /// mid-playback `paused-for-cache` stall and `awaitingNewFile` on every
    /// auto-next, so a derived flag would blank the video back to the
    /// placeholder in the middle of a binge. This view lives exactly as long
    /// as the session does, so its `@State` resets when the player closes —
    /// one intro per session, which is what it is for.
    @State private var hasShownFirstFrame = false
    #if os(macOS)
    /// The player's own key handling. See `PlayerKeyMonitor` for why it is a
    /// second monitor rather than more cases in `RootView.handleKeyDown`.
    @State private var keyMonitor = PlayerKeyMonitor()
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage("anicat_ambient_glow") private var ambientGlowEnabled: Bool = true
    /// The whole window is the picture-in-picture — see `PictureInPicture`
    /// for why there is no second window and no AVKit here.
    private var isPiP: Bool {
        #if os(macOS)
        return PictureInPicture.shared.isActive
        #else
        return false
        #endif
    }

    /// Chrome is suppressed in PiP, and so are the pill and the card: a
    /// 480x270 window has room for the picture and a play/pause button.
    private var showsFullChrome: Bool {
        !isMinimized && !isPiP
    }

    private static let miniSize = CGSize(width: 320, height: 180)

    public init(
        controller: PlayerController,
        streamURL: URL? = nil,
        onClose: @escaping () -> Void,
        onMinimize: @escaping () -> Void = {},
        isMinimized: Bool = false,
        onRestore: @escaping () -> Void = {},
        morphSource: EpisodeMorphSource? = nil,
        morphThumbnailURL: URL? = nil
    ) {
        self.controller = controller
        self.streamURL = streamURL
        self.onClose = onClose
        self.onMinimize = onMinimize
        self.isMinimized = isMinimized
        self.onRestore = onRestore
        self.morphSource = morphSource
        self.morphThumbnailURL = morphThumbnailURL
    }

    /// mpv has decoded and presented a frame of the file this session opened
    /// with. `awaitingNewFile` is set by `resolveAndPlay` before
    /// `activeStreamURL`, so this cannot read true in the gap before
    /// `loadFile` runs; `isBuffering` is set by `loadFile` and cleared by the
    /// first non-stale `time-pos`, which that method's own comment calls
    /// proof a frame decoded. `videoDisplayWidth` deliberately is not part of
    /// this: an audio-only or otherwise odd file never reports
    /// `video-params/dw`, and waiting on it would strand the placeholder up
    /// over a file that is playing fine.
    private var firstFrameLanded: Bool {
        !controller.awaitingNewFile && !controller.isBuffering
    }

    /// While true the video surface is transparent and the episode still is
    /// what fills the video frame. Reduce Motion skips the whole thing: the
    /// player's own 0.32s fade already is the plain-fade fallback.
    private var isFlyingIn: Bool {
        morphSource != nil && !hasShownFirstFrame && !reduceMotion
    }

    /// One curve for the whole minimize/restore transition, read by both the
    /// video frame and the chrome so the two cannot drift apart. Owned here
    /// rather than at the call sites: every `isPlayerMinimized` mutation used
    /// to carry its own `withAnimation(.smooth)`, which ran a second
    /// transaction against this one — the same two-curves-one-change mistake
    /// `closeDetail`'s comment in `RootView` records as "jitters, stops, pops
    /// away".
    private var minimizeCurve: Animation {
        reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.4, extraBounce: 0.05)
    }

    /// The chrome does not cross-fade through the middle of the move: the
    /// outgoing controls are gone within the first third and the incoming
    /// ones only start in the last third, so at no point are two sets of
    /// controls both legible over a frame that is still travelling.
    private static let chromeTransition = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeIn(duration: 0.13).delay(0.27)),
        removal: .opacity.animation(.easeOut(duration: 0.13))
    )

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
            // Background Canvas (Black). It has to reach 0 while minimized:
            // left opaque it blacks out the whole window and defeats the
            // point of minimizing, which is seeing and using the rest of the
            // app behind the small box. Faded rather than branched on `if`
            // so the app underneath un-dims continuously along the same
            // spring the frame shrinks on, instead of popping back the
            // instant the flag flips. `allowsHitTesting` is not
            // optional here: a fully transparent `Color` still takes every
            // click in the window.
            Color.black
                .opacity(isMinimized ? 0 : 1)
                .allowsHitTesting(!isMinimized)
                .ignoresSafeArea()

            // The episode still the play was started from, at the size and
            // place the video is about to occupy. It sits under the surface
            // and stays visible only because `isFlyingIn` holds that surface
            // transparent — the host view and the Metal layer are both
            // painted opaque black, so without that gate nothing beneath them
            // can ever be seen. With a nil aspect ratio (mpv has not reported
            // the decoded size yet, and `resolveAndPlay` clears it per
            // episode) `videoRect` is the whole window, same fallback the
            // chrome uses.
            if isFlyingIn, let morphSource {
                CachedAsyncImage(url: morphThumbnailURL, maxPixelSize: 1024) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.black
                }
                .frame(width: videoRect.width, height: videoRect.height)
                .clipped()
                .matchedGeometryEffect(id: morphSource.key, in: morphSource.namespace)
                // Same reasoning as the detail page's poster:
                // matchedGeometryEffect only animates the frame, so without
                // an opacity transition the still snaps in at the row's size
                // with no cross-fade while the player around it fades.
                .transition(.opacity)
                .allowsHitTesting(false)
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
                // The one modifier the paragraph above does not rule out.
                // Opacity is a plain layer property, so this neither moves
                // the surface to a second call site nor reaches
                // `dismantleNSView` the way an `if`/`else` or `.hidden()`
                // would — that is what "minimize exits the stream" was. It
                // also only leaves 1.0 for the length of one fade at the
                // start of a session, and Core Animation skips the group
                // pass entirely at exactly 1.0, so the mini-player's
                // steady-state cost is unchanged.
                .opacity(isFlyingIn ? 0 : 1)
                .ignoresSafeArea(isMinimized ? [] : .all)
                .frame(
                    width: isMinimized ? Self.miniSize.width : windowSize.width,
                    height: isMinimized ? Self.miniSize.height : windowSize.height
                )
                .background {
                    if isMinimized {
                        // The halo is a second shadow on the shape already
                        // behind the video, not a modifier on the surface:
                        // a shadow on the layer mpv redraws is the offscreen
                        // pass the comment above rules out. One colour rather
                        // than four — at 320x180 the four edges read as noise.
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.black)
                            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
                            .shadow(
                                color: (glowEdges?.mean.color ?? .clear).opacity(glowEdges == nil ? 0 : 0.5),
                                radius: 26
                            )
                            .animation(reduceMotion ? nil : .smooth(duration: 1.5), value: controller.ambientEdges)
                    }
                }
                .position(isMinimized ? miniCenter : CGPoint(x: windowSize.width / 2, y: windowSize.height / 2))
                .animation(minimizeCurve, value: isMinimized)

            if !isMinimized {
                // Above `MpvSurface`, never below it: the host view paints
                // itself black across the whole window (see `MpvHostView`),
                // so anything behind the surface is invisible whatever the
                // letterboxing does. It is confined to the bars, and the
                // chrome that shares them draws over it.
                ambientGlowLayer(geometry: geometry, windowSize: windowSize)

                // "Click outside cancels" for the next-episode card. Over the
                // video and under the chrome, so pausing or scrubbing while
                // the card is up still reaches the controls that do it —
                // above the chrome this would have swallowed every one of
                // them for the eight seconds the card lives.
                if controller.nextEpisodeCountdown.isVisible {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture {
                            controller.cancelNextEpisodeCountdown()
                        }
                        .ignoresSafeArea()
                }

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
                if showsFullChrome {
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
                                // Clear where the glow is on: this fill is the
                                // letterbox black, and painting it over the bleed
                                // would be painting over the whole feature.
                                (glowEdges == nil ? Color.black : Color.clear)
                                    .frame(height: naturalTop)
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
                                (glowEdges == nil ? Color.black : Color.clear)
                                    .frame(height: naturalBottom)
                            }
                        }
                        .allowsHitTesting(controller.areControlsVisible)
                    }
                    .animation(.smooth, value: controller.areControlsVisible)
                    .transition(Self.chromeTransition)

                    // Skip pill / auto-skip flash (bottom right). Kept floating
                    // over the video itself, unlike the rest of the chrome — it's a
                    // contextual action tied to what's playing right now, meant to
                    // be seen right where the eye already is, the way
                    // Netflix/Crunchyroll place it.
                    skipOverlay
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)

                    // Same corner as the pill above, which is why the pill stands
                    // down while this is up rather than the two stacking.
                    nextEpisodeCard
                        .frame(width: videoRect.width, height: videoRect.height)
                        .position(x: videoRect.midX, y: videoRect.midY)
                }

                #if os(macOS)
                if isPiP {
                    pipChrome
                }
                #endif
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
                .transition(Self.chromeTransition)
            }
        }
        .background(Color.black.opacity(isMinimized ? 0 : 1))
        // Drives the branch swap above: without an animated transaction on
        // this value SwiftUI runs no transition at all and the two chrome
        // sets hard-cut, however staged `chromeTransition` is. The surface
        // chain declares the same curve again next to the geometry it moves.
        // Below `.background`, not above it: a value animation only covers
        // what it wraps, and the backdrop added outside it would otherwise
        // pop rather than un-dim with everything else.
        .animation(minimizeCurve, value: isMinimized)
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
            #if os(macOS)
            keyMonitor.stop()
            // The window is only small and floating because a player asked
            // it to be; nothing else would ever put it back.
            PictureInPicture.shared.exit()
            #endif
        }
        #if os(macOS)
        .onAppear {
            keyMonitor.onKey = { isSkipKey in
                // The card supersedes the pill: while it is up, every key is
                // "not now" and none of them is consumed, so the key the
                // viewer actually pressed still does its usual job.
                if controller.nextEpisodeCountdown.isVisible {
                    withAnimation(.smooth) {
                        controller.cancelNextEpisodeCountdown()
                    }
                    return false
                }
                guard isSkipKey, !controller.autoSkipEnabled,
                      controller.pendingSkipWindow != nil else { return false }
                withAnimation(.snappy) {
                    controller.skipPendingWindow()
                }
                return true
            }
            keyMonitor.start()
        }
        #endif
        // The card is where Cancel lives, so it must not arm behind a
        // mini-player the viewer cannot see it in; a minimized player falls
        // back to `AppModel`'s own end-of-episode auto-next, exactly as
        // before the card existed. `initial: true` because a play started
        // straight into the mini-player never changes this value.
        .onChange(of: isMinimized, initial: true) { _, minimized in
            controller.isMiniPlayerActive = minimized
        }
        // The always-present base for the ambient glow, and the whole of it
        // on any machine or build where frame sampling turns out not to be
        // affordable. Computed once per episode and before mpv has decoded
        // anything, so the bars are lit from the first frame rather than
        // three seconds into it.
        .task(id: ambientThumbnailURL) {
            guard let url = ambientThumbnailURL else {
                controller.ambientThumbnailColor = nil
                return
            }
            let color = await AmbientGlow.averageColor(of: url)
            guard !Task.isCancelled else { return }
            controller.ambientThumbnailColor = color
        }
        // Latched, not mirrored: see `hasShownFirstFrame`. The curve is the
        // same 0.32s the player's own entrance uses (`resolveAndPlay`), so
        // the still handing over to the picture reads as one move with the
        // dim rather than a second, faster thing happening on top of it.
        .onChange(of: firstFrameLanded) { _, landed in
            guard landed, !hasShownFirstFrame else { return }
            withAnimation(.easeInOut(duration: 0.32)) {
                hasShownFirstFrame = true
            }
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

    /// The colours the letterbox bars (and the mini-player's halo) bleed
    /// right now, or nil when the glow is off. Reduce Transparency turns it
    /// off outright: the whole effect is a translucent wash of the picture
    /// over the app's own black, which is the thing that setting asks not to
    /// happen.
    private var glowEdges: AmbientEdges? {
        guard ambientGlowEnabled, !reduceTransparency,
              controller.ambientSource != .none else { return nil }
        return controller.ambientEdges
    }

    /// The still the fallback colour is taken from: the playing episode's,
    /// which the morph source only sometimes is (a menu-bar Resume or an
    /// auto-next has no row behind it).
    private var ambientThumbnailURL: URL? {
        controller.episodeList.first { $0.number == controller.episodeNumber }?.thumbnailURL
            ?? morphThumbnailURL
    }

    /// The bleed itself: one gradient per bar, running from the colour at the
    /// picture's edge to nothing at the window's. No blur — the colour is
    /// already the mean of an edge strip, so there is no detail left in it
    /// for a blur to soften, and a blur filter over a layer that sits beside
    /// 60fps video is an offscreen pass this file's other comments already
    /// record the cost of.
    @ViewBuilder
    private func ambientGlowLayer(geometry: ChromeGeometry, windowSize: CGSize) -> some View {
        if let edges = glowEdges {
            let video = geometry.videoRect
            ZStack(alignment: .topLeading) {
                if video.minY > 0 {
                    bleed(edges.top, from: .bottom)
                        .frame(width: windowSize.width, height: video.minY)
                        .position(x: windowSize.width / 2, y: video.minY / 2)
                }
                if video.maxY < windowSize.height {
                    let height = windowSize.height - video.maxY
                    bleed(edges.bottom, from: .top)
                        .frame(width: windowSize.width, height: height)
                        .position(x: windowSize.width / 2, y: video.maxY + height / 2)
                }
                if video.minX > 0 {
                    bleed(edges.left, from: .trailing)
                        .frame(width: video.minX, height: windowSize.height)
                        .position(x: video.minX / 2, y: windowSize.height / 2)
                }
                if video.maxX < windowSize.width {
                    let width = windowSize.width - video.maxX
                    bleed(edges.right, from: .leading)
                        .frame(width: width, height: windowSize.height)
                        .position(x: video.maxX + width / 2, y: windowSize.height / 2)
                }
            }
            .frame(width: windowSize.width, height: windowSize.height)
            .allowsHitTesting(false)
            .animation(reduceMotion ? nil : .smooth(duration: 1.5), value: controller.ambientEdges)
        }
    }

    private func bleed(_ rgb: AmbientRGB, from edge: UnitPoint) -> some View {
        LinearGradient(
            colors: [rgb.color.opacity(0.55), rgb.color.opacity(0)],
            startPoint: edge,
            endPoint: UnitPoint(x: 1 - edge.x, y: 1 - edge.y)
        )
    }

    #if os(macOS)
    /// The only chrome a 480x270 window has room for. Revealed by the same
    /// `areControlsVisible` the full player uses — the root already turns it
    /// on with any pointer movement and the autohide timer takes it away
    /// again, so this needs no hover layer of its own, and adding one would
    /// have sat over the video swallowing the click that toggles play/pause.
    @ViewBuilder
    private var pipChrome: some View {
        if controller.areControlsVisible {
            VStack {
                Spacer()
                HStack(spacing: 4) {
                    Button(action: { controller.togglePlayPause() }) {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.sumiPressable)
                    .help(controller.isPlaying ? "Pause" : "Play")

                    Button(action: { PictureInPicture.shared.exit() }) {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: 11))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.sumiPressable)
                    .help("Restore")
                    .accessibilityLabel("Restore the player")

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                    }
                    .buttonStyle(.sumiPressable)
                    .help("Close")
                    .accessibilityLabel("Close the player")
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.black.opacity(0.72))
                .clipShape(Capsule())
                .padding(.bottom, 10)
            }
            .transition(.opacity)
        }
    }
    #endif

    /// The window the Skip pill is offering, if any. Nothing while auto-skip
    /// is on: the jump has already happened by the time a pill could be seen,
    /// and `skipFlashLabel` is what reports it instead.
    private var skipPillWindow: SkipWindow? {
        guard !controller.autoSkipEnabled, !controller.nextEpisodeCountdown.isVisible else { return nil }
        return controller.pendingSkipWindow
    }

    /// The episode the card is offering. Read from `episodeList` rather than
    /// from a value the controller could hold: that list is the same one the
    /// next/prev buttons walk, so the card can never name an episode those
    /// would not go to.
    private var nextEpisodeItem: MediaDetailView.EpisodeItem? {
        guard let index = controller.episodeList.firstIndex(where: { $0.number == controller.episodeNumber }),
              controller.episodeList.indices.contains(index + 1) else { return nil }
        return controller.episodeList[index + 1]
    }

    /// The countdown card. It changes nothing about *whether* the next
    /// episode plays — the setting and the "is there a next episode" check
    /// are the same ones `AppModel` already made — it only puts the decision
    /// somewhere the viewer can see it and say no.
    @ViewBuilder
    private var nextEpisodeCard: some View {
        if controller.nextEpisodeCountdown.isVisible, let next = nextEpisodeItem {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(alignment: .center, spacing: 12) {
                        CachedAsyncImage(url: next.thumbnailURL, maxPixelSize: 320) { image in
                            image.resizable().aspectRatio(contentMode: .fill)
                        } placeholder: {
                            Rectangle().fill(SumiTheme.card)
                        }
                        .frame(width: 96, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                        VStack(alignment: .leading, spacing: 3) {
                            Text("Up next")
                                .sumiTabularMono(size: 9.5, weight: .bold)
                                .foregroundColor(SumiTheme.indigo)
                            Text(next.title.isEmpty ? "Episode \(next.number)" : next.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("Play now") {
                                    controller.playNextEpisodeNow()
                                }
                                .buttonStyle(.sumiPressable)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(SumiTheme.indigo)
                                Button("Cancel") {
                                    controller.cancelNextEpisodeCountdown()
                                }
                                .buttonStyle(.sumiPressable)
                                .font(.system(size: 11))
                                .foregroundColor(SumiTheme.muted)
                            }
                            .padding(.top, 2)
                        }
                        .frame(width: 168, alignment: .leading)

                        countdownIndicator
                    }
                    .padding(12)
                    .background(Color.black.opacity(0.82))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(SumiTheme.border.opacity(0.7), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.4), radius: 16, y: 6)
                    .padding(.trailing, 24)
                    .padding(.bottom, controller.areControlsVisible ? 100 : 24)
                }
            }
            .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
            .animation(.smooth, value: controller.nextEpisodeCountdown.phase)
        }
    }

    /// The ring drains once per position tick (mpv reports `time-pos` on
    /// every decoded frame), so the linear tween only has to cover the gap
    /// between ticks. Reduce Motion gets the bare number instead: a ring is
    /// motion whose only content is a count, and the count says it already.
    @ViewBuilder
    private var countdownIndicator: some View {
        let remaining = controller.nextEpisodeCountdown.remaining(at: controller.currentTime)
        let seconds = max(1, Int(remaining.rounded(.up)))
        if reduceMotion {
            Text("\(seconds)")
                .sumiTabularMono(size: 20, weight: .bold)
                .foregroundColor(SumiTheme.foreground)
                .frame(width: 40, height: 40)
        } else {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.18), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: controller.nextEpisodeCountdown.elapsedFraction(at: controller.currentTime))
                    .stroke(SumiTheme.indigo, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.25), value: controller.currentTime)
                Text("\(seconds)")
                    .sumiTabularMono(size: 14, weight: .bold)
                    .foregroundColor(SumiTheme.foreground)
            }
            .frame(width: 40, height: 40)
        }
    }

    /// Bottom-right of the picture: the manual Skip pill, and above it the
    /// brief note auto-skip leaves behind. Auto-skip is otherwise completely
    /// silent, and ninety seconds vanishing with no explanation reads as a
    /// seek bug rather than as the feature working.
    private var skipOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let flash = controller.skipFlashLabel {
                        HStack(spacing: 6) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 10))
                            Text("Skipped \(flash)")
                                .sumiTabularMono(size: 11, weight: .medium)
                        }
                        .foregroundColor(SumiTheme.foreground)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .transition(.opacity)
                    }
                    if let window = skipPillWindow {
                        Button {
                            withAnimation(.snappy) {
                                controller.skipPendingWindow()
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "forward.fill")
                                    .font(.system(size: 12))
                                Text(window.label)
                                    .sumiTabularMono(size: 12, weight: .bold)
                                Text("↵")
                                    .sumiTabularMono(size: 11, weight: .medium)
                                    .opacity(0.6)
                            }
                            .foregroundColor(SumiTheme.background)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(SumiTheme.indigo)
                            .clipShape(Capsule())
                            .shadow(color: Color.black.opacity(0.3), radius: 8, x: 0, y: 4)
                        }
                        .buttonStyle(.sumiPressable)
                        .help("\(window.label) (Return or S)")
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.trailing, 24)
                .padding(.bottom, controller.areControlsVisible ? 100 : 24)
            }
        }
        .animation(.smooth, value: skipPillWindow)
        .animation(.smooth, value: controller.skipFlashLabel)
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

                #if os(macOS)
                // Picture in Picture: the window itself shrinks and floats.
                // Button only — `P` is bound to Previous Episode in
                // `RootView.handleKeyDown`, and a second local monitor
                // claiming the same key would resolve in whichever order
                // AppKit happened to dispatch the two.
                Button(action: {
                    PictureInPicture.shared.toggle(aspectRatio: controller.videoAspectRatio)
                }) {
                    Image(systemName: "rectangle.inset.bottomright.filled")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.foreground.opacity(0.85))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.sumiPressable)
                .help("Picture in Picture")
                .accessibilityLabel("Picture in Picture")
                #endif

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
    /// Where the pointer is along the bar, 0...1, or nil when it is not over
    /// it. The tooltip is the whole of what this drives; scrubbing has its
    /// own drag state and does not read this.
    @State private var hoverFraction: Double?

    private static let tooltipWidth: CGFloat = 150

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
                    .foregroundColor(SumiTheme.foreground)
                if let chapter, !chapter.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(chapter.title)
                        .font(.system(size: 10))
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: Self.tooltipWidth)
            .background(Color.black.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SumiTheme.border.opacity(0.6), lineWidth: 1)
            )
            .allowsHitTesting(false)
            // Clamped to the bar rather than centred on the pointer at the
            // ends, where centring would hang it off the window.
            .offset(
                x: min(max(hoverFraction * width - Self.tooltipWidth / 2, 0), max(width - Self.tooltipWidth, 0)),
                y: -46
            )
        }
    }

    private var scrubber: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: 4)
                Capsule()
                    .fill(SumiTheme.indigo)
                    .frame(width: geo.size.width * CGFloat(controller.progressFraction), height: 4)
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
