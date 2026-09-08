#if os(iOS)
import SwiftUI

/// The phone as a remote for a Mac running Anicat on the same Wi-Fi.
///
/// A sheet rather than a tab or a page: it is only reachable while a Mac is
/// actually advertising, and a permanent control that is dead most of the
/// time is the thing the Films & TV segment is already hidden to avoid.
struct PhoneRemoteView: View {
    let node: BonjourDiscovery.DiscoveredNode
    let model: AppModel
    @Environment(\.dismiss) private var dismiss

    private var client: RemoteClient { RemoteClient.shared }
    @State private var showingTracks = false
    @State private var showingBrowse = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                switch client.status {
                case .connected:
                    if client.state.hasPlayback {
                        transport
                    } else {
                        message(
                            "Nothing playing",
                            detail: "Pick something with the list button, or start it on \(node.name).",
                            symbol: "play.slash"
                        )
                    }
                case .connecting:
                    message("Connecting", detail: node.name, symbol: "wifi")
                case .awaitingApproval:
                    message(
                        "Waiting for \(node.name)",
                        detail: "Approve this iPhone in Anicat on the Mac. It is asked once.",
                        symbol: "hand.raised"
                    )
                case .denied:
                    message(
                        "Not allowed",
                        detail: "\(node.name) refused this iPhone. Approve it there, or clear paired remotes in the Mac's settings and try again.",
                        symbol: "xmark.shield",
                        showsRetry: true
                    )
                case .failed(let reason):
                    message(
                        "Could not reach \(node.name)",
                        detail: reason,
                        symbol: "exclamationmark.triangle",
                        showsRetry: true
                    )
                case .idle:
                    // Reached by the Mac sleeping, quitting or dropping off
                    // the Wi-Fi mid-session. Without the retry the sheet is a
                    // dead end that has to be closed and reopened, because
                    // the only dial-out is this view's `task`.
                    message("Disconnected", detail: node.name, symbol: "wifi.slash", showsRetry: true)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(SumiTheme.background)
            .navigationTitle("Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if client.status == .connected {
                        Button {
                            showingBrowse = true
                        } label: {
                            Image(systemName: "list.and.film")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showingBrowse) {
            PhoneRemoteBrowseView(node: node, model: model)
        }
        .sheet(isPresented: $showingTracks) {
            trackPicker
        }
        .task {
            // Dialled from here and nowhere else. The first hello raises an
            // approval alert on the Mac, so connecting on discovery would
            // interrupt whoever is sitting at it with nobody having asked
            // for a remote.
            // `ensureConnected`, not a bare status check: a socket killed by
            // suspension leaves `status` reading `.connected` until the
            // cancellation is delivered, and trusting it drew a transport
            // that answered nothing.
            client.ensureConnected(to: node)
            if !RemoteClient.knownHosts().contains(node.id) { client.connect(to: node) }
        }
    }

    // MARK: - Transport

    private var state: RemoteState { client.state }

    private var transport: some View {
        VStack(spacing: 28) {
            // The poster the Mac is playing, so the sheet says what is on
            // screen across the room without reading a word of it.
            if let cover = state.coverUrl.flatMap(URL.init(string:)) {
                CachedAsyncImage(url: cover, maxPixelSize: 600) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    SumiTheme.card
                }
                .frame(width: 128, height: 182)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 12, y: 6)
                .padding(.top, 20)
            }

            VStack(spacing: 6) {
                Text(state.title)
                    .font(.sumiHeading(size: 22, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(SumiTheme.foreground)
                Text(state.episodeTitle.isEmpty
                     ? "Episode \(state.episodeNumber)"
                     : "Episode \(state.episodeNumber) - \(state.episodeTitle)")
                    .font(.system(size: 14))
                    .foregroundStyle(SumiTheme.muted)
                Text("on \(client.hostName ?? node.name)")
                    .font(.system(size: 12))
                    .foregroundStyle(SumiTheme.muted.opacity(0.7))
            }
            .padding(.top, state.coverUrl == nil ? 24 : 0)

            scrubber

            HStack(spacing: 28) {
                transportButton("backward.end.fill", size: 22, enabled: state.hasPrevious) {
                    client.send(.previousEpisode)
                }
                transportButton("gobackward.10", size: 26) { client.send(.seekBy(-10)) }
                transportButton(
                    state.isBuffering ? "hourglass" : (state.isPlaying ? "pause.fill" : "play.fill"),
                    size: 40
                ) { client.send(.playPause) }
                transportButton("goforward.10", size: 26) { client.send(.seekBy(10)) }
                transportButton("forward.end.fill", size: 22, enabled: state.hasNext) {
                    client.send(.nextEpisode)
                }
            }

            skipButton

            volume

            options

            Button("Stop on \(client.hostName ?? node.name)", role: .destructive) {
                client.send(.stop)
            }
            .font(.system(size: 15, weight: .medium))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
    }

    private var scrubber: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { min(state.currentTime, max(state.duration, 1)) },
                    set: { seconds in
                        // Locally first: state arrives on a one-second tick,
                        // so a released thumb would otherwise snap back to
                        // where it started and read as a seek that failed.
                        client.optimisticallySeek(to: seconds)
                        client.send(.seek(to: seconds))
                    }
                ),
                in: 0...max(state.duration, 1)
            )
            .tint(SumiTheme.indigo)
            .disabled(state.duration <= 0)

