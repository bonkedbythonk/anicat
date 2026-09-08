#if os(iOS)
import SwiftUI

/// The player chrome on iPhone, shaped like `AVPlayerViewController`'s.
///
/// The system player itself is not usable here: `AVFoundation` has no
/// Matroska demuxer, no ASS renderer and no way to use a file's embedded
/// font attachments, and every release this app streams is MKV — the one
/// measured on 2026-09-08 was h264 + aac + ass with nine TTF attachments.
/// Pointing `AVPlayerViewController` at the range server does not degrade,
/// it fails to open the file. So mpv keeps decoding and this view supplies
/// the layout, gestures and controls people expect from the system player.
///
/// `PlayerView` stays the macOS chrome. Splitting rather than adding `#if`
/// branches to its 1700 lines: almost nothing survives the crossing — no
/// hover, no key monitor, no mini-player, no Anime4K row (iOS never runs
/// shaders), no window to resize.
struct PhonePlayerView: View {
    @Bindable var controller: PlayerController
    let streamURL: URL
    let onClose: () -> Void

    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    @State private var scrubTarget: Double?
    @State private var releases: [MediaDetailView.ReleaseCandidateItem] = []
    @State private var releaseFailure: String?
    @State private var isLoadingReleases = false
    @State private var showReleases = false
    /// How far the sheet has been dragged down, and the drag's own state.
    @State private var dismissOffset: CGFloat = 0
    @State private var flash: (symbol: String, trailing: Bool)?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // The one mount site. `MpvSurface`'s dismantle path stops
            // playback, so this must never move between branches of an
            // `if`, which is the failure `PlayerView` records on macOS.
            MpvSurface(controller: controller, streamURL: streamURL, cornerRadius: 0)
                .ignoresSafeArea()

            // Gestures live on a clear layer above the surface, not on the
            // ZStack around it. `MpvEventCatcherView` is topmost inside the
            // host view and carries its own tap recognizer, so a tap handled
            // further out never arrived — it was swallowed and turned into a
            // play/pause toggle instead of showing the controls.
            gestureLayer

            if controller.isBuffering {
                bufferingIndicator
            }

            skipPill

            if controller.areControlsVisible {
                controls
                    .transition(.opacity)
            }

