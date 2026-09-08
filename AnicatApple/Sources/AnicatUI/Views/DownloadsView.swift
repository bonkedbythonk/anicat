import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

/// Downloads: the offline queue.
///
/// Reads `AppModel.libraryDownloads`, populated by `AppModel.startDownload`
/// whenever an episode row's download button is tapped anywhere in the app.
/// The download itself runs on the Rust side and isn't tied to this view —
/// this just renders whatever `libraryDownloads` currently says.
public struct DownloadsView: View {
    let downloads: [AppModel.LibraryDownload]
    /// Opens the finished file (`AppModel.playDownloadedFile`). Optional
    /// because the list is model state this view only reads: an unwired
    /// caller shows no Play button rather than a dead one.
    let onPlay: ((AppModel.LibraryDownload) -> Void)?
    /// Drops the row from `libraryDownloads`. Optional for the same reason:
    /// the list is model state this view only reads.
    let onRemove: ((AppModel.LibraryDownload) -> Void)?
    /// Chapters kept for offline reading. Episodes and chapters share this
    /// page because they are one question -- what is on this disk -- and
    /// separate pages would make the answer two places.
    var chapters: [FfiOfflineChapter] = []
    var chapterBytes: UInt64 = 0
    /// What the library is held to, for the header. Zero means no cap.
    var chapterCapBytes: UInt64 = 0
    /// Names for the ids the registry stores, from whatever the app has
    /// loaded. A chapter downloaded months ago may be on no shelf.
    var titles: [Int64: String] = [:]
    var onRemoveChapter: ((FfiOfflineChapter) -> Void)?
    @State private var tab = "queue"

    public init(
        downloads: [AppModel.LibraryDownload],
        onPlay: ((AppModel.LibraryDownload) -> Void)? = nil,
        onRemove: ((AppModel.LibraryDownload) -> Void)? = nil,
        chapters: [FfiOfflineChapter] = [],
        chapterBytes: UInt64 = 0,
        chapterCapBytes: UInt64 = 0,
        titles: [Int64: String] = [:],
        onRemoveChapter: ((FfiOfflineChapter) -> Void)? = nil
    ) {
        self.downloads = downloads
        self.onPlay = onPlay
        self.onRemove = onRemove
        self.chapters = chapters
        self.chapterBytes = chapterBytes
        self.chapterCapBytes = chapterCapBytes
        self.titles = titles
        self.onRemoveChapter = onRemoveChapter
    }

    /// A row can be removed once its download has stopped moving. Removing a
    /// `.downloading` row would put it straight back: `AppModel.startDownload`
    /// polls every second and re-adds the row through `setLibraryDownload`
    /// until the download reaches a terminal state, and there is no engine
    /// call to cancel one in flight — so the button is not offered rather
    /// than offered and silently undone.
    ///
    /// `nonisolated` because `View` is `@MainActor` and a static member
    /// inherits that; the tests run off the main actor — see the note on
    /// `MangaReaderView.prefetchIndices` for what that isolation did to the
    /// test process.
    nonisolated static func isRemovable(_ state: MediaDetailView.EpisodeDownloadState) -> Bool {
        switch state {
        case .downloading: return false
        case .notStarted, .done, .failed: return true
        }
    }

