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
        // A compact horizontal toast, same corner the mini-player uses —
        // not a centered modal. This shows on every single play
        // press (if only for a moment), so treating it like an alarming
        // blocking dialog was wrong to begin with; a small notification you
        // can glance at (or ignore) fits what it actually is.
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(0.8)
                .tint(SumiTheme.indigo)

            VStack(alignment: .leading, spacing: 1) {
                Text(status ?? "Finding a stream…")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: status)

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text("\(elapsed)s")
                        .sumiTabularMono(size: 10)
                        .foregroundColor(SumiTheme.muted)
                }
            }

            Button(action: onCancel) {
                Text("Cancel")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(SumiTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.sumiPressable)
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 56)
        .sumiCardStyle()
        .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
    }
}
