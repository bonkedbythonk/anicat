#if os(tvOS)
import AnicatCoreKit
import SwiftUI
import UIKit

/// The player chrome on Apple TV, driven by the Siri Remote.
///
/// The system player is no more usable here than on the phone: every
/// release this app streams is Matroska with ASS subtitles, which
/// `AVFoundation` cannot open, so mpv keeps decoding and this view supplies
/// what the TV app player would have -- transport at the bottom, a timeline,
/// and the remote's own vocabulary:
///
/// Laid out the way the TV app's own player answers the remote, since that
/// is what a viewer's hands expect:
///
/// - Play/Pause, or a press on the clickpad, pauses and plays. Pausing brings
///   the chrome up with the timeline focused.
/// - On the timeline a swipe scrubs a marker through the episode and a press
///   jumps there; a click on either edge jumps ten seconds.
/// - With the chrome down, a click on either edge jumps without bringing it
///   up (a swipe does not seek), down
///   opens the audio and subtitle panel, up brings the chrome.
/// - A click held on either edge rewinds or fast-forwards until let go.
/// - Menu (Back) drops a scrub, then puts the chrome or the seek bar away;
///   then it closes the player.
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
    @State private var showOptions = false
    /// Release picked from the options panel: its sheet opens once the
    /// options sheet has gone, since tvOS will not stack the two.
    @State private var releasesAfterOptions = false
    // Same keys as the phone's menu, so a speed or size picked on one
    // device's player is the one the other starts at.
    @AppStorage("anicat_playback_speed") private var storedSpeed: Double = 1.0

    fileprivate enum Focus: Hashable {
        case surface, back, playPause, forward, timeline, tracks, previous, next, playNextNow, cancelNext
    }
    @FocusState private var focus: Focus?
    @Environment(\.scenePhase) private var scenePhase
    /// A thin timeline shown for a moment after a seek from the hidden
    /// player, which takes no focus and leaves the controls down.
    @State private var seekBarVisible = false
    @State private var seekBarHide: Task<Void, Never>?
    /// When the chrome or the seek bar last went away on its own timer.
    @State private var barGoneAt = Date.distantPast
    @State private var lastSeekPress = Date.distantPast
    @State private var seekDirection: Double = 0
    @State private var seekStreak = 0
    /// Where a swipe on the timeline has put the marker, until a press jumps
    /// there or Back drops it.
    @State private var scrubber = TVScrub()
    /// A held edge click, seeking further every quarter second.
    @State private var holdTask: Task<Void, Never>?
    @State private var holdEndedAt = Date.distantPast

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
                    // A press pauses, as in the TV app; the chrome comes up
                    // with it (`pause` shows it) and stays while paused.
                    PlayerLog.write("[remote] press on the picture: \(controller.isPlaying ? "pause" : "play")")
                    withAnimation(.easeOut(duration: 0.2)) { controller.togglePlayPause() }
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
                    // Left and right are not seeks here: one swipe arrives
                    // as several move commands, each a further accelerated
                    // step, and a quick swipe jumped minutes, "sometimes it
                    // just skips straight to the next ep". Edge clicks seek
                    // through `TVRemoteGestures` instead.
                    switch direction {
                    case .left, .right: break
                    case .down: showOptions = true
                    default: showControls()
                    }
                }
                .ignoresSafeArea()
            }

            TVRemoteGestures(
                holdEnabled: (focus == .surface || focus == .timeline) && !showOptions && !showReleases,
                clicksEnabled: (focus == .surface || focus == .timeline) && !showOptions && !showReleases,
                // The picture is a Button: its own action already toggles.
                selectEnabled: focus == .timeline && !showOptions && !showReleases,
                panEnabled: focus == .timeline && !showOptions && !showReleases,
                onHold: hold,
                onEdgeClick: { direction in
                    // A hold's release also ends as a click.
                    guard Date().timeIntervalSince(holdEndedAt) > 0.3 else { return }
                    scrubber.drop()
                    PlayerLog.write("[remote] edge click \(direction < 0 ? "left" : "right") at \(Int(controller.currentTime))s")
                    if focus == .surface {
                        seekQuietly(by: acceleratedStep(direction))
                    } else {
                        seek(by: acceleratedStep(direction))
                    }
                },
                onSelect: commitScrubOrToggle,
                onPan: scrub
            )
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)

            if controller.isBuffering {
                bufferingIndicator
            }

            skipPill

            if seekBarVisible && !controller.areControlsVisible {
                TVTimeline(controller: controller, focus: $focus, scrub: nil, streamURL: streamURL)
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
            let new = controller.claimPlayPause(fromSystem: false)
            PlayerLog.write("[remote] Play/Pause\(new ? "" : ", already handled")")
            if new || scrubber.time != nil { commitScrubOrToggle() }
        }
        // Menu: chrome up, put it away; chrome down, leave the player. Not
        // wired to `onClose` directly, which would drop a viewer out of the
        // episode when all they wanted was the timeline gone.
        .onExitCommand {
            if scrubber.time != nil {
                withAnimation(.easeOut(duration: 0.15)) { scrubber.drop() }
            } else if controller.nextEpisodeCountdown.isVisible {
                withAnimation(.smooth) { controller.cancelNextEpisodeCountdown() }
            } else if controller.areControlsVisible {
                hideControls()
            } else if seekBarVisible {
                // The thin bar after an edge-click jump is not the chrome, so
                // Back fell through to `onClose`: "when i click back to get
                // rid of the seek bar, i exit the episode".
                seekBarHide?.cancel()
                withAnimation(.easeOut(duration: 0.15)) { seekBarVisible = false }
            } else if Date().timeIntervalSince(barGoneAt) < 1 {
                // A press aimed at a bar that timed out while the thumb was
                // on its way left the episode instead.
                PlayerLog.write("[remote] Back just after the bar hid, ignored")
            } else {
                onClose()
            }
        }
        .sheet(isPresented: $showReleases) { releaseSheet }
        .sheet(isPresented: $showOptions, onDismiss: {
            if releasesAfterOptions {
                releasesAfterOptions = false
                showReleases = true
            } else {
                controller.showControlsBriefly()
            }
        }) {
            TVPlayerOptions(
                controller: controller,
                onReleases: {
                    releasesAfterOptions = true
                    showOptions = false
                },
                onClose: {
                    showOptions = false
                    onClose()
                }
            )
        }
        // The chrome must not time out under the panel and drop focus.
        .onChange(of: showOptions) { _, open in
            if open { controller.cancelAutohide() }
        }
        .task {
            controller.showControlsBriefly()
            focus = .playPause
            if controller.playbackRate != storedSpeed { controller.setPlaybackRate(storedSpeed) }
        }
        // Focus follows the chrome: onto the play button as it comes up, back
        // onto the surface as it goes, since the button it sat on is gone.
        .onChange(of: controller.areControlsVisible) { _, visible in
            focus = visible ? (controller.isPlaying ? .playPause : .timeline) : .surface
            if !visible { scrubber.drop(); barGoneAt = Date() }
            // The bottom fifth is the transport and timeline; the dialogue
            // goes above it while they are up.
            controller.liftSubtitles(by: visible ? 0.2 : 0)
        }
        // Set again on the way back into the app. The pause on leaving
        // brings the chrome up while the app is in the background, where a
        // focus change does not take, so focus was wherever tvOS put it on
        // return. The owner: "it goes to the next ep if i leave the app".
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            focus = controller.areControlsVisible ? .playPause : .surface
        }
        // The card takes the remote: Play now is one press away, Back
        // dismisses it. Left on the surface, a press would only have
        // brought the controls up under it.
        .onChange(of: controller.nextEpisodeCountdown.isVisible) { _, visible in
            focus = visible ? .playNextNow : (controller.areControlsVisible ? .playPause : .surface)
        }
        // Paused from the play button: the timeline takes focus, so the next
        // press plays and a swipe scrubs, as in the TV app.
        .onChange(of: controller.isPlaying) { _, playing in
            if !playing, controller.areControlsVisible, focus == .playPause { focus = .timeline }
        }
        .onAppear {
            controller.commitPendingScrub = {
                guard scrubber.time != nil else { return false }
                commitScrubOrToggle()
                return true
            }
        }
        .onDisappear {
            controller.commitPendingScrub = nil
            holdTask?.cancel()
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
                    TVTimeline(controller: controller, focus: $focus, scrub: scrubber, streamURL: streamURL)
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
                commitScrubOrToggle()
            } label: {
                Image(anicat: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .focused($focus, equals: .playPause)

            Button { seek(by: 10) } label: {
                Image(anicat: "goforward.10")
            }
            .focused($focus, equals: .forward)

            Spacer()

            // Icons, the size of the seek buttons: the labelled "Next
            // episode" was the biggest thing in the row. Previous moved here
            // from the options panel so the pair sits together.
            if controller.hasPreviousEpisode {
                Button { controller.previousEpisode() } label: {
                    Image(anicat: "backward.end.fill")
                }
                .accessibilityLabel("Previous episode")
                .focused($focus, equals: .previous)
            }
            if controller.hasNextEpisode {
                Button { controller.nextEpisode() } label: {
                    Image(anicat: "forward.end.fill")
                }
                .accessibilityLabel("Next episode")
                .focused($focus, equals: .next)
            }

            // A panel of lists, not a `Menu`: on a real Apple TV the menu's
            // nested pickers glitched mid-episode and Back closed the whole
            // menu instead of the submenu it was in.
            Button { showOptions = true } label: {
                Image(anicat: "ellipsis.circle")
            }
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

    /// Clicks at an ordinary pace jump 10 s each; only quick clicks in one
    /// direction jump further, so a long way into an episode is a burst of
    /// clicks rather than a hundred ("i can only skip 10 secs"). The window
    /// was 1.2 s, and clicking 10 s at a time at a normal pace escalated
    /// anyway: "its hard to skip 10 secs at a time if it skips a lot
    /// eventually".
    private func acceleratedStep(_ direction: Double) -> Double {
        let steps: [Double] = [10, 10, 20, 30, 60, 120]
        let now = Date()
        if direction == seekDirection, now.timeIntervalSince(lastSeekPress) < 0.35 {
            seekStreak = min(seekStreak + 1, steps.count - 1)
        } else {
            seekStreak = 0
        }
        seekDirection = direction
        lastSeekPress = now
        return direction * steps[seekStreak]
    }

    private func seekQuietly(by delta: Double) {
        controller.seekRelative(by: delta, showControls: false)
        withAnimation(.easeOut(duration: 0.15)) { seekBarVisible = true }
        seekBarHide?.cancel()
        seekBarHide = Task {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { seekBarVisible = false }
            barGoneAt = Date()
        }
    }

    // MARK: Remote

    /// Play/Pause, a press on the timeline, the play button: with a scrub
    /// pending they jump to it and play from there, otherwise they toggle.
    private func commitScrubOrToggle() {
        // A press is a touch too: the thumb lands and slides before the
        // click, and that slide moved the marker. Logged on the TV with the
        // marker shown at 355.6 s: committed at 397.6 s, the press's own
        // touch having carried it 42 s. A press mid-touch takes the marker
        // from before the touch.
        // While the next episode loads there is nothing to jump in: presses
        // then were logged as "scrub committed at 0.0s", nine in a row.
        if controller.awaitingNewFile { scrubber.drop() }
        if let before = scrubber.markerBeforeTouch {
            scrubber.time = before
        }
        if let target = scrubber.target {
            PlayerLog.write(String(format: "[remote] scrub committed at %.1fs (marker %.1fs)", target, scrubber.time ?? target))
            scrubber.time = nil
            scrubber.consumed = true
            controller.seek(to: target)
            controller.play()
        } else {
            PlayerLog.write("[remote] press: \(controller.isPlaying ? "pause" : "play")")
            controller.togglePlayPause()
        }
        controller.showControlsBriefly()
    }

    /// A swipe across the touch surface moves the marker, further per point
    /// the faster it goes. At one flat rate, set so a swipe crossed a fifth
    /// of the episode, 47 swipes logged on the TV averaged 386 pt and 110 s
    /// and most were corrections of the one before: "the scrubbing feels very
    /// yanky".
    private func scrub(_ translation: CGFloat, _ velocity: CGFloat, _ state: UIGestureRecognizer.State) {
        let loaded = controller.duration > 0 && !controller.awaitingNewFile
        switch state {
        case .began where loaded:
            scrubber.begin(at: controller.currentTime)
            controller.cancelAutohide()
        case .changed where loaded:
            scrubber.move(to: translation, speed: abs(velocity), duration: controller.duration)
        case .ended, .cancelled:
            PlayerLog.write(scrubber.end(translation))
            controller.showControlsBriefly()
        default: break
        }
    }

    /// Rewind or fast-forward while an edge click is held: a jump every
    /// quarter second, each further than the last, up to a minute.
    private func hold(_ direction: Double, _ began: Bool) {
        holdTask?.cancel()
        holdTask = nil
        guard began else {
            holdEndedAt = Date()
            PlayerLog.write(String(format: "[remote] hold ended at %.1fs", controller.currentTime))
            return
        }
        PlayerLog.write("[remote] hold \(direction < 0 ? "rewind" : "fast-forward") from \(Int(controller.currentTime))s")
        scrubber.drop()
        holdTask = Task { @MainActor in
            let steps: [Double] = [5, 5, 10, 10, 20, 20, 30, 45, 60]
            var tick = 0
            while !Task.isCancelled {
                let step = direction * steps[min(tick / 2, steps.count - 1)]
                if controller.areControlsVisible {
                    controller.seekRelative(by: step)
                } else {
                    seekQuietly(by: step)
                }
                tick += 1
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    // MARK: Skip intro / outro

    /// Offered as a button the remote can reach. Focus is not stolen for
    /// it: the surface keeps the ring, and the pill is one move up.
    @ViewBuilder
    private var skipPill: some View {
        // The first 8 s of the window, and again while the controls are up.
        // Shown for the whole ending, it sat over the credits and took the
        // remote's presses for anyone who meant to watch them.
        if let window = controller.activeSkipWindow, !controller.autoSkipEnabled,
           controller.areControlsVisible || controller.currentTime - window.start < 8 {
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
            // Until the first frame, the title too: the screen was plain
            // black for the half second before it, which on a real Apple TV
            // read as part of the TV's own mode switch.
            if controller.awaitingNewFile || controller.currentTime < 0.5 {
                Text(controller.title)
                    .font(.sumiHeading(size: 44, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 1200)
                if controller.episodeNumber > 0, !controller.isLiveAction || !controller.episodeTitle.isEmpty {
                    Text(controller.episodeTitle.isEmpty ? "Episode \(controller.episodeNumber)" : "Episode \(controller.episodeNumber) · \(controller.episodeTitle)")
                        .font(.system(size: 24))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .padding(.bottom, 12)
                }
            }
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

/// The player's options (audio, subtitles, speed, look, release) as a
/// sheet with a navigation stack: each choice is a list one level down,
/// and Back steps up one level at a time, as in the system Settings.
private struct TVPlayerOptions: View {
    @Bindable var controller: PlayerController
    let onReleases: () -> Void
    let onClose: () -> Void

    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    // Same keys as the phone's and the Mac's menus, so a speed, size or look
    // picked on one device's player is the one the others start at.
    @AppStorage("anicat_playback_speed") private var storedSpeed: Double = 1.0
    @AppStorage("anicat_sub_dub") private var storedSubDub: String = "Subtitled"
    @AppStorage(PlayerController.subtitleScaleKey) private var subtitleScale: Double = 1.0
    @AppStorage(SubtitleStyle.key) private var subtitleStyleRaw: String = SubtitleStyle.release.rawValue

    private static let sizes: [(Double, String)] = [(0.8, "Small"), (1.0, "Normal"), (1.25, "Large"), (1.5, "Huge")]
    private static let zooms: [(Double, String)] = [(0, "Fit"), (0.25, "A little"), (0.5, "Halfway"), (0.75, "Most"), (1, "Fill height")]

    var body: some View {
        NavigationStack {
            List {
                // The phone's Language row. Without it the only way to the
                // dub mid-episode was picking a DUB release by hand: "i cant
                // seem to switch to dub mid episode smoothly". Films and TV
                // have no sub/dub split.
                if AppModel.shared?.currentPlaybackCatalog == .anilist {
                    choice("Language", [("Subtitled", "Sub"), ("Dubbed", "Dub")], selected: storedSubDub) { option in
                        storedSubDub = option
                        let wantsDub = option == "Dubbed"
                        controller.onSelectAudioLanguage?(wantsDub) { switched in
                            fetchTracks()
                            // No such track in this file: find a release that
                            // has one, from where the viewer is.
                            if !switched { controller.onReloadForAudioLanguage?(wantsDub) }
                        }
                    }
                }
                // For anime, Language above is the audio control unless the
                // file has a choice it cannot name (see `needsAudioPicker`).
                if !audioTracks.isEmpty,
                   AppModel.shared?.currentPlaybackCatalog != .anilist || PlayerTrack.needsAudioPicker(audioTracks) {
                    choice("Audio", audioTracks.map { ($0.id, $0.label) },
                           selected: audioTracks.first(where: \.isSelected)?.id ?? "") { id in
                        controller.onSelectAudioTrack?(id)
                        if let track = audioTracks.first(where: { $0.id == id }) { controller.rememberAudioTrack(track) }
                        fetchTracks()
                    }
                }
                if !subtitleTracks.isEmpty {
                    choice("Subtitles", [(PlayerTrack.off, "Off")] + subtitleTracks.map { ($0.id, $0.label) },
                           selected: subtitleTracks.first(where: \.isSelected)?.id ?? PlayerTrack.off) { id in
                        controller.onSelectSubtitleTrack?(id == PlayerTrack.off ? nil : id)
                        controller.rememberSubtitleTrack(subtitleTracks.first(where: { $0.id == id }))
                        fetchTracks()
                    }
                }
                choice("Speed", PlayerController.playbackSpeeds.map { ($0, $0 == 1 ? "Normal" : PlayerController.speedLabel($0)) },
                       selected: controller.playbackRate) { rate in
                    storedSpeed = rate
                    controller.setPlaybackRate(rate)
                }
                choice("Subtitle size", Self.sizes, selected: subtitleScale) { scale in
                    subtitleScale = scale
                    controller.setSubtitleScale(scale)
                }
                // The Mac player's "Subtitle look" presets.
                choice("Subtitle style", SubtitleStyle.allCases.map { ($0.rawValue, $0.label) },
                       selected: subtitleStyleRaw) { raw in
                    subtitleStyleRaw = raw
                    controller.onSetSubtitleStyle?(SubtitleStyle(rawValue: raw) ?? .release)
                }
                // Only for a picture wider than the screen: on a 16:9 episode
                // `panscan` crops nothing and the choice would do nothing.
                if (controller.videoAspectRatio ?? 0) > 1.85 {
                    choice("Zoom", Self.zooms, selected: controller.zoomAmount) { controller.setZoom($0) }
                }
                // Auto-skip is on by default, and while it is the Skip pill
                // never shows. Here so one show's opening can be kept without
                // leaving the episode for Settings.
                Toggle("Skip intros automatically", isOn: Binding(
                    get: { controller.autoSkipEnabled },
                    set: { on in if on != controller.autoSkipEnabled { controller.toggleAutoSkip() } }
                ))
                // In the player, not Settings: whether the box keeps up is only
                // known mid-episode, and a stutter should be one press from off.
                Toggle("Upscaling", isOn: Binding(
                    get: { controller.isAnime4KEnabled },
                    set: { on in if on != controller.isAnime4KEnabled { controller.toggleAnime4K() } }
                ))
                if !controller.chapters.isEmpty {
                    NavigationLink("Chapters") {
                        TVChoiceList(
                            title: "Chapters",
                            options: controller.chapters.map { ($0.time, "\(PlayerController.formatTimestamp($0.time))  \($0.title)") },
                            selected: nil
                        ) { controller.seek(to: $0) }
                    }
                }
                Button("Release", action: onReleases)
                Button("Close player", role: .destructive, action: onClose)
            }
            .navigationTitle("Options")
            // The focused row grows, and against the sheet's own edges
            // its sides were cut off.
            .padding(.horizontal, 40)
        }
        .task { fetchTracks() }
    }

    /// One row showing the current value, opening its list of choices.
    private func choice<T: Hashable>(
        _ title: String,
        _ options: [(T, String)],
        selected: T,
        pick: @escaping (T) -> Void
    ) -> some View {
        NavigationLink {
            TVChoiceList(title: title, options: options, selected: selected, pick: pick)
        } label: {
            LabeledContent(title, value: options.first(where: { $0.0 == selected })?.1 ?? "")
        }
    }

    private func fetchTracks() {
        controller.onFetchTracks? { audio, subtitle in
            audioTracks = audio
            subtitleTracks = subtitle
        }
    }
}

/// One level of `TVPlayerOptions`: the choices with a checkmark on the
/// current one. Picking steps back up, so a second Back leaves the panel.
private struct TVChoiceList<T: Hashable>: View {
    let title: String
    let options: [(T, String)]
    let selected: T?
    let pick: (T) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List(options.indices, id: \.self) { index in
            let option = options[index]
            Button {
                pick(option.0)
                dismiss()
            } label: {
                HStack {
                    Text(option.1)
                    Spacer()
                    if option.0 == selected {
                        Image(anicat: "checkmark")
                    }
                }
            }
        }
        .navigationTitle(title)
        .padding(.horizontal, 40)
    }
}

/// The marker a swipe moves. An object rather than the player's own state:
/// it changes with every touch event, and as `@State` of `TVPlayerView` each
/// one redrew the whole player. Only `TVTimeline` reads it while drawing.
@MainActor
@Observable
private final class TVScrub {
    /// Where the marker is, nil when there is none. Press jumps there.
    var time: Double?
    /// The marker as it stood before the touch now on the surface, nil when
    /// no touch is under way. See `commitScrubOrToggle`.
    @ObservationIgnored var markerBeforeTouch: Double??
    /// A press lands mid-swipe: the finger was still moving, and the marker
    /// went on after the jump. Logged on the TV: committed at 417.5 s with
    /// the marker shown at 444.2 s, then the rest of the swipe left a new
    /// marker behind. The swipe ends at the press.
    @ObservationIgnored var consumed = false
    /// The picture's own time for the marker it was made for. It is the
    /// keyframe at or before the marker, and on an x265 release keyframes
    /// were measured up to 43.2 s apart (83 gaps over 10 s in one episode):
    /// the viewer aimed by the picture and landed up to 43 s after it,
    /// "always random". The marker snaps to the picture and a press lands
    /// on what it shows.
    var snapped: (marker: Double, picture: Double)?

    /// Where a press lands: the shown picture's time, else the marker.
    var target: Double? {
        guard let time else { return nil }
        if let snapped, snapped.marker == time { return snapped.picture }
        return time
    }
    @ObservationIgnored private var base = 0.0
    @ObservationIgnored private var last: CGFloat?
    @ObservationIgnored private var fastest: CGFloat = 0
    @ObservationIgnored private var moves = 0
    @ObservationIgnored private var longestGap = 0.0
    @ObservationIgnored private var lastMove = Date()

    func begin(at current: Double) {
        markerBeforeTouch = .some(time)
        base = time ?? current
        consumed = false
        last = nil
        fastest = 0
        moves = 0
        longestGap = 0
        lastMove = Date()
    }

    /// Puts the marker away, and ends the touch that was moving it. Without
    /// the second half a marker outlived the controls it was shown on: a
    /// press on the TV jumped from 562 s to 690.4 s, a marker put away 7 s
    /// before.
    func drop() {
        time = nil
        markerBeforeTouch = nil
        consumed = true
    }

    func move(to translation: CGFloat, speed: CGFloat, duration: Double) {
        let now = Date()
        longestGap = max(longestGap, now.timeIntervalSince(lastMove))
        lastMove = now
        moves += 1
        fastest = max(fastest, speed)
        guard !consumed, markerBeforeTouch != nil else { return }
        guard let last else {
            // A click rolls the finger a few points, and a thumb left on the
            // surface after pausing drifts: 24 to 84 pt within 2 s of four
            // of five pauses logged, each leaving a marker that the press to
            // play then jumped to. So the first marker takes a real swipe.
            if abs(translation) > (time == nil ? 100 : 20) { self.last = translation }
            return
        }
        self.last = translation
        // Logged on the TV: careful swipes peak near 1,500 pt/s, ordinary
        // ones at 4,000 to 5,000, flicks at 9,000. Slow crosses the episode
        // in 20,000 pt, a flick in 6,000. Kept to about three to one: at
        // five to one a swipe that came back ended 71 s off, 80 pt from
        // where it began.
        let quick = min(max((speed - 1000) / 7000, 0), 1)
        let perPoint = 1 / 20000 + Double(quick) * (1 / 6000 - 1 / 20000)
        time = min(max((time ?? base) + Double(translation - last) * perPoint * duration, 0), duration)
    }

    /// Ends the touch; the log line the gain is tuned from.
    func end(_ translation: CGFloat) -> String {
        markerBeforeTouch = nil
        return String(format: "[remote] swipe %.0f pt from %.1fs, marker at %.1fs, peak %.0f pt/s, %d moves, longest gap %.0f ms%@",
                      translation, base, time ?? -1, fastest, moves, longestGap * 1000, consumed ? " (after a press)" : "")
    }
}

/// The picture over the scrub marker. One is made at a time and always for
/// the newest position, so a fast swipe skips the ones in between.
@MainActor
@Observable
private final class TVScrubPictures {
    private(set) var image: CGImage?
    @ObservationIgnored private let frames = ScrubFrames()
    @ObservationIgnored private var wanted: Double?
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var made = 0
    @ObservationIgnored private var slowest = 0.0

    func show(at time: Double, of duration: Double, from url: URL, for scrub: TVScrub) {
        wanted = time
        guard work == nil else { return }
        work = Task { [frames] in
            while let time = wanted, !Task.isCancelled {
                wanted = nil
                let began = Date()
                let engine = AppModel.shared?.engine
                // Asked of the engine, not read off the controller: its map
                // moves with playback, and a scrub is mostly on a pause.
                let here = await Task.detached { Self.isDownloaded(time / duration, url: url, engine: engine) }.value
                let picture = here ? await frames.picture(url: url.isFileURL ? url.path : url.absoluteString, at: time) : nil
                guard !Task.isCancelled else { return }
                image = picture?.image
                scrub.snapped = picture.map { (time, $0.time) }
                if picture != nil {
                    made += 1
                    slowest = max(slowest, Date().timeIntervalSince(began))
                }
                // Twelve a second at most: the episode is being decoded and
                // upscaled on the same box.
                try? await Task.sleep(for: .milliseconds(80))
            }
            // Cancelled, `work` is already the next scrub's.
            if !Task.isCancelled { work = nil }
        }
    }

    func clear() {
        work?.cancel()
        work = nil
        wanted = nil
        image = nil
        frames.close()
        if made > 0 { PlayerLog.write("[scrub] \(made) pictures, slowest \(Int(slowest * 1000)) ms") }
        made = 0
        slowest = 0
    }

    /// Only what the torrent already has: a picture of anything else would
    /// pull pieces ahead of the ones the episode needs next.
    private nonisolated static func isDownloaded(_ fraction: Double, url: URL, engine: AnicatEngine?) -> Bool {
        guard url.path == "/torrent-stream", let engine else { return true }
        // A share of the file's bytes, not of its time, hence the slack.
        return engine.playingFileBuffered().contains {
            $0.start <= fraction && (fraction + 0.01 <= $0.end || $0.end > 0.999)
        }
    }
}

/// The scrubbed position as a bar with the times at each end. Focusable
/// so the ring can seek from it: a `Slider` does not exist on tvOS, and
/// there is nothing to drag with anyway.
private struct TVTimeline: View {
    let controller: PlayerController
    var focus: FocusState<TVPlayerView.Focus?>.Binding
    /// Where a swipe has put the marker, nil when there is no scrub.
    let scrub: TVScrub?
    let streamURL: URL
    @State private var pictures = TVScrubPictures()

    var body: some View {
        let scrubTime = scrub?.target
        HStack(spacing: 24) {
            Text(PlayerController.formatTimestamp(controller.currentTime))
                .font(.system(size: 22)).monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 130, alignment: .leading)

            // Edges and swipes on it come through `TVRemoteGestures`: its own
            // move command could not tell a swipe from a click.
            TimelineBar(
                fraction: controller.progressFraction,
                scrubFraction: scrubTime.map { controller.duration > 0 ? $0 / controller.duration : 0 },
                scrubLabel: scrubTime.map { PlayerController.formatTimestamp($0) },
                picture: pictures.image,
                isFocused: focus.wrappedValue == .timeline
            )
                .onChange(of: scrub?.time) { _, time in
                    if let time, let scrub {
                        pictures.show(at: time, of: controller.duration, from: streamURL, for: scrub)
                    } else {
                        pictures.clear()
                    }
                }
                .frame(height: 12)
                .frame(maxWidth: .infinity)
                .focusable()
                .focused(focus, equals: .timeline)

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
    var scrubFraction: Double?
    var scrubLabel: String?
    var picture: CGImage?
    let isFocused: Bool

    private static let pictureWidth: CGFloat = 384

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                Capsule()
                    .fill(.white)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
            .overlay(alignment: .leading) {
                // The marker a swipe moves, with the time it would jump to.
                if let scrubFraction, let scrubLabel {
                    let x = geo.size.width * min(max(scrubFraction, 0), 1)
                    // Its own leading stack: `overlay` centres several views
                    // on each other first, which drew the marker half the
                    // label's width to the right of where a press jumped
                    // (40 px rendered, 97 with the wider label).
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(.white)
                            .frame(width: 6, height: 36)
                            .offset(x: x - 3)
                        Text(scrubLabel)
                            .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            // A fixed box keeps the time centred on the
                            // marker whatever its width.
                            .frame(width: 200)
                            .offset(x: x - 100, y: -52)
                        if let picture {
                            // Kept on the bar at either end, where the
                            // marker itself goes on to the edge.
                            let half = Self.pictureWidth / 2
                            let height = Self.pictureWidth * CGFloat(picture.height) / CGFloat(picture.width)
                            Image(decorative: picture, scale: 1)
                                .resizable()
                                .frame(width: Self.pictureWidth, height: height)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.3), lineWidth: 2))
                                .offset(x: min(max(x, half), max(geo.size.width - half, half)) - half, y: -86 - height / 2)
                        }
                    }
                }
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
