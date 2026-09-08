import ActivityKit
import AppIntents
import AnicatRemoteActivity
import SwiftUI
import WidgetKit

/// The lock screen and Dynamic Island face of the phone remote.
///
/// Deliberately not a Now Playing tile: iOS hands that slot to whichever app
/// owns an active audio session, and a remote plays no audio. Claiming it
/// would mean looping a silent track, which takes audio focus away from
/// whatever the person is actually listening to.
@main
struct AnicatRemoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemoteLiveActivityWidget()
    }
}

struct RemoteLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RemoteActivityAttributes.self) { context in
            lockScreen(context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "macbook.and.iphone")
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.state.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 8) {
                        progress(context.state)
                        transport(context.state)
                    }
                }
            } compactLeading: {
                Image(systemName: context.state.isPlaying ? "play.fill" : "pause.fill")
            } compactTrailing: {
                Text(Self.remaining(context.state))
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "macbook.and.iphone")
            }
        }
    }

    private func lockScreen(_ context: ActivityViewContext<RemoteActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text(context.state.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Text("on \(context.attributes.hostName)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            progress(context.state)
            transport(context.state)
        }
        .padding()
        .activityBackgroundTint(nil)
    }

    /// A plain bar rather than a `ProgressView(timerInterval:)`: the Mac is
    /// the clock here, and a self-running timer would keep counting through
    /// a pause the phone has not been told about yet.
    private func progress(_ state: RemoteActivityAttributes.ContentState) -> some View {
        ProgressView(value: min(state.currentTime, max(state.duration, 1)), total: max(state.duration, 1))
            .tint(.primary)
    }

    private func transport(_ state: RemoteActivityAttributes.ContentState) -> some View {
        HStack(spacing: 18) {
            Button(intent: RemoteActivityButtonIntent(command: .back10)) {
                Image(systemName: "gobackward.10")
            }
            Button(intent: RemoteActivityButtonIntent(command: .playPause)) {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
            }
            Button(intent: RemoteActivityButtonIntent(command: .forward10)) {
                Image(systemName: "goforward.10")
            }
            if let label = state.skipLabel {
                Button(intent: RemoteActivityButtonIntent(command: .skipWindow)) {
                    Label("Skip \(label)", systemImage: "forward.fill")
                        .font(.caption)
                }
            }
        }
        .buttonStyle(.plain)
        .labelStyle(.titleAndIcon)
    }

    static func remaining(_ state: RemoteActivityAttributes.ContentState) -> String {
        let left = max(state.duration - state.currentTime, 0)
        let minutes = Int(left) / 60
        return "\(minutes)m"
    }
}
