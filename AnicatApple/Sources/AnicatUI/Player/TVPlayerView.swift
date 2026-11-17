#if os(tvOS)
import SwiftUI

/// The player chrome on Apple TV, driven by the Siri Remote.
///
/// The system player is no more usable here than on the phone: every
/// release this app streams is Matroska with ASS subtitles, which
/// `AVFoundation` cannot open, so mpv keeps decoding and this view supplies
/// what the TV app player would have -- transport at the bottom, a timeline,
/// and the remote's own vocabulary:
///
/// - Play/Pause toggles playback, whether or not the chrome is up.
/// - Left and right on the ring or touch surface seek ten seconds while the
///   chrome is down; once it is up they move focus between the controls.
/// - Select (a press) brings the chrome up when it is down.
/// - Menu (Back) puts the chrome away; a second press closes the player.
///
/// `PhonePlayerView` stays the iPhone chrome and `PlayerView` the Mac's.
/// Split rather than gated: almost nothing crosses over. No tap layer, no
/// drag scrubber, no `statusBarHidden`, and nothing here can be reached
/// except through focus.
struct TVPlayerView: View {
    @Bindable var controller: PlayerController
    let streamURL: URL
    let onClose: () -> Void

    @State private var releases: [MediaDetailView.ReleaseCandidateItem] = []
    @State private var releaseFailure: String?
    @State private var isLoadingReleases = false
    @State private var showReleases = false
    // Same keys as the phone's menu, so a speed or size picked on one
    // device's player is the one the other starts at.
    @AppStorage("anicat_playback_speed") private var storedSpeed: Double = 1.0

    fileprivate enum Focus: Hashable {
        case surface, back, playPause, forward, timeline, tracks, next, playNextNow, cancelNext
    }
    @FocusState private var focus: Focus?
    /// A thin timeline shown for a moment after a seek from the hidden
    /// player, which takes no focus and leaves the controls down.
    @State private var seekBarVisible = false
    @State private var seekBarHide: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The one mount site. `MpvSurface`'s dismantle path stops
            // playback, so this must never move between branches of an
            // `if` -- the failure `PlayerView` records on macOS.
            MpvSurface(controller: controller, streamURL: streamURL, cornerRadius: 0)
                .ignoresSafeArea()

            // The focus holder while the chrome is down. Invisible, and the
            // only focusable thing on screen, so every remote command lands
            // on it: the ring seeks, a press brings the controls up. Removed
            // while the chrome is up so the ring moves focus between the
            // buttons instead.
            if !controller.areControlsVisible {
                Button {
                    showControls()
                } label: {
                    Color.clear
                }
                // Not `.plain`: tvOS lights a focused plain button with the
                // white lift highlight, and this one is the size of the
                // screen. The picture went white the moment the chrome
                // timed out and focus landed here. A style of our own draws
                // nothing on focus, and `focusEffectDisabled` covers the
                // halo the system would still add around it.
                .buttonStyle(TVInvisibleButtonStyle())
                .focusEffectDisabled()
                .focused($focus, equals: .surface)
                // Seeks without bringing the controls up. Showing them
                // moved focus onto the play button, so on a real Apple TV a
                // second press or swipe moved focus instead of seeking.
                .onMoveCommand { direction in
                    switch direction {
                    case .left: seekQuietly(by: -10)
                    case .right: seekQuietly(by: 10)
                    default: showControls()
                    }
                }
                .ignoresSafeArea()
            }

            if controller.isBuffering {
                bufferingIndicator
            }

            skipPill

