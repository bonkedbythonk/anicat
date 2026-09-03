import SwiftUI

/// Downloads: the offline queue.
///
/// The queue is empty by construction in this build and will stay that way
/// until the native playback path can enqueue — the Tauri app filled it from
/// its own download commands, and none of that has been ported. The view is
/// real so the shape is settled; what it lists is not invented.
public struct DownloadsView: View {
    public init() {}

    public var body: some View {
        SumiPage {
            SumiPageHeader(title: "Downloads", subtitle: "0 queued · 0 offline")

            SumiTabBar(
                tabs: [("queue", "Queue"), ("offline", "Offline")],
                selection: .constant("queue")
            )
            .disabled(true)
            .opacity(0.5)

            SumiEmptyState(
                headline: "Nothing downloaded yet",
                detail: "Downloading is not wired up in the native build yet. Episodes queued from a show's episode list will appear here."
            )
        }
    }
}
