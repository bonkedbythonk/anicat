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

    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    @State private var releases: [MediaDetailView.ReleaseCandidateItem] = []
    @State private var releaseFailure: String?
    @State private var isLoadingReleases = false
    @State private var showReleases = false

    private enum Focus: Hashable {
        case surface, back, playPause, forward, timeline, tracks, next
    }
    @FocusState private var focus: Focus?

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
                .buttonStyle(.plain)
                .focused($focus, equals: .surface)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: seek(by: -10)
                    case .right: seek(by: 10)
                    default: showControls()
                    }
                }
                .ignoresSafeArea()
            }

            if controller.isBuffering {
                bufferingIndicator
            }

            skipPill

            if controller.areControlsVisible {
                controls
                    .transition(.opacity)
            }
        }
        .onPlayPauseCommand {
            controller.togglePlayPause()
            controller.showControlsBriefly()
        }
        // Menu: chrome up, put it away; chrome down, leave the player. Not
        // wired to `onClose` directly, which would drop a viewer out of the
        // episode when all they wanted was the timeline gone.
        .onExitCommand {
            if controller.areControlsVisible {
                hideControls()
            } else {
                onClose()
            }
        }
        .sheet(isPresented: $showReleases) { releaseSheet }
        .task {
            controller.showControlsBriefly()
            focus = .playPause
            fetchTracks()
        }
        // The `task` above runs before mpv has opened the file, when the
        // track list is empty. A duration means the file is loaded.
        .onChange(of: controller.duration) { _, duration in
            if duration > 0 { fetchTracks() }
        }
        // Focus follows the chrome: onto the play button as it comes up, back
        // onto the surface as it goes, since the button it sat on is gone.
        .onChange(of: controller.areControlsVisible) { _, visible in
            focus = visible ? .playPause : .surface
        }
        .onDisappear { controller.cancelAutohide() }
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
                    timeline
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

    /// The scrubbed position as a bar with the times at each end. Focusable
    /// so the ring can seek from it: a `Slider` does not exist on tvOS, and
    /// there is nothing to drag with anyway.
    @ViewBuilder
    private var timeline: some View {
        HStack(spacing: 24) {
            Text(PlayerController.formatTimestamp(controller.currentTime))
                .font(.system(size: 22, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 130, alignment: .leading)

            TimelineBar(fraction: controller.progressFraction, isFocused: focus == .timeline)
                .frame(height: 12)
                .frame(maxWidth: .infinity)
                .focusable()
                .focused($focus, equals: .timeline)
                .onMoveCommand { direction in
                    switch direction {
                    case .left: seek(by: -10)
                    case .right: seek(by: 10)
                    default: break
                    }
                }

            Text("-" + PlayerController.formatTimestamp(max(0, controller.duration - controller.currentTime)))
                .font(.system(size: 22, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 140, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 40) {
            Button { seek(by: -10) } label: {
                Image(systemName: "gobackward.10")
            }
            .focused($focus, equals: .back)

            Button {
                controller.togglePlayPause()
                controller.showControlsBriefly()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
            }
            .focused($focus, equals: .playPause)

            Button { seek(by: 10) } label: {
                Image(systemName: "goforward.10")
            }
            .focused($focus, equals: .forward)

            Spacer()

            if controller.hasNextEpisode {
                Button {
                    controller.nextEpisode()
                } label: {
                    Label("Next episode", systemImage: "forward.end.fill")
                }
                .focused($focus, equals: .next)
            }

            tracksMenu
                .focused($focus, equals: .tracks)
        }
        .font(.system(size: 30))
        .focusSection()
    }

    @ViewBuilder
    private var tracksMenu: some View {
        Menu {
            if !audioTracks.isEmpty {
                Picker("Audio", selection: audioSelection) {
                    ForEach(audioTracks) { track in
                        Text(track.label).tag(track.id)
                    }
                }
            }
            if !subtitleTracks.isEmpty {
                Picker("Subtitles", selection: subtitleSelection) {
                    Text("Off").tag(PlayerTrack.off)
                    ForEach(subtitleTracks) { track in
                        Text(track.label).tag(track.id)
                    }
                }
            }
            Button {
                showReleases = true
            } label: {
                Label("Release", systemImage: "square.stack.3d.up")
            }
            if controller.hasPreviousEpisode {
                Button("Previous episode") { controller.previousEpisode() }
            }
            Button("Close player", role: .destructive, action: onClose)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        // A menu open on tvOS is a modal; the chrome under it must not time
        // out and drop focus from under the picker.
        .onChange(of: controller.isMenuOpen) { _, open in
            if open { controller.cancelAutohide() } else { controller.showControlsBriefly() }
        }
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
                    ContentUnavailableView("Could not list releases", systemImage: "exclamationmark.triangle", description: Text(releaseFailure))
                } else if releases.isEmpty {
                    ContentUnavailableView("No other releases", systemImage: "square.stack.3d.up.slash")
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
                                        .font(.system(size: 20, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                    if release.name == controller.rememberedReleaseName {
                                        Text("Played last time")
                                            .font(.system(size: 18, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 8)
                                if release.name == controller.currentReleaseName {
                                    Image(systemName: "checkmark")
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

    private func seek(by delta: Double) {
        controller.seekRelative(by: delta)
        controller.showControlsBriefly()
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
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            } else if let percent = controller.bufferingPercent {
                Text("\(percent)%")
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            } else if let seconds = controller.resolveElapsedSeconds {
                Text(PlayerController.withElapsed("Searching indexers", seconds))
                    .font(.system(size: 22, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
        .allowsHitTesting(false)
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
#endif