            if seekBarVisible && !controller.areControlsVisible {
                TVTimeline(controller: controller, focus: $focus, onSeek: seek(by:))
                    .disabled(true)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.horizontal, TVMetrics.gutter)
                    .padding(.vertical, 60)
                    .transition(.opacity)
            }

            if controller.areControlsVisible {
                controls
                    .transition(.opacity)
            }

            if controller.nextEpisodeCountdown.isVisible {
                nextEpisodeCard
                    .transition(.opacity)
            }
        }
        .accessibilityIdentifier("tv.player")
        .onPlayPauseCommand {
            controller.togglePlayPause()
            controller.showControlsBriefly()
        }
        // Menu: chrome up, put it away; chrome down, leave the player. Not
        // wired to `onClose` directly, which would drop a viewer out of the
        // episode when all they wanted was the timeline gone.
        .onExitCommand {
            if controller.nextEpisodeCountdown.isVisible {
                withAnimation(.smooth) { controller.cancelNextEpisodeCountdown() }
            } else if controller.areControlsVisible {
                hideControls()
            } else {
                onClose()
            }
        }
        .sheet(isPresented: $showReleases) { releaseSheet }
        .task {
            controller.showControlsBriefly()
            focus = .playPause
            if controller.playbackRate != storedSpeed { controller.setPlaybackRate(storedSpeed) }
        }
        // Focus follows the chrome: onto the play button as it comes up, back
        // onto the surface as it goes, since the button it sat on is gone.
        .onChange(of: controller.areControlsVisible) { _, visible in
            focus = visible ? .playPause : .surface
            // The bottom fifth is the transport and timeline; the dialogue
            // goes above it while they are up.
            controller.liftSubtitles(by: visible ? 0.2 : 0)
        }
        // The card takes the remote: Play now is one press away, Back
        // dismisses it. Left on the surface, a press would only have
        // brought the controls up under it.
        .onChange(of: controller.nextEpisodeCountdown.isVisible) { _, visible in
            focus = visible ? .playNextNow : (controller.areControlsVisible ? .playPause : .surface)
        }
        .onDisappear {
            controller.cancelAutohide()
            controller.liftSubtitles(by: 0)
        }
    }

    // MARK: Next episode

    /// The Mac's "next episode in 8" card, in the bottom right where the
    /// TV app puts its own. Without it the TV ran the countdown with
    /// nothing on screen: the next episode simply started, with no way to
    /// stay on the credits.
    private var nextEpisodeCard: some View {
        let remaining = Int(controller.nextEpisodeCountdown.remaining(at: controller.currentTime).rounded(.up))
        return VStack(alignment: .leading, spacing: 20) {
            Text("Next episode in \(remaining)")
                .font(.system(size: 30, weight: .semibold)).monospacedDigit()
                .foregroundStyle(.white)
            HStack(spacing: 24) {
                Button {
                    withAnimation(.smooth) { controller.playNextEpisodeNow() }
                } label: {
                    Label("Play now", anicat: "play.fill")
                }
                .focused($focus, equals: .playNextNow)
                Button("Cancel") {
                    withAnimation(.smooth) { controller.cancelNextEpisodeCountdown() }
                }
                .focused($focus, equals: .cancelNext)
            }
        }
        .padding(40)
        .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.horizontal, TVMetrics.gutter)
        .padding(.vertical, 60)
        .focusSection()
    }

    // MARK: Controls

    private func showControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            controller.showControlsBriefly()
        }
    }

    private func hideControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            // Not `cancelAutohide()`: it ends with `areControlsVisible =
            // true` (on macOS it means "hold the controls while a menu is
            // open"). See `PhonePlayerView.toggleControls`.
            controller.areControlsVisible = false
        }
    }

    @ViewBuilder
    private var controls: some View {
        ZStack {
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 220)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 320)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                titleRow
                Spacer()
                VStack(spacing: 28) {
                    // Its own view: the clock changes four times a second,
                    // and read here it redrew the whole chrome each time.
                    TVTimeline(controller: controller, focus: $focus, onSeek: seek(by:))
                    transport
                }
            }
            .padding(.horizontal, TVMetrics.gutter)
            .padding(.vertical, 60)
        }
        // Any focus movement inside the chrome keeps it up.
        .onChange(of: focus) { _, _ in
            if controller.areControlsVisible { controller.showControlsBriefly() }
        }
    }

    @ViewBuilder
    private var titleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.title)
                .font(.sumiHeading(size: 36, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            if !controller.episodeTitle.isEmpty {
                Text("Episode \(controller.episodeNumber) · \(controller.episodeTitle)")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            } else {
                Text("Episode \(controller.episodeNumber)")
                    .font(.system(size: 24))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 40) {
            Button { seek(by: -10) } label: {
                Image(anicat: "gobackward.10")
            }
            .focused($focus, equals: .back)

            Button {
                controller.togglePlayPause()
                controller.showControlsBriefly()
            } label: {
                Image(anicat: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .focused($focus, equals: .playPause)

            Button { seek(by: 10) } label: {
                Image(anicat: "goforward.10")
            }
            .focused($focus, equals: .forward)

            Spacer()

            if controller.hasNextEpisode {
                Button {
                    controller.nextEpisode()
                } label: {
                    Label("Next episode", anicat: "forward.end.fill")
                }
                .focused($focus, equals: .next)
            }

            // Its own view, compared by controller only: built inline, the
            // menu was rebuilt by every one-second clock tick of this view,
            // and on a real Apple TV an open menu glitched mid-episode.
            TVPlayerMenu(controller: controller, showReleases: $showReleases, onClose: onClose)
                .equatable()
                .focused($focus, equals: .tracks)
        }
        .font(.system(size: 30))
        .focusSection()
    }

    /// Which release is being streamed: the engine races candidates and
    /// picks one, and this is how a viewer overrides that.
    @ViewBuilder
    private var releaseSheet: some View {
        NavigationStack {
            Group {
                if isLoadingReleases {
                    ProgressView("Searching indexers")
                } else if let releaseFailure {
                    ContentUnavailableView("Could not list releases", anicat: "exclamationmark.triangle", description: Text(releaseFailure))
                } else if releases.isEmpty {
                    ContentUnavailableView("No other releases", anicat: "square.stack.3d.up.slash")
                } else {
                    List(releases) { release in
                        Button {
                            controller.onSelectRelease?(release.name)
                            showReleases = false
                        } label: {
                            HStack(spacing: 20) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(release.name)
                                        .font(.system(size: 24))
                                        .lineLimit(2)
                                    Text(Self.releaseDetail(release))
                                        .font(.system(size: 20)).monospacedDigit()
                                        .foregroundStyle(.secondary)
                                    if release.name == controller.rememberedReleaseName {
                                        Text("Played last time")
                                            .font(.system(size: 18)).monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if release.name == controller.currentReleaseName {
                                    Image(anicat: "checkmark")
                                        .foregroundStyle(.tint)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Release")
        }
        .task { loadReleases() }
    }

    private static func releaseDetail(_ release: MediaDetailView.ReleaseCandidateItem) -> String {
        var parts: [String] = []
        if release.isDub { parts.append("DUB") }
        if release.seeders > 0 { parts.append("\(release.seeders) SEEDS") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func loadReleases() {
        guard !isLoadingReleases else { return }
        isLoadingReleases = true
        releaseFailure = nil
        controller.onListReleases? { candidates, failure in
            isLoadingReleases = false
            releases = candidates
            releaseFailure = failure
        }
    }

    private func seek(by delta: Double) {
        controller.seekRelative(by: delta)
        controller.showControlsBriefly()
    }

    private func seekQuietly(by delta: Double) {
        controller.seekRelative(by: delta)
        withAnimation(.easeOut(duration: 0.15)) { seekBarVisible = true }
        seekBarHide?.cancel()
        seekBarHide = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { seekBarVisible = false }
        }
    }

    // MARK: Skip intro / outro

    /// Offered as a button the remote can reach. Focus is not stolen for
    /// it: the surface keeps the ring, and the pill is one move up.
    @ViewBuilder
    private var skipPill: some View {
        if let window = controller.activeSkipWindow, !controller.autoSkipEnabled {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button {
                        withAnimation(.snappy) { controller.skipPendingWindow() }
                    } label: {
                        Text(window.label)
                            .font(.system(size: 24, weight: .semibold))
                    }
                }
            }
            .padding(.horizontal, TVMetrics.gutter)
            .padding(.bottom, controller.areControlsVisible ? 260 : 60)
        }
    }

    @ViewBuilder
    private var bufferingIndicator: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            if let status = controller.resolveStatus {
                Text(PlayerController.withElapsed(status, controller.resolveElapsedSeconds))
                    .font(.system(size: 22)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            } else if let percent = controller.bufferingPercent {
                Text("\(percent)%")
                    .font(.system(size: 22)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            } else if let seconds = controller.resolveElapsedSeconds {
                Text(PlayerController.withElapsed("Searching indexers", seconds))
                    .font(.system(size: 22)).monospacedDigit()
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The player's options menu (audio, subtitles, speed, look, release).
///
/// Equatable on the controller alone, so the parent's one-second redraws
/// pass it by; it still redraws when anything it reads on the controller
/// changes, through observation.
private struct TVPlayerMenu: View, @MainActor Equatable {
    @Bindable var controller: PlayerController
    @Binding var showReleases: Bool
    let onClose: () -> Void

    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    // Same keys as the phone's and the Mac's menus, so a speed, size or look
    // picked on one device's player is the one the others start at.
    @AppStorage("anicat_playback_speed") private var storedSpeed: Double = 1.0
    @AppStorage(PlayerController.subtitleScaleKey) private var subtitleScale: Double = 1.0
    @AppStorage(SubtitleStyle.key) private var subtitleStyleRaw: String = SubtitleStyle.release.rawValue

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.controller === rhs.controller }

    var body: some View {
        Menu {
            if !audioTracks.isEmpty {
                Picker("Audio", selection: audioSelection) {
                    ForEach(audioTracks) { track in
                        Text(track.label).tag(track.id)
                    }
                }
                // A submenu with its name and current value: inline, tvOS
                // listed every choice under one another with no heading.
                .pickerStyle(.menu)
            }
            if !subtitleTracks.isEmpty {
                Picker("Subtitles", selection: subtitleSelection) {
                    Text("Off").tag(PlayerTrack.off)
                    ForEach(subtitleTracks) { track in
                        Text(track.label).tag(track.id)
                    }
                }
                .pickerStyle(.menu)
            }
            Picker("Speed", selection: Binding(
                get: { controller.playbackRate },
                set: { rate in
                    storedSpeed = rate
                    controller.setPlaybackRate(rate)
                }
            )) {
                ForEach(PlayerController.playbackSpeeds, id: \.self) { rate in
                    Text(rate == 1 ? "Normal" : PlayerController.speedLabel(rate)).tag(rate)
                }
            }
            .pickerStyle(.menu)
            Picker("Subtitle size", selection: Binding(
                get: { subtitleScale },
                set: { scale in
                    subtitleScale = scale
                    controller.setSubtitleScale(scale)
                }
            )) {
                Text("Small").tag(0.8)
                Text("Normal").tag(1.0)
                Text("Large").tag(1.25)
                Text("Huge").tag(1.5)
            }
            .pickerStyle(.menu)
            // The Mac player's "Subtitle look" tiles, as a list: the same
            // presets, applied at once and kept for the next episode.
            Picker("Subtitle style", selection: Binding(
                get: { SubtitleStyle(rawValue: subtitleStyleRaw) ?? .release },
                set: { style in
                    subtitleStyleRaw = style.rawValue
                    controller.onSetSubtitleStyle?(style)
                }
            )) {
                ForEach(SubtitleStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.menu)
            // Only for a picture wider than the screen: on a 16:9 episode
            // `panscan` crops nothing and the choice would do nothing.
            if (controller.videoAspectRatio ?? 0) > 1.85 {
                Picker("Zoom", selection: Binding(
                    get: { controller.zoomAmount },
                    set: { controller.setZoom($0) }
                )) {
                    Text("Fit").tag(0.0)
                    Text("A little").tag(0.25)
                    Text("Halfway").tag(0.5)
                    Text("Most").tag(0.75)
                    Text("Fill height").tag(1.0)
                }
                .pickerStyle(.menu)
            }
            // Auto-skip is on by default, and while it is the Skip pill never
            // shows: the intro just goes. Here so it can be turned off for one
            // show's opening without leaving the episode for Settings.
            Toggle("Skip intros automatically", isOn: Binding(
                get: { controller.autoSkipEnabled },
                set: { on in if on != controller.autoSkipEnabled { controller.toggleAutoSkip() } }
            ))
            // In the player, not Settings: whether the box keeps up is only
            // known mid-episode, and a stutter should be one click from off.
            Toggle("Upscaling", isOn: Binding(
                get: { controller.isAnime4KEnabled },
                set: { on in if on != controller.isAnime4KEnabled { controller.toggleAnime4K() } }
            ))
            if !controller.chapters.isEmpty {
                Menu {
                    ForEach(controller.chapters) { chapter in
                        Button("\(PlayerController.formatTimestamp(chapter.time))  \(chapter.title)") {
                            controller.seek(to: chapter.time)
                            controller.showControlsBriefly()
                        }
                    }
                } label: {
                    Label("Chapters", anicat: "list.number")
                }
            }
            Button {
                showReleases = true
            } label: {
                Label("Release", anicat: "square.stack.3d.up")
            }
            if controller.hasPreviousEpisode {
                Button("Previous episode") { controller.previousEpisode() }
            }
            Button("Close player", role: .destructive, action: onClose)
        } label: {
            Image(anicat: "ellipsis.circle")
        }
        // A menu open on tvOS is a modal; the chrome under it must not time
        // out and drop focus from under the picker.
        .onChange(of: controller.isMenuOpen) { _, open in
            if open { controller.cancelAutohide() } else { controller.showControlsBriefly() }
        }
        .task { fetchTracks() }
        // The chrome can come up before mpv has opened the file, when the
        // track list is empty. A duration means the file is loaded.
        .onChange(of: controller.duration) { _, duration in
            if duration > 0 { fetchTracks() }
        }
    }

    private var audioSelection: Binding<String> {
        Binding(
            get: { audioTracks.first(where: \.isSelected)?.id ?? "" },
            set: { id in
                controller.onSelectAudioTrack?(id)
                if let track = audioTracks.first(where: { $0.id == id }) {
                    controller.rememberAudioTrack(track)
                }
                fetchTracks()
            }
        )
    }

    private var subtitleSelection: Binding<String> {
        Binding(
            get: { subtitleTracks.first(where: \.isSelected)?.id ?? PlayerTrack.off },
            set: { id in
                let track = subtitleTracks.first(where: { $0.id == id })
                controller.onSelectSubtitleTrack?(id == PlayerTrack.off ? nil : id)
                controller.rememberSubtitleTrack(track)
                fetchTracks()
            }
        )
    }

    private func fetchTracks() {
        controller.onFetchTracks? { audio, subtitle in
            audioTracks = audio
            subtitleTracks = subtitle
        }
    }
}

/// The scrubbed position as a bar with the times at each end. Focusable
/// so the ring can seek from it: a `Slider` does not exist on tvOS, and
/// there is nothing to drag with anyway.
private struct TVTimeline: View {
    let controller: PlayerController
    var focus: FocusState<TVPlayerView.Focus?>.Binding
    let onSeek: (Double) -> Void

    var body: some View {
        HStack(spacing: 24) {
            Text(PlayerController.formatTimestamp(controller.currentTime))
                .font(.system(size: 22)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 130, alignment: .leading)

            TimelineBar(fraction: controller.progressFraction, isFocused: focus.wrappedValue == .timeline)
                .frame(height: 12)
                .frame(maxWidth: .infinity)
                .focusable()
                .focused(focus, equals: .timeline)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: onSeek(-10)
                    case .right: onSeek(10)
                    default: break
                    }
                }

            Text("-" + PlayerController.formatTimestamp(max(0, controller.duration - controller.currentTime)))
                .font(.system(size: 22)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 140, alignment: .trailing)
        }
    }
}

/// The timeline. Thicker and brighter under focus so the viewer can tell
/// the ring is now seeking rather than moving between buttons.
private struct TimelineBar: View {
    let fraction: Double
    let isFocused: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                Capsule()
                    .fill(.white)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
            .frame(height: isFocused ? 12 : 6)
            .frame(maxHeight: .infinity)
            .scaleEffect(y: 1, anchor: .center)
            .animation(.easeOut(duration: 0.15), value: isFocused)
        }
    }
}

/// A button that draws nothing, focused or not. See the focus holder in
/// `TVPlayerView`.
private struct TVInvisibleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif
