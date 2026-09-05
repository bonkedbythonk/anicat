import SwiftUI

/// Downloads: the offline queue.
///
/// Reads `AppModel.libraryDownloads`, populated by `AppModel.startDownload`
/// whenever an episode row's download button is tapped anywhere in the app.
/// The download itself runs on the Rust side and isn't tied to this view —
/// this just renders whatever `libraryDownloads` currently says.
public struct DownloadsView: View {
    let downloads: [AppModel.LibraryDownload]
    @State private var tab = "queue"

    public init(downloads: [AppModel.LibraryDownload]) {
        self.downloads = downloads
    }

    private var queued: [AppModel.LibraryDownload] {
        downloads.filter {
            switch $0.state {
            case .notStarted, .downloading, .failed: return true
            case .done: return false
            }
        }
    }

    private var offline: [AppModel.LibraryDownload] {
        downloads.filter {
            if case .done = $0.state { return true }
            return false
        }
    }

    public var body: some View {
        SumiPage {
            SumiPageHeader(title: "Downloads", subtitle: "\(queued.count) queued · \(offline.count) offline")

            SumiTabBar(
                tabs: [("queue", "Queue"), ("offline", "Offline")],
                selection: $tab
            )

            Group {
                let shown = tab == "queue" ? queued : offline
                if shown.isEmpty {
                    SumiEmptyState(
                        headline: tab == "queue" ? "Nothing queued" : "Nothing downloaded yet",
                        detail: "Episodes queued from a show's episode list will appear here."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(shown) { item in
                            DownloadRow(item: item)
                        }
                    }
                }
            }
            .animation(.smooth, value: tab)
        }
    }
}

private struct DownloadRow: View {
    let item: AppModel.LibraryDownload

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.coverURL, maxPixelSize: 96) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                SumiTheme.muted.opacity(0.15)
            }
            .frame(width: 40, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
                Text("Episode \(item.episode)")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
            }

            Spacer(minLength: 12)

            statusView
        }
        .padding(10)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
    }

    @ViewBuilder
    private var statusView: some View {
        switch item.state {
        case .notStarted:
            Text("Queued").sumiTabularMono(size: 11).foregroundColor(SumiTheme.muted)
        case .downloading(let percent):
            HStack(spacing: 6) {
                ProgressView(value: min(max(percent / 100, 0), 1))
                    .frame(width: 80)
                Text("\(Int(percent))%").sumiTabularMono(size: 11).foregroundColor(SumiTheme.muted)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(SumiTheme.successLight)
        case .failed(let message):
            Image(systemName: "exclamationmark.circle")
                .foregroundColor(SumiTheme.dangerLight)
                .help("Download failed: \(message)")
        }
    }
}