    /// Where a finished download landed, or nil while it is still coming
    /// down. The only thing that distinguishes a row with a Play and a Reveal
    /// from a row with neither.
    nonisolated static func donePath(_ state: MediaDetailView.EpisodeDownloadState) -> String? {
        if case .done(let path) = state { return path }
        return nil
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

    /// What the list's `.animation(value:)` watches. `LibraryDownload` is
    /// not `Equatable` (see `AppModel.downloadSignature`), and a change that
    /// keeps a row where it is (a percentage tick) must not re-run the row
    /// transition, so this is ids plus done-ness: which rows exist and
    /// which tab each belongs to.
    private var membership: [String] {
        downloads.map { "\($0.id):\(Self.donePath($0.state) != nil)" }
    }

    public var body: some View {
        SumiPage {
            SumiPageHeader(
                title: "Downloads",
                subtitle: chapters.isEmpty
                    ? "\(queued.count) queued · \(offline.count) offline"
                    : "\(queued.count) queued · \(offline.count) offline · \(chapters.count) chapters, \(usage)"
            )

            SumiTabBar(
                tabs: [("queue", "Queue"), ("offline", "Offline"), ("chapters", "Chapters")],
                selection: $tab
            )

            Group {
                if tab == "chapters" {
                    chapterList
                } else {
                let shown = tab == "queue" ? queued : offline
                if shown.isEmpty {
                    SumiEmptyState(
                        headline: tab == "queue" ? "Nothing queued" : "Nothing downloaded yet",
                        detail: "Episodes queued from a show's episode list will appear here."
                    )
                } else {
                    VStack(spacing: 8) {
                        ForEach(shown) { item in
                            DownloadRow(item: item, onPlay: onPlay, onRemove: onRemove)
                                .transition(.asymmetric(
                                    insertion: .opacity,
                                    removal: .scale(scale: 0.96).combined(with: .opacity)
                                ))
                        }
                    }
                }
                }
            }
            .animation(.smooth, value: tab)
            // Without an animated value on the list a removed row vanished
            // and the rows under it jumped up in the same frame. Keyed on
            // membership rather than the array itself so a finished download
            // leaving Queue for Offline animates out the same way.
            .animation(.snappy, value: membership)
        }
    }

    /// Chapters on disk, newest first, each removable.
    @ViewBuilder
    private var chapterList: some View {
        if chapters.isEmpty {
            SumiEmptyState(
                headline: "No chapters downloaded",
                detail: "Download a chapter from a manga's chapter list to read it with no network."
            )
        } else {
            VStack(spacing: 8) {
                ForEach(chapters, id: \.chapterId) { chapter in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(titles[chapter.catalogId] ?? chapter.title ?? "Media \(chapter.catalogId)")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)
                            Text("CH \(chapter.chapterNumber) · \(chapter.pageCount) pages · \(Self.size(chapter.bytes))")
                                .sumiTabularMono(size: 11)
                                .foregroundColor(SumiTheme.muted)
                        }
                        Spacer()
                        if let onRemoveChapter {
                            Button {
                                onRemoveChapter(chapter)
                            } label: {
                                Text("Remove")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundColor(SumiTheme.muted)
                            }
                            .buttonStyle(.sumiPressable)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(SumiTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                }
            }
        }
    }

    /// "14 MB of 2 GB", or just the size when there is no cap. The ceiling
    /// is worth saying: chapters leave on their own once it is reached, and
    /// a list that shrinks by itself needs to have said why in advance.
    private var usage: String {
        chapterCapBytes == 0
            ? Self.size(chapterBytes)
            : "\(Self.size(chapterBytes)) of \(Self.size(chapterCapBytes))"
    }

    /// Bytes as the page says them. Rounded: the exact figure is noise next
    /// to "is this worth removing".
    static func size(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1024)
    }
}

private struct DownloadRow: View {
    let item: AppModel.LibraryDownload
    let onPlay: ((AppModel.LibraryDownload) -> Void)?
    let onRemove: ((AppModel.LibraryDownload) -> Void)?

    @State private var removeConfirming = false

    private var donePath: String? { DownloadsView.donePath(item.state) }
    private var isRemovable: Bool { DownloadsView.isRemovable(item.state) }

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

            actions

            statusView
        }
        .padding(10)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        // Leaving the row and coming back should not still be one click away
        // from deleting it.
        .onHover { inside in if !inside { removeConfirming = false } }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 4) {
            if let onPlay, donePath != nil {
                iconButton("play.fill", help: "Play episode \(item.episode)") { onPlay(item) }
            }

            #if os(macOS)
            if let path = donePath {
                iconButton("folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            #endif

            if let onRemove, isRemovable {
                // Two-step confirm, same shape as Settings' maintenance
                // buttons: the label becomes the question rather than a sheet
                // interrupting a page that is otherwise all one-click rows.
                Button {
                    if removeConfirming {
                        onRemove(item)
                        removeConfirming = false
                    } else {
                        removeConfirming = true
                    }
                } label: {
                    Group {
                        if removeConfirming {
                            Text("Remove?")
                                .font(.system(size: 11, weight: .semibold))
                        } else {
                            Image(systemName: "trash")
                                .font(.system(size: 11.5))
                        }
                    }
                    .foregroundColor(SumiTheme.dangerLight)
                    .frame(height: 24)
                    .padding(.horizontal, removeConfirming ? 8 : 6)
                    .background(removeConfirming ? SumiTheme.danger.opacity(0.18) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(removeConfirming ? "Click again to remove this row" : "Remove from the list")
            }
        }
        .animation(.snappy, value: removeConfirming)
    }

    private func iconButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5))
                .foregroundColor(SumiTheme.muted)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .help(help)
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
