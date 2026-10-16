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
        // A 2pt moving line across the top of the window with the status
        // tucked under its trailing end. The first version was a full-width
        // opaque strip with a border and a spinner: it shows on every play
        // press, if only for a moment, and read as a heavy bar for that.
        // The text keeps a backing of the window colour, since bare text
        // over a poster grid is unreadable.
        VStack(spacing: 0) {
            SweepLine()

            HStack(spacing: 10) {
                Text(status ?? "Finding a stream…")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
                    .lineLimit(1)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: status)

                TimelineView(.periodic(from: startedAt, by: 1)) { context in
                    let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
                    Text("\(elapsed)s")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                }

                Button(action: onCancel) {
                    Text("Cancel")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.foreground)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(SumiTheme.background.opacity(0.9))
            .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.top, 6)
            .padding(.horizontal, 14)
        }
    }
}

/// Indeterminate: the resolve is one opaque FFI call with no fraction to
/// show, so a bar that fills to the right would promise progress it cannot
/// measure.
private struct SweepLine: View {
    @State private var sweeping = false

    var body: some View {
        GeometryReader { geo in
            let bar = geo.size.width * 0.3
            Rectangle()
                .fill(SumiTheme.indigo)
                .frame(width: bar)
                .offset(x: sweeping ? geo.size.width : -bar)
        }
        .frame(height: 2)
        .background(SumiTheme.border)
        .clipped()
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: false)) {
                sweeping = true
            }
        }
    }
}
