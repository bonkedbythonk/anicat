import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

/// Shown while `resolveAndPlay` is inside its `resolveStream` FFI call —
/// see the loading overlay's comment for why this exists instead of a bare
/// spinner. `TimelineView` rather than a `Timer`/`@State` tick: it's a
/// display-only clock with no state to manage or invalidate when the card
/// disappears.
struct ResolvingStreamCard: View {
    let startedAt: Date
    /// The engine's own phase ("Searching indexers", "Connecting to ...").
    /// The player is not mounted until the resolve returns, so on a first
    /// play this card is the only place that line can show.
    let status: String?
    let onCancel: () -> Void

    var body: some View {
        // A line across the top of the window, the same shape as the error
        // line: it shows on every play press, if only for a moment, and a
        // card floating in the corner with a drop shadow read as a web toast.
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(SumiTheme.indigo)

            Text(status ?? "Finding a stream…")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
                .lineLimit(1)
                .contentTransition(.opacity)
                .animation(.smooth, value: status)

            TimelineView(.periodic(from: startedAt, by: 1)) { context in
                let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                Text("\(elapsed)s")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }

            Spacer()

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 12.5))
                    .foregroundColor(SumiTheme.muted)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(SumiTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
    }
}
