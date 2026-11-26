import SwiftUI
import AnicatCoreKit

/// The `.manga` tab. Split out of `tabContent` alongside the other tabs
/// below so switching tabs, or any one tab's own state changing, only
/// re-evaluates that tab's struct instead of the whole detail page body.
struct MangaTabSection: View {
    /// Volumes of a light novel, or an honest word about why there are none.
    ///
    /// This tab used to say reading "isn't available yet" for every novel,
    /// because nothing resolved a catalogue entry to a source at all. Most
    /// AniList light novels still have no indexed English translation, so a
    /// miss stays a first-class outcome rather than an error.
    @ViewBuilder
    var novelVolumeList: some View {
        if !lnoriEnabled {
            // Downloaded volumes stay listed under the card: they are read
            // from disk and never reach the site the switch is about.
            VStack(alignment: .leading, spacing: 12) {
                lnoriDisabledCard
                if !novelVolumes.isEmpty {
                    LazyVStack(spacing: 0) {
                        ForEach(novelVolumes, id: \.url) { volume in
                            volumeRow(volume)
                        }
                    }
                }
            }
        } else if isLoadingNovelVolumes {
            EpisodeListSkeleton(count: 4, isCompact: true)
        } else if !novelVolumes.isEmpty {
            LazyVStack(spacing: 0) {
                ForEach(novelVolumes, id: \.url) { volume in
                    volumeRow(volume)
                }
            }
        } else if novelSourceMissing {
            SumiEmptyState(
                headline: "No readable copy found",
                detail: "No English translation of this novel is indexed. Titles that are translated open here; the rest can still be read by pasting a Syosetu link into the Light Novels page."
            )
        } else {
            SumiEmptyState(
                headline: "No chapters found",
                detail: "Nothing readable was found for this title."
            )
        }
    }

