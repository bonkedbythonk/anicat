import ActivityKit
import AppIntents
import AnicatRemoteActivity
import SwiftUI
import WidgetKit

/// The lock screen and Dynamic Island face of the phone remote, in the app's
/// own Ink & Index look rather than the system's default chrome.
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
            LockScreenView(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(context.attributes.background)
                .activitySystemActionForegroundColor(context.attributes.accent)
        } dynamicIsland: { context in
            let theme = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    EpisodeStamp(theme: theme, number: state.episodeNumber)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(state.remainingStamp)
                            .font(SumiWidget.mono(13, weight: .medium))
                            .foregroundStyle(theme.foreground)
                        Text(theme.hostName.uppercased())
                            .font(SumiWidget.mono(8))
                            .tracking(0.8)
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(SumiWidget.heading(15, serif: theme.usesSerifHeadings))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 12) {
                        ProgressRule(theme: theme, state: state)
                        Transport(theme: theme, state: state, compact: true)
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                // The accent tick, not a play glyph: the compact Island is
                // four characters wide and the clock beside it already says
                // whether anything is moving.
                HStack(spacing: 3) {
                    Circle()
                        .fill(state.isPlaying ? theme.accent : theme.muted)
                        .frame(width: 6, height: 6)
                    Text("\(state.episodeNumber)")
                        .font(SumiWidget.mono(12, weight: .medium))
                        .foregroundStyle(theme.foreground)
                }
            } compactTrailing: {
                Text(state.remainingStamp)
                    .font(SumiWidget.mono(12))
                    .foregroundStyle(theme.muted)
            } minimal: {
                Circle()
                    .fill(state.isPlaying ? theme.accent : theme.muted)
                    .frame(width: 8, height: 8)
            }
            .keylineTint(theme.accent)
        }
    }
}

/// The index stamp: the register the app sets episode numbers, chapters and
/// clocks in, and the one element that survives every size this activity is
/// drawn at.
private struct EpisodeStamp: View {
    let theme: RemoteActivityAttributes
    let number: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("EP")
                .font(SumiWidget.mono(8, weight: .medium))
                .tracking(1.4)
                .foregroundStyle(theme.muted)
            Text(String(format: "%02d", number))
                .font(SumiWidget.mono(20, weight: .semibold))
                .foregroundStyle(theme.accent)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(theme.border, lineWidth: 1)
                )
        )
    }
}

/// A ruled line with the played part inked in, and the clocks stamped under
/// its two ends.
private struct ProgressRule: View {
    let theme: RemoteActivityAttributes
    let state: RemoteActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.wash)
                    Capsule()
                        .fill(theme.accent)
                        .frame(width: max(geometry.size.width * state.fraction, 2))
                }
            }
            .frame(height: 3)

            HStack {
                Text(state.elapsedStamp)
                Spacer()
                Text(state.remainingStamp)
            }
            .font(SumiWidget.mono(10))
            .foregroundStyle(theme.muted)
        }
    }
}

private struct Transport: View {
    let theme: RemoteActivityAttributes
    let state: RemoteActivityAttributes.ContentState
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 14 : 18) {
            key(.back10, symbol: "gobackward.10")
            key(
                .playPause,
                symbol: state.isPlaying ? "pause.fill" : "play.fill",
                emphasised: true
            )
            key(.forward10, symbol: "goforward.10")

            if let label = state.skipLabel {
                Button(intent: RemoteActivityButtonIntent(command: .skipWindow)) {
                    Text("SKIP \(label.uppercased())")
                        .font(SumiWidget.mono(9, weight: .medium))
                        .tracking(1)
                        .foregroundStyle(theme.background)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(theme.accent))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func key(
        _ command: RemoteActivityCommand,
        symbol: String,
        emphasised: Bool = false
    ) -> some View {
        Button(intent: RemoteActivityButtonIntent(command: command)) {
            Image(systemName: symbol)
                .font(.system(size: emphasised ? 17 : 14, weight: .medium))
                .foregroundStyle(emphasised ? theme.background : theme.foreground)
                .frame(width: emphasised ? 38 : 32, height: emphasised ? 38 : 32)
                .background(
                    Circle()
                        .fill(emphasised ? theme.accent : theme.card)
                        .overlay(
                            Circle().strokeBorder(emphasised ? .clear : theme.border, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

private struct LockScreenView: View {
    let attributes: RemoteActivityAttributes
    let state: RemoteActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                EpisodeStamp(theme: attributes, number: state.episodeNumber)

                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(SumiWidget.heading(17, serif: attributes.usesSerifHeadings))
                        .foregroundStyle(attributes.foreground)
                        .lineLimit(1)
                    Text(state.subtitle)
                        .font(SumiWidget.mono(11))
                        .foregroundStyle(attributes.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                // The card's own filing label: which machine this is
                // driving, set in the same stamped register as the clocks.
                VStack(alignment: .trailing, spacing: 2) {
                    Text("ON")
                        .font(SumiWidget.mono(8, weight: .medium))
                        .tracking(1.4)
                    Text(attributes.hostName.uppercased())
                        .font(SumiWidget.mono(9, weight: .medium))
                        .tracking(0.6)
                        .lineLimit(1)
                }
                .foregroundStyle(attributes.muted)
                .frame(maxWidth: 96, alignment: .trailing)
            }

            ProgressRule(theme: attributes, state: state)

            Transport(theme: attributes, state: state)
        }
        .padding(14)
    }
}
