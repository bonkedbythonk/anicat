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
                // The expanded Island's leading and trailing regions are
                // narrow columns beside the camera, not halves of a row: the
                // full index card was squeezed to a sliver there and the
                // countdown wrapped onto two lines. Only the two short
                // stamps go in them, and everything with a width goes in
                // `.center` and `.bottom`.
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("EP")
                            .font(SumiWidget.mono(8, weight: .medium))
                            .tracking(1.4)
                            .foregroundStyle(theme.muted)
                        Text(String(format: "%02d", state.episodeNumber))
                            .font(SumiWidget.mono(17, weight: .semibold))
                            .foregroundStyle(theme.accent)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.remainingStamp)
                        .font(SumiWidget.mono(13, weight: .medium))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .fixedSize()
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 1) {
                        Text(state.title)
                            .font(SumiWidget.heading(14, serif: theme.usesSerifHeadings))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(state.subtitle)
                            .font(SumiWidget.mono(10))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        ProgressRule(theme: theme, state: state, showsStamps: false)
                        Transport(theme: theme, state: state, compact: true)
                    }
                    .padding(.top, 4)
                }
            } compactLeading: {
                // The accent tick, not a play glyph: the compact Island is
                // a few characters wide and the clock beside it already says
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
                    .fixedSize()
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
    /// Off inside the Island, where the countdown is already stamped in the
    /// trailing column and a second copy of it reads as a duplicate.
    var showsStamps = true

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

            if showsStamps {
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

                // The title takes the whole width it can. A right-hand
                // "ON <MAC>" column used to sit here and it lost twice: it
                // truncated the title to about half the card and then
                // truncated its own machine name anyway. The host is filed
                // under the clocks instead, where a long name has the room
                // to be read.
                VStack(alignment: .leading, spacing: 3) {
                    Text(state.title)
                        .font(SumiWidget.heading(17, serif: attributes.usesSerifHeadings))
                        .foregroundStyle(attributes.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(state.subtitle)
                        .font(SumiWidget.mono(11))
                        .foregroundStyle(attributes.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)
            }

            ProgressRule(theme: attributes, state: state)

            HStack(alignment: .center) {
                Text("ON \(attributes.hostName.uppercased())")
                    .font(SumiWidget.mono(9, weight: .medium))
                    .tracking(0.6)
                    .foregroundStyle(attributes.muted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Transport(theme: attributes, state: state)
            }
        }
        .padding(14)
    }
}