    /// Why the list is empty before the switch has ever been touched, and
    /// the switch itself: the reason and the choice on one card, so turning
    /// it on is not a trip to Settings and back. Same dashed frame as the
    /// miss state above; `SumiEmptyState` has no slot for a control.
    private var lnoriDisabledCard: some View {
        VStack(spacing: 8) {
            Text("Official volumes are off")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
            Text("Official volumes come from a third-party site that hosts licensed light novels. It is off until you turn it on.")
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 10) {
                Text("Official volumes")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                lnoriSwitch
            }
            .padding(.top, 6)
            Text("Web novels from Syosetu are unaffected.")
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
        .overlay(
            SumiRect(cornerRadius: SumiTheme.radiusLg)
                .strokeBorder(SumiTheme.border, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }

    private var lnoriSwitch: some View {
        SumiSwitch(isOn: $lnoriEnabled)
    }

    /// One volume, ruled like the chapter rows: its title and its state in
    /// words. Download, removal and the EPUB export are the context menu; as
    /// two icons in a boxed card per volume they were the only boxed rows
    /// left on the page.
    @ViewBuilder
    private func volumeRow(_ volume: NovelChapterRef) -> some View {
        let state = novelVolumeStates[volume.url] ?? .none
        Button { onReadVolume?(volume) } label: {
            HStack(spacing: 12) {
                Text(volume.title)
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(Self.volumeStateLabel(state))
                    .font(.system(size: 11.5))
                    .foregroundColor(state == .failed ? SumiTheme.danger : (state == .stored ? SumiTheme.success : SumiTheme.muted))
                    .lineLimit(1)
            }
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SumiTheme.border).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .contextMenu {
            Button("Read") { onReadVolume?(volume) }
            Divider()
            if state == .stored {
                Button("Remove download") { onDeleteVolumeDownload?(volume) }
            } else if state != .downloading {
                Button(state == .failed ? "Retry download" : "Download for offline reading") { onDownloadVolume?(volume) }
            }
            // Offered whether or not the volume is downloaded: it downloads
            // first when it has to, so sending a book to a reader is one
            // action rather than two in an order the user has to know.
            if state != .exporting {
                Button("Save as EPUB…") { onExportVolume?(volume) }
            }
        }
    }

    private static func volumeStateLabel(_ state: MediaDetailView.ChapterOfflineState) -> String {
        switch state {
        case .stored: return "Downloaded"
        case .downloading: return "Downloading"
        case .exporting: return "Saving EPUB"
        case .failed: return "Download failed"
        case .none: return ""
        }
    }

    let chapters: [MediaDetailView.MangaChapterItem]
    let format: String?
    /// AniList's chapter progress: its group opens by default.
    var readProgress: Int?
    // Which groups are open, keyed by their first row's index.
    @State private var expandedGroups: Set<Int> = []
    var isLoading: Bool = false
    // `AppModel.isLnoriEnabled` owns the reader and the default (off);
    // `@AppStorage` needs a literal here, so the two must agree.
    @AppStorage("anicat_lnori_enabled") private var lnoriEnabled: Bool = false
    var novelVolumes: [NovelChapterRef] = []
    var isLoadingNovelVolumes: Bool = false
    var novelSourceMissing: Bool = false
    var onReadVolume: ((NovelChapterRef) -> Void)?
    var novelVolumeStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    var onDownloadVolume: ((NovelChapterRef) -> Void)?
    var onDeleteVolumeDownload: ((NovelChapterRef) -> Void)?
    var onExportVolume: ((NovelChapterRef) -> Void)?
    // `AppModel.isJapaneseManga` owns the reader and the default (off).
    @AppStorage("anicat_manga_japanese") private var japaneseManga: Bool = false
    /// Which chapters are on disk, or on their way there. Keyed by chapter
    /// id because that is what the registry and the files are keyed on.
    var offlineStates: [String: MediaDetailView.ChapterOfflineState] = [:]
    var onDownloadChapter: ((MediaDetailView.MangaChapterItem) -> Void)?
    var onDeleteChapterDownload: ((MediaDetailView.MangaChapterItem) -> Void)?
    let onReadChapter: (MediaDetailView.MangaChapterItem) -> Void

    var body: some View {
        list
    }

    @ViewBuilder
    private var list: some View {
        if chapters.isEmpty {
            if isLoading {
                EpisodeListSkeleton(count: 6, isCompact: true)
            } else if format == "NOVEL" {
                novelVolumeList
            } else if japaneseManga {
                SumiEmptyState(
                    headline: "No Japanese chapters",
                    detail: "Sen Manga does not carry this title under its romaji name. Switch to English to read the English chapters."
                )
            } else {
                SumiEmptyState(headline: "No chapters found", detail: "No chapters were found for this title.")
            }
        } else if let groups = chapterGroups {
            LazyVStack(spacing: 8) {
                ForEach(groups, id: \.start) { group in
                    ExpandableGroup(
                        title: "Chapters \(group.chapters.first?.number ?? "")-\(group.chapters.last?.number ?? "")",
                        isExpanded: Binding(member: group.start, of: $expandedGroups)
                    ) {
                        chapterRows(group.chapters)
                    }
                }
            }
            // Added, never swapped in, so a group the reader opened stays
            // open when progress moves on.
            .task(id: [chapters.count, readProgress ?? -1]) {
                let next = Double((readProgress ?? 0) + 1)
                let owning = groups.first { group in
                    group.chapters.contains { (Double($0.number) ?? -1) >= next }
                } ?? groups.last
                if let owning { expandedGroups.insert(owning.start) }
            }
        } else {
            LazyVStack(spacing: 0) {
                chapterRows(chapters[...])
            }
        }
    }

    /// The episode list's grouping, for chapters (owner: "bundle manga
    /// chapters like it does with anime so its not a huge list"). 50 rather
    /// than 26: chapters are read in minutes, not watched in 24, and a
    /// long-runner goes to 1,000 and more (Martial Peak lists 3,844).
    private static let groupSize = 50

    private var chapterGroups: [(start: Int, chapters: ArraySlice<MediaDetailView.MangaChapterItem>)]? {
        guard chapters.count > Self.groupSize else { return nil }
        return stride(from: 0, to: chapters.count, by: Self.groupSize).map { start in
            (start, chapters[start..<min(start + Self.groupSize, chapters.count)])
        }
    }

    /// The first chapter numbered past AniList's progress: the one the
    /// header's button opens, so the row it names says so.
    private var nextChapterId: String? {
        let progress = Double(readProgress ?? 0)
        return chapters.first { (Double($0.number) ?? -1) > progress }?.id
    }

    private func chapterRows(_ rows: ArraySlice<MediaDetailView.MangaChapterItem>) -> some View {
        let next = nextChapterId
        return ForEach(rows) { chapter in
            MediaDetailView.ChapterRowView(
                chapter: chapter,
                isRead: (Double(chapter.number) ?? .infinity) <= Double(readProgress ?? 0),
                isNext: chapter.id == next,
                offline: offlineStates[chapter.id] ?? .none,
                onDownload: onDownloadChapter.map { action in { action(chapter) } },
                onDeleteDownload: onDeleteChapterDownload.map { action in { action(chapter) } }
            ) {
                onReadChapter(chapter)
            }
        }
    }
}