            HStack {
                Text(PhonePlayerView.timestamp(state.currentTime))
                Spacer()
                Text(PhonePlayerView.timestamp(state.duration))
            }
            .font(.system(size: 12).monospacedDigit())
            .foregroundStyle(SumiTheme.muted)
        }
    }

    /// The Skip pill, mirrored. Present only while the Mac is showing its
    /// own -- pressing it takes that exact offer, so a button here that
    /// outlived the Mac's would seek into a window nobody is in any more.
    @ViewBuilder
    private var skipButton: some View {
        if client.hostSupports(RemoteFeature.skip), let label = state.skipLabel {
            Button {
                client.send(.skipPendingWindow)
            } label: {
                Label("Skip \(label)", systemImage: "forward.fill")
                    .font(.system(size: 15, weight: .medium))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(SumiTheme.card))
            }
            .foregroundStyle(SumiTheme.foreground)
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// Speed and autoplay, each drawn only when the attached Mac announced
    /// it can serve them. An older Mac drops a verb it has never heard of
    /// without answering, so an ungated control would be a control that
    /// silently does nothing.
    @ViewBuilder
    private var options: some View {
        HStack(spacing: 20) {
            if client.hostSupports(RemoteFeature.speed) {
                Menu {
                    ForEach(Self.speeds, id: \.self) { rate in
                        Button {
                            client.send(.setPlaybackRate(rate))
                        } label: {
                            if abs(state.playbackRate - rate) < 0.01 {
                                Label(Self.speedLabel(rate), systemImage: "checkmark")
                            } else {
                                Text(Self.speedLabel(rate))
                            }
                        }
                    }
                } label: {
                    Label(Self.speedLabel(state.playbackRate), systemImage: "speedometer")
                        .font(.system(size: 14))
                        .foregroundStyle(SumiTheme.muted)
                }
            }

            if client.hostSupports(RemoteFeature.tracks) {
                Button {
                    // Asked for on open rather than kept fresh: the Mac has
                    // to walk mpv's track list to answer, and nothing draws
                    // them while this sheet is closed.
                    client.send(.requestTracks)
                    showingTracks = true
                } label: {
                    Label("Tracks", systemImage: "captions.bubble")
                        .font(.system(size: 14))
                        .foregroundStyle(SumiTheme.muted)
                }
            }

            if client.hostSupports(RemoteFeature.upscale) {
                Button {
                    client.send(.setUpscaling(!state.upscalingEnabled))
                } label: {
                    Label("Upscale", systemImage: "sparkles")
                        .font(.system(size: 14))
                        .foregroundStyle(state.upscalingEnabled ? SumiTheme.indigo : SumiTheme.muted)
                }
            }

            if client.hostSupports(RemoteFeature.autoNext) {
                Button {
                    client.send(.setAutoPlayNext(!state.autoPlayNextEnabled))
                } label: {
                    Label(
                        "Autoplay",
                        systemImage: state.autoPlayNextEnabled
                            ? "play.square.stack.fill"
                            : "play.square.stack"
                    )
                    .font(.system(size: 14))
                    .foregroundStyle(state.autoPlayNextEnabled ? SumiTheme.indigo : SumiTheme.muted)
                }
            }
        }
    }

    /// Audio and subtitles for whatever the Mac has open.
    ///
    /// "Off" is prepended to the subtitle list here rather than sent by the
    /// Mac: it is not a track mpv reports, it is the absence of one, and the
    /// Mac already spells it `nil` on the wire.
    private var trackPicker: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    if client.audioTracks.isEmpty {
                        Text("No audio tracks reported")
                            .foregroundStyle(SumiTheme.muted)
                    }
                    ForEach(client.audioTracks) { track in
                        trackRow(track, isSelected: track.isSelected) {
                            client.send(.selectAudioTrack(track.id))
                        }
                    }
                }
                Section("Subtitles") {
                    trackRow(
                        RemoteTrack(id: RemoteTrack.off, lang: nil, title: "Off", isSelected: false, isForced: false),
                        isSelected: !client.subtitleTracks.contains { $0.isSelected }
                    ) {
                        client.send(.selectSubtitleTrack(nil))
                    }
                    ForEach(client.subtitleTracks) { track in
                        trackRow(track, isSelected: track.isSelected) {
                            client.send(.selectSubtitleTrack(track.id))
                        }
                    }
                }
            }
            .navigationTitle("Tracks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showingTracks = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func trackRow(
        _ track: RemoteTrack,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.trackLabel(track))
                        .foregroundStyle(SumiTheme.foreground)
                    if track.isForced {
                        Text("Forced")
                            .font(.system(size: 12))
                            .foregroundStyle(SumiTheme.muted)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(SumiTheme.indigo)
                }
            }
        }
    }

    static func trackLabel(_ track: RemoteTrack) -> String {
        let title = track.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lang = track.lang?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty, !lang.isEmpty { return "\(title) (\(lang))" }
        if !title.isEmpty { return title }
        if !lang.isEmpty { return lang }
        return "Track \(track.id)"
    }

    static let speeds: [Double] = [0.75, 1, 1.25, 1.5, 2]

    static func speedLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%gx", rate)
    }

    private var volume: some View {
        HStack(spacing: 14) {
            Button {
                client.send(.toggleMute)
            } label: {
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(SumiTheme.muted)
            }
            Slider(
                value: Binding(
                    get: { state.isMuted ? 0 : state.volume },
                    set: { client.send(.setVolume($0)) }
                ),
                in: 0...1
            )
            .tint(SumiTheme.indigo)
        }
    }

    private func transportButton(
        _ symbol: String,
        size: CGFloat,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundStyle(enabled ? SumiTheme.foreground : SumiTheme.muted.opacity(0.4))
                .frame(width: size + 14, height: size + 14)
        }
        .disabled(!enabled)
    }

    private func message(
        _ title: String,
        detail: String,
        symbol: String,
        showsRetry: Bool = false
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 34))
                .foregroundStyle(SumiTheme.muted)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(SumiTheme.foreground)
            Text(detail)
                .font(.system(size: 14))
                .multilineTextAlignment(.center)
                .foregroundStyle(SumiTheme.muted)
            if showsRetry {
                Button("Try Again") { client.connect(to: node) }
                    .font(.system(size: 15, weight: .medium))
                    .padding(.top, 6)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 80)
    }
}
#endif
