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
    /// A bar above the tab bar with the picture as a thumbnail, the same
    /// surface at a different frame. Never an `if` around the surface.
    var isMinimized: Bool = false
    var onMinimize: () -> Void = {}
    var onRestore: () -> Void = {}
    let onClose: () -> Void

    static let miniBarHeight: CGFloat = 64
    static let speeds: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    @State private var audioTracks: [PlayerTrack] = []
    @State private var subtitleTracks: [PlayerTrack] = []
    @State private var scrubTarget: Double?
    @State private var releases: [MediaDetailView.ReleaseCandidateItem] = []
    @State private var releaseFailure: String?
    @State private var isLoadingReleases = false
    @State private var showReleases = false
    @State private var flash: (symbol: String, trailing: Bool)?
    /// A swipe HUD: brightness, volume, the scrub target or the held 2x.
    @State private var hud: Hud?
    @State private var dragAxis: DragAxis?
    @State private var dragStartValue: Double = 0
    @State private var holdTask: Task<Void, Never>?
    @State private var tapTask: Task<Void, Never>?
    @State private var touchDown = false
    @State private var heldSpeed = false
    /// Persisted, unlike the Mac's: a phone is picked up for one episode
    /// at a time and 1.25x chosen once is meant for every one after it.
    @AppStorage("anicat_playback_speed") private var storedSpeed: Double = 1.0
    @AppStorage(PlayerController.subtitleScaleKey) private var subtitleScale: Double = 1.0

    enum DragAxis { case horizontal, brightness, volume }

    struct Hud: Equatable {
        let symbol: String
        let text: String
        var fraction: Double? = nil
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if !isMinimized {
                Color.black.ignoresSafeArea()
                    .transition(.opacity)
            }

            // The one mount site. `MpvSurface`'s dismantle path stops
            // playback, so this must never move between branches of an
            // `if`, which is the failure `PlayerView` records on macOS.
            // Minimised, the same surface is a 16:9 thumbnail at the left
            // of the bar; its frame moves, its identity does not.
            GeometryReader { geo in
                MpvSurface(controller: controller, streamURL: streamURL, cornerRadius: isMinimized ? 6 : 0)
                    .frame(
                        width: isMinimized ? Self.miniThumbSize.width : geo.size.width,
                        height: isMinimized ? Self.miniThumbSize.height : geo.size.height)
                    .clipShape(RoundedRectangle(cornerRadius: isMinimized ? 6 : 0, style: .continuous))
                    .position(
                        x: isMinimized ? 16 + 8 + Self.miniThumbSize.width / 2 : geo.size.width / 2,
                        y: isMinimized ? geo.size.height - Self.miniBarBottomInset - Self.miniBarHeight / 2 : geo.size.height / 2)
                    .allowsHitTesting(!isMinimized)
            }
            .ignoresSafeArea()
            // Above the bar while minimised (the bar's card is opaque and
            // drew over the thumbnail), under the chrome while full.
            .zIndex(isMinimized ? 2 : 0)

            if isMinimized {
                miniBar
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                // Gestures live on a clear layer above the surface, not on
                // the ZStack around it. `MpvEventCatcherView` is topmost
                // inside the host view and carries its own tap recognizer,
                // so a tap handled further out never arrived — it was
                // swallowed and turned into a play/pause toggle instead of
                // showing the controls.
                gestureLayer

                if controller.isBuffering {
                    bufferingIndicator
                }

                skipPill
                nextEpisodeCard

                if controller.areControlsVisible {
                    controls
                        .transition(.opacity)
                }

                if let flash {
                    seekFlash(symbol: flash.symbol, trailing: flash.trailing)
                }

                if let hud {
                    hudView(hud)
                        .transition(.opacity)
                }
            }
        }
        // Always hidden, not just while the controls are up: the system
        // player hides it for the whole session, and leaving it on put the
        // clock in the same strip as the title.
        .statusBarHidden(!isMinimized)
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
            if duration > 0 {
                fetchTracks()
                // The Mac's rate lives in the controller for the session;
                // the phone's is a setting, so a new file gets it back.
                if controller.playbackRate != storedSpeed, !heldSpeed {
                    controller.setPlaybackRate(storedSpeed)
                }
            }
        }
        // The Mac's `PlayerView` mirrors this; nothing on iOS did, so the
        // countdown could arm behind a minimised bar.
        .onChange(of: isMinimized, initial: true) { _, minimized in
            controller.isMiniPlayerActive = minimized
            if minimized { controller.areControlsVisible = false }
        }
        .onDisappear { controller.cancelAutohide() }
    }

    static let miniThumbSize = CGSize(width: 96, height: 54)
    /// Tab bar plus home indicator, measured on the 17 Pro; the bar sits on
    /// top of the tab bar rather than replacing it.
    static let miniBarBottomInset: CGFloat = 92

    // MARK: Mini bar

    /// Title and transport over the tabs. The thumbnail beside it is the
    /// live surface, positioned by the `GeometryReader` above.
    @ViewBuilder
    private var miniBar: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Self.miniThumbSize.width, height: Self.miniThumbSize.height)
            VStack(alignment: .leading, spacing: 2) {
                Text(controller.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(1)
                Text("EP \(controller.episodeNumber) \u{00B7} -\(Self.timestamp(max(0, controller.duration - controller.currentTime)))")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.togglePlayPause()
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(SumiTheme.muted)
                    .frame(width: 36, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .frame(height: Self.miniBarHeight)
        .background(SumiTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .bottom) {
            GeometryReader { geo in
                Rectangle()
                    .fill(SumiTheme.indigo)
                    .frame(width: geo.size.width * controller.progressFraction, height: 2)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .allowsHitTesting(false)
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(SumiTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onRestore)
        .padding(.horizontal, 16)
        // Same coordinate space as the thumbnail's `GeometryReader`, which
        // ignores the safe area: measured from the physical bottom, both
        // land at the same y. With the bar inside the safe area and the
        // thumb outside it, the thumb floated 30pt above the bar.
        .padding(.bottom, Self.miniBarBottomInset)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }

    // MARK: Controls

    private func toggleControls() {
        withAnimation(.easeOut(duration: 0.2)) {
            if controller.areControlsVisible {
                // NOT `cancelAutohide()` here, however much it reads like the
                // right call: it ends with `areControlsVisible = true`,
                // because on macOS it means "hold the controls up while a
                // menu is open". Calling it after setting false put the value
                // straight back, so the chrome could be summoned and never
                // dismissed. Leaving the pending task alone is harmless — all
                // it does when it fires is hide something already hidden.
                controller.areControlsVisible = false
            } else {
                controller.showControlsBriefly()
            }
        }
    }

    @ViewBuilder
    private var controls: some View {
        ZStack {
            // The chrome needs its own dismiss tap. While it is up it covers
            // the gesture layer underneath, so a tap on the scrim never
            // reached that layer: the controls could be summoned but not
            // dismissed, and only the 3.5s timer ever put them away.
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

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
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 14) {
            // Minimise, not stop: the system player's chevron shrinks the
            // picture and keeps it going. Stop is in the menu and on the
            // mini bar.
            Button(action: onMinimize) {
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

            // Where the bytes come from, when that is another machine.
            if AppModel.shared?.activeRemoteStreamToken != nil,
               let node = BonjourDiscovery.shared.discoveredMacNode {
                Label("via \(node.name)", systemImage: "macbook")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.35), in: Capsule())
                    .lineLimit(1)
            }

            tracksMenu
        }
    }

    /// Hands this episode to the Mac at the second the phone is on, and
    /// stops here. Absent unless a Mac that has already been paired is
    /// advertising: an unpaired one would raise an approval alert on a
    /// machine nobody is standing at, and the episode would stop on the
    /// phone for a handover that never lands.
    @ViewBuilder
    private var continueOnMac: some View {
        if let node = BonjourDiscovery.shared.discoveredMacNode,
           RemoteClient.knownHosts().contains(node.id),
           let catalogId = AppModel.shared?.currentPlaybackCatalogId {
            Button {
                let link = DeepLink.play(id: catalogId, episode: controller.episodeNumber)
                RemoteClient.shared.send(
                    .openAt(link: link.url.absoluteString, seconds: controller.currentTime),
                    to: node
                )
                AppModel.shared?.stopPlayback()
            } label: {
                Label("Continue on \(node.name)", systemImage: "macbook.and.iphone")
            }
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
            Picker("Speed", selection: Binding(
                get: { controller.playbackRate },
                set: { rate in
                    storedSpeed = rate
                    controller.setPlaybackRate(rate)
                }
            )) {
                ForEach(Self.speeds, id: \.self) { rate in
                    Text(Self.speedLabel(rate)).tag(rate)
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

            if !controller.chapters.isEmpty {
                Menu {
                    ForEach(controller.chapters) { chapter in
                        Button {
                            controller.seek(to: chapter.time)
                            controller.showControlsBriefly()
                        } label: {
                            Text("\(Self.timestamp(chapter.time))  \(chapter.title)")
                        }
                    }
                } label: {
                    Label("Chapters", systemImage: "list.number")
                }
            }

            Button {
                showReleases = true
            } label: {
                Label("Release", systemImage: "square.stack.3d.up")
            }

            sleepTimerMenu
            continueOnMac

            if controller.hasNextEpisode {
                Button("Next episode") { controller.nextEpisode() }
            }
            if controller.hasPreviousEpisode {
                Button("Previous episode") { controller.previousEpisode() }
            }

            Button(role: .destructive, action: onClose) {
                Label("Stop", systemImage: "xmark.circle")
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
                                    // The engine tries this one first on
                                    // every play and never said so; a
                                    // viewer choosing between rows should
                                    // know which one already worked.
                                    if release.name == controller.rememberedReleaseName {
                                        Text("Played last time")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 4))
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

    /// The Mac's sleep timer lives in the menu bar; the phone has no such
    /// thing, so it lives here. Same `AppModel.sleepTimer`, same "stop, do
    /// not pause" semantics at the end.
    @ViewBuilder
    private var sleepTimerMenu: some View {
        if let model = AppModel.shared {
            Menu {
                Button("Off") { model.sleepTimer = .off }
                Button("End of episode") { model.sleepTimer = .afterEpisode }
                ForEach([15, 30, 45, 60], id: \.self) { minutes in
                    Button("\(minutes) min") {
                        model.sleepTimer = .at(Date().addingTimeInterval(TimeInterval(minutes * 60)))
                    }
                }
            } label: {
                Label(model.sleepTimerCaption.map { "Sleep timer: \($0)" } ?? "Sleep timer",
                      systemImage: "moon.zzz")
            }
        }
    }

    private var nextEpisodeItem: MediaDetailView.EpisodeItem? {
        guard let index = controller.episodeList.firstIndex(where: { $0.number == controller.episodeNumber }),
              controller.episodeList.indices.contains(index + 1) else { return nil }
        return controller.episodeList[index + 1]
    }

    /// The Mac's countdown card, phone-sized. Same controller state:
    /// `armNextEpisodeCountdown` decides when, this only draws it and
    /// hands the two buttons to `playNextEpisodeNow` / `cancel`.
    @ViewBuilder
    private var nextEpisodeCard: some View {
        if controller.nextEpisodeCountdown.isVisible {
            let next = nextEpisodeItem
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    HStack(spacing: 12) {
                        // Position-driven like the Mac's ring: the countdown
                        // counts playback seconds, so a pause holds it.
                        ZStack {
                            Circle().stroke(.white.opacity(0.25), lineWidth: 3)
                            Circle()
                                .trim(from: 0, to: controller.nextEpisodeCountdown.elapsedFraction(at: controller.currentTime))
                                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            Text("\(max(1, Int(controller.nextEpisodeCountdown.remaining(at: controller.currentTime).rounded(.up))))")
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                        .frame(width: 34, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Up next")
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.7))
                            Text(next.map { "Episode \($0.number)\($0.title.isEmpty ? "" : " \u{00B7} \($0.title)")" } ?? "Next episode")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: 220, alignment: .leading)
                        Button {
                            controller.playNextEpisodeNow()
                        } label: {
                            Text("Play now")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .background(.white, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        Button {
                            withAnimation(.snappy) { controller.cancelNextEpisodeCountdown() }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.leading, 12)
                    .padding(.trailing, 6)
                    .padding(.vertical, 8)
                    .playerGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, controller.areControlsVisible ? 96 : 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func hudView(_ hud: Hud) -> some View {
        VStack(spacing: 8) {
            Image(systemName: hud.symbol)
                .font(.system(size: 26, weight: .regular))
            Text(hud.text)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            if let fraction = hud.fraction {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 120, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(.white).frame(width: 120 * fraction)
                    }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .playerGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }

    static func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : "\(rate)x"
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

            if controller.playbackRate != 1.0 {
                Text(Self.speedLabel(controller.playbackRate))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.white.opacity(0.22), in: Capsule())
            }

            Scrubber(
                value: scrubTarget ?? controller.currentTime,
                duration: max(controller.duration, 0.001),
                buffered: controller.bufferedRanges,
                marks: controller.chapters.map(\.time),
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
                    tapTask?.cancel()
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
                // One recogniser for tap, hold and drag. Three separate ones
                // (`onTapGesture`, `onLongPressGesture`, a `DragGesture`)
                // left the drag never beginning on the simulator, whether
                // simultaneous or high priority: the long press claimed the
                // touch. A zero-distance drag sees the whole touch and sorts
                // it out itself: under 12pt and under 0.5s is a tap, under
                // 12pt and past 0.5s is a hold (2x), past 12pt is a drag
                // whose axis is fixed on that first movement -- vertical on
                // the left is brightness, on the right volume, horizontal is
                // a scrub. What every phone player does, and what the Mac
                // has no gesture for.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            if !touchDown {
                                touchDown = true
                                AppLog.write("[gesture] touch down at \(Int(drag.startLocation.x)),\(Int(drag.startLocation.y)) in \(Int(geo.size.width))x\(Int(geo.size.height))")
                                holdTask?.cancel()
                                holdTask = Task {
                                    try? await Task.sleep(for: .milliseconds(500))
                                    guard !Task.isCancelled, dragAxis == nil else { return }
                                    heldSpeed = true
                                    controller.setPlaybackRate(2.0)
                                    withAnimation(.easeOut(duration: 0.12)) {
                                        hud = Hud(symbol: "forward.fill", text: "2x")
                                    }
                                }
                            }
                            let distance = hypot(drag.translation.width, drag.translation.height)
                            if dragAxis == nil {
                                guard distance >= 12, !heldSpeed else { return }
                                holdTask?.cancel()
                                let horizontal = abs(drag.translation.width) > abs(drag.translation.height)
                                if horizontal {
                                    dragAxis = .horizontal
                                    dragStartValue = controller.currentTime
                                    controller.isScrubbing = true
                                } else if drag.startLocation.x < geo.size.width / 2 {
                                    dragAxis = .brightness
                                    dragStartValue = Double(UIScreen.main.brightness)
                                } else {
                                    dragAxis = .volume
                                    dragStartValue = controller.isMuted ? 0 : controller.volume
                                }
                                controller.cancelAutohide()
                            }
                            switch dragAxis {
                            case .horizontal?:
                                // A full-width drag is 90s: fine enough to
                                // land on a line, coarse enough to cross an
                                // intro.
                                let delta = Double(drag.translation.width / geo.size.width) * 90
                                let target = min(max(dragStartValue + delta, 0), max(controller.duration, 0))
                                scrubTarget = target
                                let sign = delta >= 0 ? "+" : "-"
                                hud = Hud(symbol: delta >= 0 ? "goforward" : "gobackward",
                                          text: "\(Self.timestamp(target))  \(sign)\(Int(abs(delta)))s")
                            case .brightness?:
                                let value = min(max(dragStartValue - Double(drag.translation.height / geo.size.height) * 1.5, 0), 1)
                                UIScreen.main.brightness = CGFloat(value)
                                hud = Hud(symbol: value < 0.35 ? "sun.min" : "sun.max", text: "\(Int(value * 100))%", fraction: value)
                            case .volume?:
                                let value = min(max(dragStartValue - Double(drag.translation.height / geo.size.height) * 1.5, 0), 1)
                                controller.setVolume(value)
                                hud = Hud(symbol: value == 0 ? "speaker.slash" : "speaker.wave.2", text: "\(Int(value * 100))%", fraction: value)
                            case nil:
                                break
                            }
                        }
                        .onEnded { drag in
                            AppLog.write("[gesture] ended axis=\(String(describing: dragAxis)) translation=\(Int(drag.translation.width)),\(Int(drag.translation.height)) held=\(heldSpeed)")
                            holdTask?.cancel()
                            touchDown = false
                            if heldSpeed {
                                heldSpeed = false
                                controller.setPlaybackRate(storedSpeed)
                                withAnimation(.easeIn(duration: 0.2)) { hud = nil }
                            } else if dragAxis == nil {
                                // A tap. Shows the controls; it does not
                                // toggle playback. The system player behaves
                                // the same way, and a tap that pauses is the
                                // thing people hit by accident reaching for a
                                // button. Deferred a beat so a double tap can
                                // cancel it, and only while the chrome is
                                // down: up, it has its own dismiss layer.
                                tapTask?.cancel()
                                tapTask = Task {
                                    try? await Task.sleep(for: .milliseconds(250))
                                    guard !Task.isCancelled, !controller.areControlsVisible else { return }
                                    toggleControls()
                                }
                            } else {
                                if dragAxis == .horizontal, let target = scrubTarget {
                                    controller.seek(to: target)
                                    scrubTarget = nil
                                    controller.isScrubbing = false
                                }
                                controller.showControlsBriefly()
                                Task {
                                    try? await Task.sleep(for: .milliseconds(500))
                                    withAnimation(.easeIn(duration: 0.2)) { if !heldSpeed { hud = nil } }
                                }
                            }
                            dragAxis = nil
                        }
                )
        }
        .ignoresSafeArea()
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
            // The engine's phase while a resolve is in flight (Next,
            // Previous, a release switch), mpv's percentage otherwise. The
            // seconds count comes in past 2s of resolve: a bare spinner for
            // longer than that reads as frozen.
            if let status = controller.resolveStatus {
                Text(PlayerController.withElapsed(status, controller.resolveElapsedSeconds))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            } else if let percent = controller.bufferingPercent {
                Text("\(percent)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
            } else if let seconds = controller.resolveElapsedSeconds {
                Text(PlayerController.withElapsed("Searching indexers", seconds))
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
    var buffered: [BufferedSpan] = []
    /// Chapter starts, as the Mac's scrubber draws them.
    var marks: [Double] = []
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
                ForEach(Array(buffered.enumerated()), id: \.offset) { _, span in
                    let x0 = width * min(max(span.start / duration, 0), 1)
                    let x1 = width * min(max(span.end / duration, 0), 1)
                    Capsule()
                        .fill(.white.opacity(0.32))
                        .frame(width: max(x1 - x0, 0), height: isDragging ? 7 : 4)
                        .offset(x: x0)
                }
                .allowsHitTesting(false)
                Capsule()
                    .fill(.white)
                    .frame(width: width * fraction, height: isDragging ? 7 : 4)
                ForEach(marks, id: \.self) { mark in
                    Rectangle()
                        .fill(.black.opacity(0.55))
                        .frame(width: 2, height: isDragging ? 7 : 4)
                        .offset(x: width * min(max(mark / duration, 0), 1) - 1)
                }
                .allowsHitTesting(false)
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
/// exists there, and the deployment target is 18, so the pre-26 fallback is
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
