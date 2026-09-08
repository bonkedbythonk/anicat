#if os(iOS)
import SwiftUI

/// The phone as a remote for a Mac running Anicat on the same Wi-Fi.
///
/// A sheet rather than a tab or a page: it is only reachable while a Mac is
/// actually advertising, and a permanent control that is dead most of the
/// time is the thing the Films & TV segment is already hidden to avoid.
struct PhoneRemoteView: View {
    let node: BonjourDiscovery.DiscoveredNode
    @Environment(\.dismiss) private var dismiss

    private var client: RemoteClient { RemoteClient.shared }

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
                            detail: "Open a title and choose Play on Mac, or start something on \(node.name).",
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task {
            // Dialled from here and nowhere else. The first hello raises an
            // approval alert on the Mac, so connecting on discovery would
            // interrupt whoever is sitting at it with nobody having asked
            // for a remote.
            if client.status != .connected { client.connect(to: node) }
        }
    }

    // MARK: - Transport

    private var state: RemoteState { client.state }

    private var transport: some View {
        VStack(spacing: 28) {
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
            .padding(.top, 24)

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

            volume

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
