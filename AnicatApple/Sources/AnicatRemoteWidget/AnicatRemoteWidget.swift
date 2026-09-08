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
                // Tapping anywhere that is not a button opens the remote
                // itself. A widget can only ask for a URL, which is why
                // `anicat://remote` exists as a link rather than a flag.
                .widgetURL(URL(string: "anicat://remote"))
        } dynamicIsland: { context in
            let theme = context.attributes
            let state = context.state
            // As little as ActivityKit permits. `ActivityConfiguration`
            // requires a `dynamicIsland:` closure -- there is no way to run a
            // Live Activity without one -- so this says what is playing and
            // stops. No transport: the Island is glanced at over a keyboard
            // or in a pocket, and a row of buttons there was a second, worse
            // copy of the lock screen's.
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text("EP \(String(format: "%02d", state.episodeNumber))")
                        .font(SumiWidget.mono(12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.remainingStamp)
                        .font(SumiWidget.mono(12, weight: .medium))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(SumiWidget.heading(14, serif: theme.usesSerifHeadings))
                        .foregroundStyle(theme.foreground)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity)
                }
            } compactLeading: {
                Circle()
                    .fill(state.isPlaying ? theme.accent : theme.muted)
                    .frame(width: 6, height: 6)
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
            .widgetURL(URL(string: "anicat://remote"))
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
        VStack(spacing: 7) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.wash)
                    Capsule()
                        .fill(theme.accent)
                        // No minimum width. A 2pt stub at the start of an
                        // episode read as a dot someone had spilled on the
                        // rule rather than as progress; an empty rule says
                        // "just started" correctly.
                        .frame(width: geometry.size.width * state.fraction)
                }
            }
            .frame(height: 5)

            if showsStamps {
                HStack {
                    Text(state.elapsedStamp)
                    Spacer()
                    Text(state.remainingStamp)
                }
                .font(SumiWidget.mono(11))
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
        HStack(spacing: compact ? 12 : 20) {
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
        // Sized for a thumb on a locked phone, not for a pointer. The keys
        // were 32/38pt, under Apple's 44pt minimum, which is a hard target
        // to hit on a screen you are not looking at closely -- and this is
        // the surface most likely to be used without looking.
        let side: CGFloat = compact ? (emphasised ? 44 : 38) : (emphasised ? 56 : 48)
        return Button(intent: RemoteActivityButtonIntent(command: command)) {
            Image(systemName: symbol)
                .font(.system(size: emphasised ? side * 0.42 : side * 0.38, weight: .medium))
                .foregroundStyle(emphasised ? theme.background : theme.foreground)
                .frame(width: side, height: side)
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
        VStack(spacing: 11) {
            HStack(alignment: .top, spacing: 12) {
                EpisodeStamp(theme: attributes, number: state.episodeNumber)

                VStack(alignment: .leading, spacing: 4) {
                    // Two lines. Anime titles are long -- the one this was
                    // built against is "Love, Chunibyo & Other Delusions" --
                    // and a single line spent most of its width on an
                    // ellipsis where a second line would have finished the
                    // sentence.
                    Text(state.title)
                        .font(SumiWidget.heading(17, serif: attributes.usesSerifHeadings))
                        .foregroundStyle(attributes.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(state.subtitle)
                        .font(SumiWidget.mono(11))
                        .foregroundStyle(attributes.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ProgressRule(theme: attributes, state: state)

            HStack {
                Spacer(minLength: 0)
                Transport(theme: attributes, state: state)
                Spacer(minLength: 0)
            }
            // The keys sat in a pocket of dead space under the clocks
            // because the card's own padding was under them as well. They
            // ride up against the rule instead; the padding below is theirs
            // alone.
            .padding(.top, -2)
        }
        // The card is drawn edge to edge by the system, so every inset here
        // is ours to give. 20 rather than 16: at 16 the episode stamp and
        // the ends of the rule sat right on the rounded corner and read as
        // running off it.
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
        // Nothing inside may push past that inset. Without the clamp a long
        // title or a wide transport row grows the card's content instead of
        // wrapping or compressing, and the padding it grows through is the
        // padding that was supposed to hold it in.
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
