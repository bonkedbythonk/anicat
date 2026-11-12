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
    @State private var showEpisodes = false
    /// The side panel standing in for the overflow `Menu`: twelve rows in
    /// one list put Stop beside Speed and hid Chapters two levels down, and
    /// a menu covers the picture it is adjusting.
    @State private var panel: Panel?
    /// A pinch and the one-finger recogniser see the same touches. While
    /// this is set, or just after, the drag is ignored: a pinch opening
    /// sideways otherwise read as a scrub and landed a seek on lift.
    /// `GestureState`, not `State`: a cancelled pinch never reaches
    /// `onEnded`, and a flag left set there would swallow every touch after.
    @GestureState private var isPinching = false
    @State private var pinchEndedAt: Date?
    @AppStorage("anicat_sub_dub") private var storedSubDub: String = "Subtitled"
    /// When `isBuffering` last went true; nil while playing. Drives the
    /// stall line under the spinner.
    @State private var bufferingSince: Date?
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

    enum Panel { case tracks, options }

    struct Hud: Equatable {
        let symbol: String
        let text: String
        var fraction: Double? = nil
        /// Brightness and volume draw as a slim bar at the edge their drag
        /// started on; the centred box sat over the middle of the picture
        /// being adjusted.
        var edge: HorizontalEdge? = nil
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

                // A resolve from inside the player (Next, a release switch,
                // the opening watchdog) can run while the old file still
                // plays; its line and Cancel live here, not on the tab bar's
                // card, which stays hidden under a full-screen player.
                // With the chrome up the transport carries the spinner and
                // this readout sits under it; drawn here as well, the play
                // button and its scrim landed on the percentage and the
                // swarm line, and a viewer who tapped to see what was wrong
                // saw a pause button and nothing else.
                if isStalled, !controller.areControlsVisible {
                    VStack(spacing: 10) {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .controlSize(.large)
                            .tint(.white)
                        bufferingDetails
                    }
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

                if let panel {
                    panelLayer(panel)
                }
            }
        }
        .animation(.easeOut(duration: 0.25), value: controller.areControlsVisible)
        // Always hidden, not just while the controls are up: the system
        // player hides it for the whole session, and leaving it on put the
        // clock in the same strip as the title.
        .statusBarHidden(!isMinimized)
        .sheet(isPresented: $showReleases) { releaseSheet }
        .sheet(isPresented: $showEpisodes) { episodesSheet }
        .onChange(of: controller.isBuffering, initial: true) { _, buffering in
            bufferingSince = buffering ? Date() : nil
        }
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
                Text("Ep \(controller.episodeNumber) \u{00B7} -\(Self.timestamp(max(0, controller.duration - controller.currentTime)))")
                    .sumiTabularMono(size: 12)
                    .foregroundStyle(SumiTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                controller.togglePlayPause()
                AppHaptics.play(.transport)
            } label: {
                Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Forward, not close, beside play: the close sat where a thumb
            // reaching for the tab bar lands, and ended the episode. Stop is
            // a long press on the bar and a row in the Options panel.
            Button {
                // Not `seek(by:)`: that also raises the full player's
                // chrome, which then greeted the next restore.
                AppHaptics.play(.transport)
                controller.seekRelative(by: 5)
            } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SumiTheme.foreground)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Forward 5 seconds")
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
        .contextMenu {
            Button(role: .destructive, action: onClose) {
                Label("Stop", systemImage: "xmark")
            }
        }
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
            //
            // It also carries the double-tap seek. A first tap shows the
            // controls at once, so the second tap of a double tap lands on
            // this layer, not on the gesture layer; without a recogniser
            // here it only dismissed the controls, and skipping worked
            // solely when both taps beat the chrome onto the screen. The
            // single tap waits out the double-tap window so a seek does not
            // flash the controls away first.
            GeometryReader { geo in
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        tapTask?.cancel()
                        tapTask = Task {
                            try? await Task.sleep(for: .milliseconds(250))
                            guard !Task.isCancelled else { return }
                            toggleControls()
                        }
                    }
                    .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { event in
                        skipTap(trailing: event.location.x > geo.size.width / 2)
                    })
            }

            // The system player dims the whole picture while its controls
            // are up, not the two ends: glyphs sit over any frame, and the
            // dim is what makes bare white transport buttons (no circle
            // behind them) readable. Gone with the controls.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Centred on the screen, not between the bars: `transportButton`
            // maps taps on the bare picture to these buttons by distance
            // from the centre.
            transport

            VStack {
                topBar
                Spacer()
                bottomBar
            }
            // The picture is full-bleed; the controls are not. Fixed padding
            // put the top row under the Dynamic Island and the scrubber under
            // the home indicator on a real phone — in landscape the notch
            // inset lands on a *side*, which no horizontal constant can know
            // about. `safeAreaPadding` is the only thing that does.
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private var topBar: some View {
        HStack(spacing: 14) {
            // Minimise, not stop: the system player's chevron shrinks the
            // picture and keeps it going. Stop is the X at the other end.
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .playerGlass(in: Circle())
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(controller.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if !controller.episodeTitle.isEmpty {
                    Text("Episode \(controller.episodeNumber) · \(controller.episodeTitle)")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Out of the menu and onto the bar: choosing another episode is
            // the thing a streaming app's player is most often opened for,
            // and Next/Previous in the overflow menu only reached neighbours.
            // One glass capsule for the pair, as the system player groups
            // its trailing buttons.
            HStack(spacing: 0) {
                // Subtitles and audio get their own button: the setting a
                // viewer changes most, and it sat inside the overflow menu.
                Button {
                    openPanel(.tracks)
                } label: {
                    Image(systemName: "captions.bubble")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Subtitles and audio")

                if !controller.episodeList.isEmpty {
                    Button {
                        showEpisodes = true
                    } label: {
                        Image(systemName: "rectangle.stack")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Episodes")
                }

                Button {
                    openPanel(.options)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Options")
            }
            .playerGlass(in: Capsule())

            // Ending the episode took the Options panel's Stop row or a long
            // press on the mini bar, and nobody found either. Opposite
            // corner from the chevron, so minimise and stop are not one
            // mis-tap apart.
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .playerGlass(in: Circle())
            }
            .accessibilityLabel("Stop")
        }
    }

    /// The playing title's episodes, the current one in view. Unaired ones
    /// stay listed, as the detail page lists them, but cannot be picked.
    @ViewBuilder
    private var episodesSheet: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(controller.episodeList) { episode in
                    Button {
                        showEpisodes = false
                        controller.selectEpisode(episode.number)
                    } label: {
                        PlayerEpisodeRow(episode: episode, isCurrent: episode.number == controller.episodeNumber)
                    }
                    .disabled(!episode.isAired || episode.number == controller.episodeNumber)
                    .id(episode.number)
                }
                .listStyle(.plain)
                .onAppear { proxy.scrollTo(controller.episodeNumber, anchor: .center) }
            }
            .navigationTitle(controller.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showEpisodes = false }
                }
            }
        }
    }

    /// Sub/Dub, the standing choice shared with Settings through
    /// `anicat_sub_dub`. Picking one switches the playing file's audio when it
    /// carries that language; most releases carry one, and then the alert
    /// offers a search for this episode in the other language, since a
    /// switch that only changes the next episode reads as broken.
    private var subDubSelection: Binding<String> {
        Binding(
            get: { storedSubDub },
            set: { option in
                storedSubDub = option
                let wantsDub = option == "Dubbed"
                guard let select = controller.onSelectAudioLanguage else { return }
                select(wantsDub) { switched in
                    fetchTracks()
                    // No such track in this file: the app finds a release that
                    // has one, from where the viewer is, without asking first.
                    if !switched { controller.onReloadForAudioLanguage?(wantsDub) }
                }
            }
        )
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

    // MARK: Panels

    private func openPanel(_ which: Panel) {
        if which == .tracks { fetchTracks() }
        withAnimation(.snappy) {
            panel = which
            controller.areControlsVisible = false
        }
    }

    private func closePanel() {
        withAnimation(.snappy) { panel = nil }
        controller.showControlsBriefly()
    }

    /// A column at the trailing edge with the picture still playing beside
    /// it. A tap on the picture closes it.
    @ViewBuilder
    private func panelLayer(_ which: Panel) -> some View {
        ZStack(alignment: .trailing) {
            Color.black.opacity(0.25)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closePanel() }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    switch which {
                    case .tracks: tracksPanel
                    case .options: optionsPanel
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .foregroundStyle(.white)
            .playerPanelGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.vertical, 10)
            .padding(.trailing, 10)
        }
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    @ViewBuilder
    private var tracksPanel: some View {
        Text("Subtitles and audio")
            .font(.system(size: 17, weight: .semibold))
        // Films and TV have no sub/dub split; their audio tracks are the
        // list below.
        if AppModel.shared?.currentPlaybackCatalog == .anilist {
            panelHeading("Language")
            panelSteps([("Subtitled", "Sub"), ("Dubbed", "Dub")], selected: storedSubDub) { option in
                subDubSelection.wrappedValue = option
            }
        }
        // Anime already has Sub / Dub above, so the track list appears only
        // when the file has a choice that row cannot name.
        if !audioTracks.isEmpty,
           AppModel.shared?.currentPlaybackCatalog != .anilist || PlayerTrack.needsAudioPicker(audioTracks) {
            panelHeading("Audio")
            ForEach(audioTracks) { track in
                panelChoice(label(for: track), selected: track.isSelected) {
                    audioSelection.wrappedValue = track.id
                }
            }
        }
        if !subtitleTracks.isEmpty {
            panelHeading("Subtitles")
            panelChoice("Off", selected: !subtitleTracks.contains(where: \.isSelected)) {
                subtitleSelection.wrappedValue = PlayerTrack.off
            }
            ForEach(subtitleTracks) { track in
                panelChoice(label(for: track), selected: track.isSelected) {
                    subtitleSelection.wrappedValue = track.id
                }
            }
        }
        panelHeading("Subtitle size")
        panelSteps([(0.8, "Small"), (1.0, "Normal"), (1.25, "Large"), (1.5, "Huge")], selected: subtitleScale) { scale in
            subtitleScale = scale
            controller.setSubtitleScale(scale)
        }
    }

    @ViewBuilder
    private var optionsPanel: some View {
        Text("Options")
            .font(.system(size: 17, weight: .semibold))

        panelHeading("Speed")
        panelSteps(Self.speeds.map { ($0, Self.speedLabel($0)) }, selected: controller.playbackRate) { rate in
            storedSpeed = rate
            controller.setPlaybackRate(rate)
        }

        panelHeading("Picture")
        panelSteps([(false, "Fit"), (true, "Fill")], selected: controller.isFillingScreen) { fill in
            setFill(fill)
        }

        if let model = AppModel.shared {
            panelHeading(model.sleepTimerCaption.map { "Sleep timer \u{00B7} \($0)" } ?? "Sleep timer")
            panelSteps(
                [(0, "Off"), (-1, "End"), (15, "15m"), (30, "30m"), (45, "45m"), (60, "60m")],
                selected: model.sleepTimer == .off ? 0 : (model.sleepTimer == .afterEpisode ? -1 : nil)
            ) { minutes in
                switch minutes {
                case 0: model.sleepTimer = .off
                case -1: model.sleepTimer = .afterEpisode
                default: model.sleepTimer = .at(Date().addingTimeInterval(TimeInterval(minutes * 60)))
                }
            }
        }

        if !controller.chapters.isEmpty {
            panelHeading("Chapters")
            ForEach(controller.chapters) { chapter in
                Button {
                    controller.seek(to: chapter.time)
                    closePanel()
                } label: {
                    HStack(spacing: 12) {
                        Text(Self.timestamp(chapter.time))
                            .sumiTabularMono(size: 13)
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 52, alignment: .leading)
                        Text(chapter.title)
                            .font(.system(size: 15))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }

        panelHeading("Source")
        Button {
            closePanel()
            showReleases = true
        } label: {
            HStack(spacing: 8) {
                Text("Release")
                    .font(.system(size: 15))
                Spacer(minLength: 8)
                Text(controller.currentReleaseName ?? "")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)

        if controller.hasNextEpisode || controller.hasPreviousEpisode {
            panelHeading("Episode")
            if controller.hasNextEpisode {
                panelAction("Next episode", systemImage: "forward.end") {
                    closePanel()
                    controller.nextEpisode()
                }
            }
            if controller.hasPreviousEpisode {
                panelAction("Previous episode", systemImage: "backward.end") {
                    closePanel()
                    controller.previousEpisode()
                }
            }
        }

        continueOnMac
            .buttonStyle(.plain)
            .font(.system(size: 15))
            .frame(minHeight: 44)

        Divider().overlay(.white.opacity(0.15)).padding(.vertical, 6)
        Button(role: .destructive, action: onClose) {
            HStack {
                Text("Stop")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Color(red: 1, green: 0.45, blue: 0.42))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func panelHeading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
            .padding(.top, 14)
            .padding(.bottom, 4)
    }

    private func panelChoice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            SumiHaptics.selection()
            action()
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func panelAction(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                Text(title)
                    .font(.system(size: 15))
                Spacer()
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// One row of short choices, the current one filled. Speed was a
    /// submenu of six; here every value is one tap.
    private func panelSteps<Value: Hashable>(
        _ options: [(Value, String)],
        selected: Value?,
        pick: @escaping (Value) -> Void
    ) -> some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.0) { option in
                let isOn = option.0 == selected
                Button {
                    // The chosen one is inert: re-picking Sub or Dub started
                    // the language check and release search over again.
                    guard !isOn else { return }
                    SumiHaptics.selection()
                    pick(option.0)
                } label: {
                    Text(option.1)
                        .font(.system(size: 13, weight: isOn ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(isOn ? .black : .white)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(isOn ? Color.white : Color.white.opacity(0.12),
                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
                                        .sumiTabularMono(size: 12)
                                        .foregroundStyle(.secondary)
                                    // The engine tries this one first on
                                    // every play and never said so; a
                                    // viewer choosing between rows should
                                    // know which one already worked.
                                    if release.name == controller.rememberedReleaseName {
                                        Text("Played last time")
                                            .sumiTabularMono(size: 12)
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

    private var nextEpisodeItem: MediaDetailView.EpisodeItem? {
        guard let index = controller.episodeList.firstIndex(where: { $0.number == controller.episodeNumber }),
              controller.episodeList.indices.contains(index + 1) else { return nil }
        return controller.episodeList[index + 1]
    }

    /// The Mac's countdown card, phone-sized. Same controller state:
    /// `armNextEpisodeCountdown` decides when, this only draws it and
    /// hands the two buttons to `playNextEpisodeNow` / `cancel`. The next
    /// episode's still and a bar that fills, rather than a ring and a
    /// number: the still says which episode before the title is read.
    @ViewBuilder
    private var nextEpisodeCard: some View {
        if controller.nextEpisodeCountdown.isVisible {
            let next = nextEpisodeItem
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    CachedAsyncImage(url: next?.thumbnailURL, maxPixelSize: 300) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Color.white.opacity(0.12)
                    }
                    .frame(width: 112, height: 63)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(next.map { "Next \u{00B7} Episode \($0.number)" } ?? "Next episode")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.7))
                        if let title = next?.title, !title.isEmpty {
                            Text(title)
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        // Position-driven like the Mac's ring: the countdown
                        // counts playback seconds, so a pause holds it.
                        GeometryReader { geo in
                            Capsule().fill(.white.opacity(0.25))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white)
                                        .frame(width: geo.size.width * controller.nextEpisodeCountdown.elapsedFraction(at: controller.currentTime))
                                }
                        }
                        .frame(height: 3)
                        .padding(.top, 5)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 8) {
                    Button {
                        withAnimation(.snappy) { controller.cancelNextEpisodeCountdown() }
                    } label: {
                        Text("Stay here")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Button {
                        AppHaptics.play(.transport)
                        controller.playNextEpisodeNow()
                    } label: {
                        Text("Play now")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .background(.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .frame(width: 320)
            .playerGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.horizontal, 26)
            .padding(.bottom, controller.areControlsVisible ? 96 : 26)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func hudView(_ hud: Hud) -> some View {
        if let edge = hud.edge, let fraction = hud.fraction {
            edgeBar(symbol: hud.symbol, fraction: fraction, edge: edge)
        } else {
            centredHud(hud)
        }
    }

    private func edgeBar(symbol: String, fraction: Double, edge: HorizontalEdge) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .frame(height: 18)
            Capsule()
                .fill(.white.opacity(0.25))
                .frame(width: 6, height: 150)
                .overlay(alignment: .bottom) {
                    Capsule().fill(.white).frame(width: 6, height: 150 * fraction)
                }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 14)
        .padding(.horizontal, 10)
        .playerGlass(in: Capsule())
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .leading ? .leading : .trailing)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func centredHud(_ hud: Hud) -> some View {
        VStack(spacing: 8) {
            Image(systemName: hud.symbol)
                .font(.system(size: 26, weight: .regular))
            Text(hud.text)
                .sumiTabularMono(size: 12, weight: .semibold)
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

    /// Bare white glyphs over the dim, large, and play/pause morphing rather
    /// than swapping, as the system player draws them.
    @ViewBuilder
    private var transport: some View {
        HStack(spacing: Self.transportGap) {
            Button { seek(by: -5) } label: {
                Image(systemName: "gobackward.5")
                    .font(.system(size: 36, weight: .regular))
                    .frame(width: Self.skipCell, height: Self.skipCell)
            }
            Button {
                controller.togglePlayPause()
                AppHaptics.play(.transport)
                controller.showControlsBriefly()
            } label: {
                // mpv keeps `pause` false while it waits for the cache, so a
                // stall showed a pause button as if it were playing.
                if isStalled {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: Self.playCell, height: Self.playCell)
                } else {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 50, weight: .regular))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Self.playCell, height: Self.playCell)
                }
            }
            Button { seek(by: 5) } label: {
                Image(systemName: "goforward.5")
                    .font(.system(size: 36, weight: .regular))
                    .frame(width: Self.skipCell, height: Self.skipCell)
            }
        }
        .buttonStyle(TransportPressStyle())
        .foregroundStyle(.white)
        .overlay(alignment: .top) {
            if isStalled {
                bufferingDetails
                    .fixedSize()
                    .offset(y: Self.playCell + 12)
            }
        }
    }

    private var isStalled: Bool {
        controller.isBuffering || controller.resolveStatus != nil
    }

    static let playCell: CGFloat = 76
    static let skipCell: CGFloat = 52
    static let transportGap: CGFloat = 44

    private var bottomBar: some View {
        PhoneBottomBar(controller: controller, scrubTarget: $scrubTarget)
    }

    /// Times under the scrubber, small and quiet; what is left, not the total,
    /// because that is the number people read.
    ///
    /// Its own view so the playhead's 4 Hz tick re-evaluates this bar and
    /// not `PhonePlayerView.body`. Read there, every tick rebuilt the
    /// overflow `Menu` too (measured: `tracksMenu` built 4 times a second
    /// while the controls were up), and a menu rebuilt under the thumb
    /// glitches while it is scrolled.
    private struct PhoneBottomBar: View {
        @Bindable var controller: PlayerController
        @Binding var scrubTarget: Double?
        /// The chapter the last scrub position fell in, so crossing into
        /// another one can tick under the finger.
        @State private var scrubChapter: Int?

        var body: some View {
            let position = scrubTarget ?? controller.currentTime
            VStack(alignment: .leading, spacing: 2) {
                // Which stretch the playhead or the scrub is in, named: the
                // segments alone say there is an opening, not where.
                if let index = PhonePlayerView.chapterIndex(at: position, in: controller.chapters) {
                    Text(controller.chapters[index].title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .padding(.bottom, 2)
                }
                Scrubber(
                    value: position,
                    duration: max(controller.duration, 0.001),
                    buffered: controller.bufferedRanges,
                    marks: controller.chapters.map(\.time),
                    onScrub: { value in
                        let chapter = PhonePlayerView.chapterIndex(at: value, in: controller.chapters)
                        if scrubTarget != nil, chapter != scrubChapter { AppHaptics.play(.chapterCross) }
                        scrubChapter = chapter
                        scrubTarget = value
                        controller.isScrubbing = true
                        controller.cancelAutohide()
                    },
                    onCommit: { value in
                        controller.seek(to: value)
                        scrubTarget = nil
                        scrubChapter = nil
                        controller.isScrubbing = false
                        controller.showControlsBriefly()
                    }
                )
                .frame(height: 28)

                HStack {
                    Text(PhonePlayerView.timestamp(position))
                    Spacer()
                    if controller.playbackRate != 1.0 {
                        Text(PhonePlayerView.speedLabel(controller.playbackRate))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Text("-" + PhonePlayerView.timestamp(max(0, controller.duration - position)))
                }
                .sumiTabularMono(size: 12, weight: .semibold)
                .foregroundStyle(.white.opacity(0.7))
            }
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
                        AppHaptics.play(.transport)
                    } label: {
                        HStack(spacing: 8) {
                            Text(window.label)
                                .font(.system(size: 14, weight: .semibold))
                            Image(systemName: "forward.end.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .playerGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
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
                    skipTap(trailing: event.location.x > geo.size.width / 2)
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
                // Pinch out to fill, in to fit: the system player's gesture.
                // Decided on lift, past a small margin, so a two-finger
                // touch that barely moves changes nothing.
                .simultaneousGesture(
                    MagnifyGesture()
                        .updating($isPinching) { _, pinching, _ in pinching = true }
                        .onChanged { _ in
                            holdTask?.cancel()
                            if dragAxis != nil || heldSpeed { abandonDrag() }
                        }
                        .onEnded { value in
                            pinchEndedAt = Date()
                            let scale = value.magnification
                            if scale > 1.08, !controller.isFillingScreen {
                                setFill(true)
                            } else if scale < 0.92, controller.isFillingScreen {
                                setFill(false)
                            }
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            guard !isPinching else { return }
                            if !touchDown {
                                touchDown = true
                                AppLog.write("[gesture] touch down at \(Int(drag.startLocation.x)),\(Int(drag.startLocation.y)) in \(Int(geo.size.width))x\(Int(geo.size.height))")
                                holdTask?.cancel()
                                holdTask = Task {
                                    try? await Task.sleep(for: .milliseconds(500))
                                    guard !Task.isCancelled, dragAxis == nil else { return }
                                    heldSpeed = true
                                    controller.setPlaybackRate(2.0)
                                    AppHaptics.play(.speedHold)
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
                                hud = Hud(symbol: value < 0.35 ? "sun.min" : "sun.max", text: "\(Int(value * 100))%", fraction: value, edge: .leading)
                            case .volume?:
                                let value = min(max(dragStartValue - Double(drag.translation.height / geo.size.height) * 1.5, 0), 1)
                                controller.setVolume(value)
                                hud = Hud(symbol: value == 0 ? "speaker.slash" : "speaker.wave.2", text: "\(Int(value * 100))%", fraction: value, edge: .trailing)
                            case nil:
                                break
                            }
                        }
                        .onEnded { drag in
                            AppLog.write("[gesture] ended axis=\(String(describing: dragAxis)) translation=\(Int(drag.translation.width)),\(Int(drag.translation.height)) held=\(heldSpeed)")
                            holdTask?.cancel()
                            touchDown = false
                            // The fingers of a pinch lift after it ends; that
                            // lift is not a tap and must not show the chrome.
                            if isPinching || pinchEndedAt.map({ Date().timeIntervalSince($0) < 0.5 }) == true {
                                // Only when something is left to undo: the
                                // call clears the HUD, and the pinch has just
                                // put "Fill" or "Fit" there.
                                if heldSpeed || dragAxis != nil { abandonDrag() }
                                return
                            }
                            if heldSpeed {
                                heldSpeed = false
                                controller.setPlaybackRate(storedSpeed)
                                withAnimation(.easeIn(duration: 0.2)) { hud = nil }
                            } else if dragAxis == nil {
                                // A tap. Shows the controls at once; it does
                                // not toggle playback. The system player
                                // behaves the same way, and a tap that pauses
                                // is the thing people hit by accident
                                // reaching for a button. Not deferred for a
                                // double tap: the 250ms wait read as the
                                // controls lagging, and the second tap of a
                                // double tap is heard by the chrome's own
                                // layer. Up, the chrome has its own dismiss
                                // layer. A tap where a transport button
                                // will appear acts as that button, so
                                // pausing or skipping from a bare picture is
                                // one tap, not a tap to summon the chrome and
                                // a second to press the button.
                                if !controller.areControlsVisible {
                                    withAnimation(.easeOut(duration: 0.2)) {
                                        switch transportButton(at: drag.location, in: geo.size) {
                                        case .rewind?: seek(by: -5)
                                        case .playPause?:
                                            controller.togglePlayPause()
                                            AppHaptics.play(.transport)
                                            controller.showControlsBriefly()
                                        case .forward?: seek(by: 5)
                                        case nil: toggleControls()
                                        }
                                    }
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

    private enum TransportButton { case rewind, playPause, forward }

    /// The transport row sits at the centre of the screen: play/pause in a
    /// `playCell` square, `transportGap` either side, then a `skipCell`
    /// square. The zones are those cells plus the gaps, a little taller than
    /// the glyphs so a thumb that lands near one still counts.
    private func transportButton(at point: CGPoint, in size: CGSize) -> TransportButton? {
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        guard abs(dy) <= Self.playCell / 2 else { return nil }
        let inner = Self.playCell / 2
        let outer = inner + Self.transportGap + Self.skipCell
        switch abs(dx) {
        case 0 ..< inner: return .playPause
        case inner ..< outer: return dx < 0 ? .rewind : .forward
        default: return nil
        }
    }

    /// The double-tap seek, shared by the gesture layer (controls hidden)
    /// and the chrome's scrim (controls up).
    private func skipTap(trailing: Bool) {
        tapTask?.cancel()
        seek(by: trailing ? 5 : -5)
        withAnimation(.easeOut(duration: 0.12)) {
            flash = (trailing ? "goforward.5" : "gobackward.5", trailing)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            withAnimation(.easeIn(duration: 0.2)) { flash = nil }
        }
    }

    private func seek(by delta: Double) {
        AppHaptics.play(.transport)
        controller.seekRelative(by: delta)
        controller.showControlsBriefly()
    }

    /// Undoes whatever the first finger of a pinch had started: the drag
    /// fixes its axis at 12pt, and two fingers spreading cross that before
    /// the pinch is recognised. A finger resting past 0.5s first has already
    /// switched to 2x, and the pinch's lift never reaches the restore in the
    /// drag's `onEnded`, so the rate is put back here too.
    private func abandonDrag() {
        holdTask?.cancel()
        if heldSpeed {
            heldSpeed = false
            controller.setPlaybackRate(storedSpeed)
            hud = nil
        }
        switch dragAxis {
        case .horizontal?:
            scrubTarget = nil
            controller.isScrubbing = false
        case .brightness?:
            UIScreen.main.brightness = CGFloat(dragStartValue)
        case .volume?:
            controller.setVolume(dragStartValue)
        case nil:
            break
        }
        dragAxis = nil
        hud = nil
    }

    private func setFill(_ fill: Bool) {
        controller.setFillScreen(fill)
        withAnimation(.easeOut(duration: 0.12)) {
            hud = Hud(symbol: fill ? "arrow.up.left.and.arrow.down.right" : "arrow.down.right.and.arrow.up.left",
                      text: fill ? "Fill" : "Fit")
        }
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeIn(duration: 0.2)) { if !heldSpeed { hud = nil } }
        }
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
    private var bufferingDetails: some View {
        VStack(spacing: 10) {
            // The engine's phase while a resolve is in flight (Next,
            // Previous, a release switch), mpv's percentage otherwise. The
            // seconds count comes in past 2s of resolve: a bare spinner for
            // longer than that reads as frozen.
            if let status = controller.resolveStatus {
                Text(PlayerController.withElapsed(status, controller.resolveElapsedSeconds))
                    .sumiTabularMono(size: 12)
                    .foregroundStyle(.white.opacity(0.8))
                Button {
                    AppModel.shared?.cancelResolve()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.16), in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            } else if let seconds = controller.resolveElapsedSeconds {
                Text(PlayerController.withElapsed("Searching indexers", seconds))
                    .sumiTabularMono(size: 12)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                // A bare "0%" under a spinner said nothing about what was
                // being waited for.
                Text(controller.bufferingPercent.map { "Buffering \($0)%" } ?? "Buffering")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            // Not during a resolve: the engine may still hold the torrent
            // being left, whose peers say nothing about the one coming.
            if controller.resolveStatus == nil {
                SwarmLine(controller: controller)
            }
            // A spinner that has sat for a quarter of a minute with mpv's
            // percentage not moving is a swarm that dried up, and on a
            // phone the only way out was closing the player and finding
            // the release sheet by hand. Not during a resolve: that is
            // already a switch in progress with its own line above.
            if controller.resolveStatus == nil, let since = bufferingSince {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    let stalled = Int(context.date.timeIntervalSince(since))
                    if stalled >= Self.stallNudgeSeconds {
                        VStack(spacing: 8) {
                            Text("Stalled for \(stalled)s")
                                .sumiTabularMono(size: 12)
                                .foregroundStyle(.white.opacity(0.8))
                            Button {
                                showReleases = true
                            } label: {
                                Label("Switch release", systemImage: "square.stack.3d.up")
                                    .font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 8)
                                    .background(.white.opacity(0.16), in: Capsule())
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    /// Longer than one unchoke round (10s) and the opening watchdog's 20s
    /// window, so a slow swarm that is still alive is not nagged, and the
    /// watchdog's own switch gets to happen first while opening.
    static let stallNudgeSeconds = 25

    /// The last chapter starting at or before `time`, nil with no chapters.
    static func chapterIndex(at time: Double, in chapters: [PlayerChapter]) -> Int? {
        chapters.lastIndex(where: { $0.time <= time })
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

/// Peers and speed under the stall spinner, read once a second. During a
/// resolve the line above already carries the engine's own reading, and the
/// swarm stats would describe the torrent being left.
private struct SwarmLine: View {
    let controller: PlayerController
    @State private var line: String?

    var body: some View {
        // Always a `Text`, never an empty branch: the `task` below needs a
        // view to hang on from the first frame.
        Text(line ?? " ")
            .sumiTabularMono(size: 12)
            .foregroundStyle(.white.opacity(0.65))
            .task {
                while !Task.isCancelled {
                    controller.onFetchSwarmSummary? { line = $0 }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
    }
}

/// One row of the in-player episode list: the detail page's row, with room
/// for the synopsis and a marker on the one playing.
private struct PlayerEpisodeRow: View {
    let episode: MediaDetailView.EpisodeItem
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: episode.thumbnailURL, maxPixelSize: 300) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: 112, height: 63)
                .clipped()
                if isCurrent {
                    Color.black.opacity(0.45)
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if episode.isWatched {
                    Color.black.opacity(0.45)
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let percent = episode.progressPercent, percent > 0, !episode.isWatched {
                    Rectangle()
                        .fill(SumiTheme.indigo)
                        .frame(width: 112 * min(percent, 100) / 100, height: 3)
                }
            }
            .frame(width: 112, height: 63)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(isCurrent ? "Episode \(episode.number) \u{00B7} Now playing" : "Episode \(episode.number)")
                    .sumiTabularMono(size: 12, weight: .semibold)
                    .foregroundStyle(isCurrent ? SumiTheme.indigo : SumiTheme.muted)
                if !episode.title.isEmpty {
                    Text(episode.title)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(episode.isAired ? SumiTheme.foreground : SumiTheme.muted)
                        .lineLimit(1)
                }
                if !episode.isAired {
                    Text(Self.airDate(episode.airDate).map { "Airs \($0)" } ?? "Not aired yet")
                        .font(.system(size: 12))
                        .foregroundStyle(SumiTheme.muted)
                } else if let synopsis = episode.synopsis, !synopsis.isEmpty {
                    Text(synopsis)
                        .font(.system(size: 12))
                        .foregroundStyle(SumiTheme.muted)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// AniZip's `YYYY-MM-DD`, read as UTC because that is how it is written;
    /// local time rolled the date back a day west of Greenwich.
    private static func airDate(_ raw: String?) -> String? {
        guard let raw,
              let date = try? Date(raw, strategy: Date.ISO8601FormatStyle().year().month().day())
        else { return nil }
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = .gmt
        return date.formatted(style)
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

            let height: CGFloat = isDragging ? 7 : 4

            ZStack(alignment: .leading) {
                // The track splits at chapter starts with a gap, not a dark
                // tick painted on it: the tick was 55% black, which shows on
                // the white played part and next to nothing on the dim
                // unplayed track over a dark frame.
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.white.opacity(0.28))
                    ForEach(Array(buffered.enumerated()), id: \.offset) { _, span in
                        let x0 = width * min(max(span.start / duration, 0), 1)
                        let x1 = width * min(max(span.end / duration, 0), 1)
                        Rectangle()
                            .fill(.white.opacity(0.32))
                            .frame(width: max(x1 - x0, 0))
                            .offset(x: x0)
                    }
                    Rectangle()
                        .fill(.white)
                        .frame(width: width * fraction)
                }
                .frame(height: height)
                .mask(SegmentedTrack(cuts: marks.map { min(max($0 / duration, 0), 1) }))
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

/// The scrubber's track cut into one rounded segment per chapter. `cuts`
/// are fractions of the width; a cut at either end draws no gap.
private struct SegmentedTrack: Shape {
    let cuts: [Double]
    static let gap: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        let inner = cuts.filter { $0 > 0.005 && $0 < 0.995 }.sorted()
        let edges = [0.0] + inner + [1.0]
        var path = Path()
        for (start, end) in zip(edges, edges.dropFirst()) {
            let x0 = rect.minX + rect.width * start + (start > 0 ? Self.gap / 2 : 0)
            let x1 = rect.minX + rect.width * end - (end < 1 ? Self.gap / 2 : 0)
            guard x1 > x0 else { continue }
            path.addRoundedRect(
                in: CGRect(x: x0, y: rect.minY, width: x1 - x0, height: rect.height),
                cornerSize: CGSize(width: rect.height / 2, height: rect.height / 2))
        }
        return path
    }
}

/// The system player's transport buttons dip and dim under the finger.
private struct TransportPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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

    /// The side panel's ground. Not `.interactive()`: that variant answers
    /// touches, which suits a button, not a surface a finger scrolls.
    @ViewBuilder
    func playerPanelGlass(in shape: some Shape) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.black.opacity(0.6), in: shape)
        }
    }
}
#endif