            if let flash {
                seekFlash(symbol: flash.symbol, trailing: flash.trailing)
            }
        }
        // Swipe down to dismiss, the way the system player does. The whole
        // stack moves with the finger and fades as it goes, so the gesture
        // reads as dragging the player off rather than as a scroll that
        // happens to close something.
        .offset(y: dismissOffset)
        .scaleEffect(1 - min(dismissOffset / 2400, 0.08))
        .opacity(1 - min(dismissOffset / 700, 0.55))
        .gesture(dismissDrag)
        .statusBarHidden(!controller.areControlsVisible)
        .sheet(isPresented: $showReleases) { releaseSheet }
        .task {
            controller.showControlsBriefly()
            fetchTracks()
        }
        // The `task` above runs when the view appears, which is before mpv
        // has opened the file — the track list was empty every time and the
        // menu showed neither Audio nor Subtitles. A duration means the file
        // is loaded and its tracks can be enumerated.
        .onChange(of: controller.duration) { _, duration in
            if duration > 0 { fetchTracks() }
        }
        .onDisappear { controller.cancelAutohide() }
    }

    // MARK: Controls

    @ViewBuilder
    private var controls: some View {
        ZStack {
            // Scrims rather than a flat dim: white glyphs over a bright frame
            // are unreadable without one, and dimming the whole picture to
            // fix that is what the system player pointedly does not do.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.55), .clear],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 120)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.65)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack {
                topBar
                Spacer()
                transport
                Spacer()
                bottomBar
            }
            // The picture is full-bleed; the controls are not. Fixed padding
            // put the top row under the Dynamic Island and the scrubber under
            // the home indicator on a real phone — in landscape the notch
            // inset lands on a *side*, which no horizontal constant can know
            // about. `safeAreaPadding` is the only thing that does.
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .safeAreaPadding(.all)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 14) {
            Button(action: onClose) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .playerGlass(in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !controller.episodeTitle.isEmpty {
                    Text("Episode \(controller.episodeNumber) · \(controller.episodeTitle)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            tracksMenu
        }
    }

    @ViewBuilder
    private var tracksMenu: some View {
        Menu {
            if !audioTracks.isEmpty {
                Picker("Audio", selection: audioSelection) {
                    ForEach(audioTracks) { track in
                        Text(label(for: track)).tag(track.id)
                    }
                }
            }
            if !subtitleTracks.isEmpty {
                Picker("Subtitles", selection: subtitleSelection) {
                    Text("Off").tag(PlayerTrack.off)
                    ForEach(subtitleTracks) { track in
                        Text(label(for: track)).tag(track.id)
                    }
                }
            }
            Button {
                showReleases = true
            } label: {
                Label("Release", systemImage: "square.stack.3d.up")
            }

            if controller.hasNextEpisode {
                Button("Next episode") { controller.nextEpisode() }
            }
            if controller.hasPreviousEpisode {
                Button("Previous episode") { controller.previousEpisode() }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(.black.opacity(0.35), in: Circle())
        }

    }

    /// Which release is being streamed. The engine races candidates and
    /// picks one; this is how a viewer overrides that — a different group, a
    /// dub, a better-seeded copy.
    ///
    /// A sheet, not a submenu. `Menu` content is built eagerly, so anything
    /// hung off its `onAppear` runs at first render: the fetch fired on every
    /// play, and the autohide cancel that sat beside it killed the timer once
    /// and left the controls up for the whole episode. A sheet's `task` runs
    /// when it is actually presented, and release names need the width.
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
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(release.name)
                                        .font(.system(size: 13))
                                        .lineLimit(2)
                                    Text(Self.releaseDetail(release))
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showReleases = false }
                }
            }
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

    private func label(for track: PlayerTrack) -> String {
        let name = track.title ?? track.lang ?? "Track \(track.id)"
        return track.isForced ? "\(name) (forced)" : name
    }

    private func fetchTracks() {
        controller.onFetchTracks? { audio, subtitle in
            audioTracks = audio
            subtitleTracks = subtitle
        }
    }

    @ViewBuilder
    private var transport: some View {
        HStack(spacing: 46) {
            Button { seek(by: -10) } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 30, weight: .regular))
            }
            Button {
                controller.togglePlayPause()
                controller.showControlsBriefly()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .regular))
                    .frame(width: 54, height: 54)
            }
            Button { seek(by: 10) } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 30, weight: .regular))
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private var bottomBar: some View {
        HStack(spacing: 12) {
            Text(Self.timestamp(scrubTarget ?? controller.currentTime))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 46, alignment: .leading)

            Scrubber(
                value: scrubTarget ?? controller.currentTime,
                duration: max(controller.duration, 0.001),
                onScrub: { value in
                    scrubTarget = value
                    controller.isScrubbing = true
                    controller.cancelAutohide()
                },
                onCommit: { value in
                    controller.seek(to: value)
                    scrubTarget = nil
                    controller.isScrubbing = false
                    controller.showControlsBriefly()
                }
            )
            .frame(height: 28)

            // Remaining, not total: the system player shows what is left and
            // that is the number people are actually reading.
            Text("-" + Self.timestamp(max(0, controller.duration - (scrubTarget ?? controller.currentTime))))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 50, alignment: .trailing)
        }
    }

    // MARK: Skip intro / outro

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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .background(.white.opacity(0.92), in: Capsule())
                            .compositingGroup()
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, controller.areControlsVisible ? 96 : 26)
            .safeAreaPadding(.all)
        }
    }

    // MARK: Gestures

    @ViewBuilder
    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                // Simultaneous, not sequential. Declaring the double tap
                // ahead of the single one makes SwiftUI hold every single tap
                // for the double-tap timeout before acting on it — which on
                // a phone reads as the controls being slow, and sometimes as
                // them not responding at all. Both recognisers now fire
                // independently: the first tap shows the controls at once and
                // a second one seeks.
                .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { event in
                    let location = event.location
                    let trailing = location.x > geo.size.width / 2
                    seek(by: trailing ? 10 : -10)
                    withAnimation(.easeOut(duration: 0.12)) {
                        flash = (trailing ? "goforward.10" : "gobackward.10", trailing)
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        withAnimation(.easeIn(duration: 0.2)) { flash = nil }
                    }
                })
                // Tap shows the controls; it does not toggle playback. The
                // system player behaves the same way, and a tap that pauses
                // is the thing people hit by accident reaching for a button.
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if controller.areControlsVisible {
                            controller.areControlsVisible = false
                            controller.cancelAutohide()
                        } else {
                            controller.showControlsBriefly()
                        }
                    }
                }
        }
        .ignoresSafeArea()
    }

    /// Downward drags only, and only from a real vertical intent: a
    /// `minimumDistance` of 0 here would steal the scrubber's own drag and
    /// the double-tap, and an unclamped translation would let the player be
    /// thrown upward off the top of the screen.
    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { drag in
                guard drag.translation.height > 0,
                      abs(drag.translation.height) > abs(drag.translation.width)
                else { return }
                dismissOffset = drag.translation.height
            }
            .onEnded { drag in
                // Distance or throw: a short flick dismisses as readily as a
                // long slow drag, which is what the system player does.
                let far = drag.translation.height > 140
                let fast = drag.predictedEndTranslation.height > 420
                if far || fast {
                    withAnimation(.easeIn(duration: 0.18)) {
                        dismissOffset = 1200
                    }
                    onClose()
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.85)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    private func seek(by delta: Double) {
        controller.seekRelative(by: delta)
        controller.showControlsBriefly()
    }

    @ViewBuilder
    private func seekFlash(symbol: String, trailing: Bool) -> some View {
        HStack {
            if trailing { Spacer() }
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.white)
                .padding(26)
                .playerGlass(in: Circle())
            if !trailing { Spacer() }
        }
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var bufferingIndicator: some View {
        VStack(spacing: 10) {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.white)
            if let percent = controller.bufferingPercent {
                Text("\(percent)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    static func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}

/// The scrub bar. A `Slider` was tried first and rejected: its thumb is a
/// fixed 27pt circle that cannot be shrunk to the system player's hairline
/// bead, and its track ignores `tint` on iOS 17 when the view is inside a
/// dark overlay.
private struct Scrubber: View {
    let value: Double
    let duration: Double
    let onScrub: (Double) -> Void
    let onCommit: (Double) -> Void

    @State private var isDragging = false

    var body: some View {
        GeometryReader { geo in
            let fraction = min(max(value / duration, 0), 1)
            let width = geo.size.width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.28))
                    .frame(height: isDragging ? 7 : 4)
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction, height: isDragging ? 7 : 4)
                Circle()
                    .fill(.white)
                    .frame(width: isDragging ? 15 : 11)
                    .offset(x: width * fraction - (isDragging ? 7.5 : 5.5))
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            withAnimation(.easeOut(duration: 0.12)) { isDragging = true }
                        }
                        onScrub(min(max(drag.location.x / width, 0), 1) * duration)
                    }
                    .onEnded { drag in
                        withAnimation(.easeOut(duration: 0.15)) { isDragging = false }
                        onCommit(min(max(drag.location.x / width, 0), 1) * duration)
                    }
            )
        }
    }
}

/// iOS 26 draws system player chrome on Liquid Glass. `glassEffect` only
/// exists there, and the deployment target is 17, so the pre-26 fallback is
/// the flat scrim these controls used to carry.
private extension View {
    @ViewBuilder
    func playerGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.black.opacity(0.35), in: shape)
        }
    }
}
#endif
