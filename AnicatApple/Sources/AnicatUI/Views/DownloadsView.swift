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

    /// Finished files' sizes by path, and the free space on their volume.
    /// Read off the main actor: the volume query can take tens of
    /// milliseconds, and the body re-runs on every 1s progress tick.
    @State private var fileBytes: [String: UInt64] = [:]
    @State private var freeBytes: UInt64?
    /// Titles opened to show their single episodes or chapters.
    @State private var expanded: Set<String> = []
    @State private var pending: PendingDelete?

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

    /// A row restored without a name is renamed in place once the lookup
    /// lands (`applyResolvedDownloadTitles`); the map is the shortcut for an
    /// AniList id a shelf has named since.
    private func displayTitle(_ row: AppModel.LibraryDownload) -> String {
        row.catalog == .anilist && row.title == AppModel.placeholderTitle(row.catalogId)
            ? (titles[row.catalogId] ?? row.title)
            : row.title
    }

    /// Rows grouped under the title they belong to, titles in the order
    /// their newest row appears.
    ///
    /// A flat list was fine with three downloads and unreadable with thirty:
    /// four episodes of one show and two of another interleaved by whenever
    /// each happened to finish. The files have always been grouped this way
    /// on disk (`Downloads/Anicat/<title>/`); this is the page catching up.
    private func grouped(_ rows: [AppModel.LibraryDownload]) -> [(String, [AppModel.LibraryDownload])] {
        var order: [String] = []
        var byTitle: [String: [AppModel.LibraryDownload]] = [:]
        for row in rows {
            let title = displayTitle(row)
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(row)
        }
        return order.map { title in
            // Episodes in their own order inside a show, whatever order they
            // were fetched in.
            (title, (byTitle[title] ?? []).sorted { $0.episode < $1.episode })
        }
    }

    /// Chapters grouped the same way.
    private var groupedChapters: [(String, [FfiOfflineChapter])] {
        var order: [String] = []
        var byTitle: [String: [FfiOfflineChapter]] = [:]
        for row in chapters {
            let title = titles[row.catalogId] ?? row.title ?? "Media \(row.catalogId)"
            if byTitle[title] == nil { order.append(title) }
            byTitle[title, default: []].append(row)
        }
        return order.map { title in
            (title, (byTitle[title] ?? []).sorted {
                (Double($0.chapterNumber) ?? 0) < (Double($1.chapterNumber) ?? 0)
            })
        }
    }

    /// What the list's `.animation(value:)` watches. `LibraryDownload` is
    /// not `Equatable` (see `AppModel.downloadSignature`), and a change that
    /// keeps a row where it is (a percentage tick) must not re-run the row
    /// transition, so this is ids plus done-ness: which rows exist and
    /// which section each belongs to.
    private var membership: [String] {
        downloads.map { "\($0.id):\(Self.donePath($0.state) != nil)" }
    }

    private var usedBytes: UInt64 {
        offline.reduce(chapterBytes) { $0 + (Self.donePath($1.state).flatMap { fileBytes[$0] } ?? 0) }
    }

    public var body: some View {
        SumiPage {
            VStack(alignment: .leading, spacing: 12) {
                SumiPageHeader(title: "Downloads", subtitle: summary)
                if let freeBytes, usedBytes > 0 {
                    DownloadBar(fraction: Double(usedBytes) / Double(usedBytes + freeBytes), height: 6)
                }
            }

            Group {
                if downloads.isEmpty && chapters.isEmpty {
                    SumiEmptyState(
                        headline: "Nothing downloaded yet",
                        detail: "Episodes queued from a show's episode list, and chapters kept from a manga's, will appear here.",
                        art: "empty"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        if !queued.isEmpty { inProgressSection }
                        if !offline.isEmpty || !chapters.isEmpty { onDiskSection }
                    }
                }
            }
            // Without an animated value on the list a removed row vanished
            // and the rows under it jumped up in the same frame. Keyed on
            // membership rather than the array itself so a finished download
            // leaving In progress for On this Mac animates out the same way.
            .animation(.snappy, value: membership)
            .animation(.snappy, value: expanded)
        }
        .overlay {
            if let pending {
                DeleteSheet(pending: pending) { self.pending = nil }
                    .transition(.opacity)
            }
        }
        .animation(.snappy, value: pending?.id)
        .task(id: membership) { await measure() }
    }

    private func measure() async {
        let paths = offline.compactMap { Self.donePath($0.state) }
        let probe = paths.first ?? NSHomeDirectory()
        let (sizes, free) = await Task.detached(priority: .utility) {
            var sizes: [String: UInt64] = [:]
            for path in paths {
                sizes[path] = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? UInt64) ?? 0
            }
            return (sizes, Self.freeSpace(at: probe))
        }.value
        fileBytes = sizes
        freeBytes = free
    }

    nonisolated private static func freeSpace(at path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        #if os(tvOS)
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity.map(Int64.init)
        #else
        // The "important usage" figure counts purgeable space the system
        // will clear for a download; the plain capacity key reported a
        // fraction of what Finder shows.
        let free = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
        #endif
        return free.map { UInt64(max($0, 0)) }
    }

    // MARK: - In progress

    private var inProgressSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SumiSectionHeader("In progress")
            VStack(spacing: 0) {
                ForEach(queued) { item in
                    progressRow(item).transition(.opacity)
                }
            }
        }
    }

    private func progressRow(_ item: AppModel.LibraryDownload) -> some View {
        let title = displayTitle(item)
        return DownloadLine { hovered in
            HStack(spacing: Cols.gap) {
                Poster(url: item.coverURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Text("Episode \(item.episode)")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Group {
                    if case .downloading(let percent) = item.state {
                        DownloadBar(fraction: percent / 100, height: 3)
                    } else {
                        Color.clear.frame(height: 3)
                    }
                }
                .frame(width: Cols.bar)
                progressStatus(item.state)
                    .frame(width: Cols.status, alignment: .leading)
                Group {
                    if onRemove != nil, Self.isRemovable(item.state) {
                        wordButton("Remove", tone: SumiTheme.muted) {
                            pending = PendingDelete(
                                title: "Remove episode \(item.episode) of \(title)?",
                                message: "It leaves this list. You can download it again from the episode list.",
                                action: "Remove"
                            ) { onRemove?(item) }
                        }
                    }
                }
                .frame(width: Cols.action, alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func progressStatus(_ state: MediaDetailView.EpisodeDownloadState) -> some View {
        switch state {
        case .notStarted:
            Text("Queued").sumiTabularMono(size: 11.5).foregroundColor(SumiTheme.muted)
        case .downloading(let percent):
            Text("\(Int(percent))%")
                .sumiTabularMono(size: 11.5)
                .foregroundColor(SumiTheme.muted)
                .contentTransition(.numericText())
        case .done:
            Text("Downloaded").sumiTabularMono(size: 11.5).foregroundColor(SumiTheme.muted)
        case .failed(let message):
            Text("Failed").sumiTabularMono(size: 11.5).foregroundColor(SumiTheme.danger)
                .help("Download failed: \(message)")
        }
    }

    // MARK: - On this Mac

    private var onDiskSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            SumiSectionHeader("On this \(Self.deviceName)", trailing: retentionNote)
            VStack(spacing: 0) {
                ForEach(grouped(offline), id: \.0) { title, rows in
                    episodeGroup(title, rows).transition(.opacity)
                }
                ForEach(groupedChapters, id: \.0) { title, rows in
                    chapterGroup(title, rows).transition(.opacity)
                }
            }
        }
    }

    /// What empties this list without anyone pressing Delete, said before
    /// it happens: a list that shrinks by itself needs to have said why.
    private var retentionNote: String? {
        var parts: [String] = []
        if AppModel.deletesWatchedDownloads { parts.append("Watched episodes are deleted once playback moves on") }
        if chapterCapBytes > 0 { parts.append("Chapters held to \(Self.size(chapterCapBytes))") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func episodeGroup(_ title: String, _ rows: [AppModel.LibraryDownload]) -> some View {
        let bytes = rows.reduce(UInt64(0)) { $0 + (Self.donePath($1.state).flatMap { fileBytes[$0] } ?? 0) }
        let isOpen = expanded.contains(title)
        return VStack(spacing: 0) {
            groupLine(
                key: title, title: title, cover: rows.first?.coverURL,
                detail: Self.span(rows.map { Double($0.episode) }, total: rows.count, noun: "episode"),
                bytes: bytes,
                canDelete: onRemove != nil
            ) {
                pending = PendingDelete(
                    title: "Delete \(Self.count(rows.count, "episode")) of \(title)?",
                    message: Self.freesMessage(bytes, plural: rows.count != 1)
                ) { rows.forEach { onRemove?($0) } }
            }
            if isOpen {
                ForEach(rows) { episodeLine($0, title: title) }
            }
        }
    }

    private func episodeLine(_ item: AppModel.LibraryDownload, title: String) -> some View {
        let path = Self.donePath(item.state)
        let bytes = path.flatMap { fileBytes[$0] } ?? 0
        return DownloadLine { hovered in
            HStack(spacing: Cols.gap) {
                Color.clear.frame(width: Cols.poster, height: 1)
                Text("Episode \(item.episode)")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 14) {
                    if let onPlay, path != nil {
                        wordButton("Play", tone: SumiTheme.foreground) { onPlay(item) }
                    }
                    #if os(macOS)
                    if let path {
                        wordButton("Show in Finder", tone: SumiTheme.muted) {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                        }
                    }
                    #endif
                }
                .frame(width: Cols.bar, alignment: .leading)
                Text(Self.size(bytes))
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: Cols.status, alignment: .leading)
                deleteWord(hovered: hovered, enabled: onRemove != nil) {
                    pending = PendingDelete(
                        title: "Delete episode \(item.episode) of \(title)?",
                        message: Self.freesMessage(bytes, plural: false)
                    ) { onRemove?(item) }
                }
            }
        }
    }

    private func chapterGroup(_ title: String, _ rows: [FfiOfflineChapter]) -> some View {
        let key = "chapters:" + title
        let bytes = rows.reduce(UInt64(0)) { $0 + $1.bytes }
        let isNovel = rows.allSatisfy { $0.kind == .novel }
        // A novel row's "number" is the volume's name ("Volume 1"), so it
        // cannot be read as a range.
        let what = isNovel
            ? Self.count(rows.count, "volume")
            : Self.span(rows.compactMap { Double($0.chapterNumber) }, total: rows.count, noun: "chapter")
        let noun = isNovel ? "volume" : "chapter"
        return VStack(spacing: 0) {
            groupLine(
                key: key, title: title, cover: nil,
                detail: what + " · for offline reading",
                bytes: bytes,
                canDelete: onRemoveChapter != nil
            ) {
                pending = PendingDelete(
                    title: "Delete \(Self.count(rows.count, noun)) of \(title)?",
                    message: Self.freesMessage(bytes, plural: rows.count != 1)
                ) { rows.forEach { onRemoveChapter?($0) } }
            }
            if expanded.contains(key) {
                ForEach(rows, id: \.chapterId) { chapterLine($0, title: title) }
            }
        }
    }

    private func chapterLine(_ chapter: FfiOfflineChapter, title: String) -> some View {
        // Built before the view rather than inside the `Text` initialisers.
        // Two interpolations carrying a ternary each put this body past the
        // solver's budget in a release build -- "unable to type-check this
        // expression in reasonable time" -- while the debug build compiled
        // it fine, so it only ever failed at packaging time.
        let isNovel = chapter.kind == .novel
        // A novel row's "number" is the volume's name, so prefixing it with
        // Chapter would read "Chapter Volume 1".
        let heading = isNovel ? chapter.chapterNumber : "Chapter " + chapter.chapterNumber
        let unit = isNovel ? "chapters" : "pages"
        let detail = "\(chapter.pageCount) " + unit
        return DownloadLine { hovered in
            HStack(spacing: Cols.gap) {
                Color.clear.frame(width: Cols.poster, height: 1)
                Text(heading)
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(detail)
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: Cols.bar, alignment: .leading)
                Text(Self.size(chapter.bytes))
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: Cols.status, alignment: .leading)
                deleteWord(hovered: hovered, enabled: onRemoveChapter != nil) {
                    pending = PendingDelete(
                        title: "Delete \(heading.prefix(1).lowercased() + heading.dropFirst()) of \(title)?",
                        message: Self.freesMessage(chapter.bytes, plural: false)
                    ) { onRemoveChapter?(chapter) }
                }
            }
        }
    }

    /// One title on disk. A click opens its single files: Play and Show in
    /// Finder live there, where they name one episode rather than a show.
    private func groupLine(
        key: String, title: String, cover: URL?, detail: String, bytes: UInt64,
        canDelete: Bool, onDelete: @escaping () -> Void
    ) -> some View {
        DownloadLine(onTap: {
            if expanded.contains(key) { expanded.remove(key) } else { expanded.insert(key) }
        }) { hovered in
            HStack(spacing: Cols.gap) {
                Poster(url: cover)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Text(detail)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Color.clear.frame(width: Cols.bar, height: 1)
                Text(Self.size(bytes))
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: Cols.status, alignment: .leading)
                deleteWord(hovered: hovered, enabled: canDelete, action: onDelete)
            }
        }
        .accessibilityHint(expanded.contains(key) ? "Hides the single files" : "Shows the single files")
    }

    // MARK: - Parts

    /// Delete in the danger colour under the pointer, muted otherwise: thirty
    /// red words down a column read as an alarm. Always red on the phone,
    /// which has no pointer.
    @ViewBuilder
    private func deleteWord(hovered: Bool, enabled: Bool, action: @escaping () -> Void) -> some View {
        Group {
            if enabled {
                wordButton("Delete", tone: hovered ? SumiTheme.danger : SumiTheme.muted, action: action)
            }
        }
        .frame(width: Cols.action, alignment: .trailing)
    }

    private func wordButton(_ label: String, tone: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(tone)
                .frame(minHeight: Cols.hit)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #elseif os(tvOS)
        "Apple TV"
        #else
        "iPhone"
        #endif
    }

    /// "18.4 GB used · 312 GB free on this Mac". Used is what this page
    /// lists, not the whole disk: the question the page answers is what
    /// Anicat is holding.
    private var summary: String {
        let used = usedBytes
        let head = used == 0 ? "Nothing downloaded yet" : "\(Self.size(used)) used"
        guard let freeBytes else { return head }
        return "\(head) · \(Self.size(freeBytes)) free on this \(Self.deviceName)"
    }

    private static func freesMessage(_ bytes: UInt64, plural: Bool) -> String {
        let again = plural ? "them" : "it"
        let frees = bytes > 0 ? "Frees \(size(bytes)). " : ""
        return frees + "Your progress and list entry stay; you can download \(again) again."
    }

    /// "Episodes 1 to 4" for an unbroken run, "Episode 3" for one, a count
    /// otherwise: "Episodes 1 to 6" over 1, 2 and 6 would claim files that
    /// are not there. `total` counts rows whose number did not parse
    /// ("10.5a"), which can only be counted.
    static func span(_ numbers: [Double], total: Int, noun: String) -> String {
        let sorted = numbers.sorted()
        let name = noun.capitalizedFirst
        func label(_ n: Double) -> String { n.rounded() == n ? String(Int(n)) : String(n) }
        guard sorted.count == total, let first = sorted.first, let last = sorted.last else {
            return count(total, noun)
        }
        if total == 1 { return "\(name) \(label(first))" }
        let unbroken = sorted.allSatisfy { $0.rounded() == $0 }
            && Set(sorted).count == total && Int(last - first) + 1 == total
        return unbroken ? "\(name)s \(label(first)) to \(label(last))" : count(total, noun)
    }

    /// "1 episode", "2 episodes".
    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
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

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The page's column widths, shared by every row so sizes and Delete line up
/// down the list as the mockup's grid has them. The phone's 370pt column
/// could not hold a 220pt bar beside a title.
private enum Cols {
    static let poster: CGFloat = 40
    #if os(iOS)
    static let gap: CGFloat = 10
    static let bar: CGFloat = 64
    static let status: CGFloat = 56
    static let action: CGFloat = 52
    /// A thumb target: 24pt words were hit by the row beside them.
    static let hit: CGFloat = 44
    #else
    static let gap: CGFloat = 14
    static let bar: CGFloat = 220
    static let status: CGFloat = 110
    static let action: CGFloat = 80
    static let hit: CGFloat = 24
    #endif
}

/// A confirmation waiting on the sheet.
private struct PendingDelete: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    var action: String = "Delete"
    let perform: () -> Void
}

/// The delete confirmation, drawn in Sumi over the page. The stock
/// `confirmationDialog` it replaces was system chrome in the middle of an
/// app that draws everything else itself.
private struct DeleteSheet: View {
    let pending: PendingDelete
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 14) {
                Text(pending.title)
                    .font(.sumiHeading(size: 15, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                Text(pending.message)
                    .font(.system(size: 12.5))
                    .lineSpacing(3)
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    Button("Cancel", action: dismiss)
                        .sumiSecondaryButton()
                        #if !os(tvOS)
                        .keyboardShortcut(.cancelAction)
                        #endif
                    Button(pending.action, role: .destructive) {
                        pending.perform()
                        dismiss()
                    }
                    .sumiSecondaryButton()
                }
            }
            .padding(22)
            .frame(maxWidth: 380, alignment: .leading)
            .background(SumiTheme.card, in: SumiRect(cornerRadius: SumiTheme.radiusXl))
            .overlay(SumiRect(cornerRadius: SumiTheme.radiusXl).stroke(SumiTheme.border, lineWidth: 1))
            .padding(24)
        }
    }
}

private struct Poster: View {
    let url: URL?

    var body: some View {
        let shape = SumiRect(cornerRadius: SumiTheme.radiusSm)
        CachedAsyncImage(url: url, maxPixelSize: 120) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            SumiTheme.foregroundWash
        }
        .frame(width: Cols.poster, height: 60)
        .clipShape(shape)
        .overlay(shape.stroke(SumiTheme.border, lineWidth: 1))
    }
}

/// A thin progress line: the storage bar under the header, and a download's
/// progress. The stock linear `ProgressView` drew the platform's own bar,
/// in the system accent, in a page drawn in Sumi.
private struct DownloadBar: View {
    let fraction: Double
    let height: CGFloat

    var body: some View {
        let shape = SumiRect(cornerRadius: height / 2)
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                shape.fill(SumiTheme.foregroundWash)
                shape.fill(SumiTheme.indigo)
                    .frame(width: geo.size.width * min(max(fraction, 0), 1))
            }
        }
        .frame(height: height)
        // `downloadStates` is a 1s poll, so without this the bar jumped a
        // second's worth of width at a time.
        .animation(.linear(duration: 1), value: fraction)
    }
}

/// A row on the page ground with a hairline under it, washed under the
/// pointer. Boxed rows with an icon column on each read as a generic
/// actions table, thirty times over. The phone reports itself always
/// hovered so Delete keeps its colour there.
private struct DownloadLine<Content: View>: View {
    var onTap: (() -> Void)?
    @ViewBuilder let content: (Bool) -> Content
    @State private var isHovered = false

    var body: some View {
        #if os(macOS)
        let hovered = isHovered
        #else
        let hovered = true
        #endif
        let row = content(hovered)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SumiTheme.border).frame(height: 1)
            }
            .padding(.horizontal, 12)
            .background(
                isHovered ? SumiTheme.foreground.opacity(0.04) : Color.clear,
                in: SumiRect(cornerRadius: 8)
            )
            .padding(.horizontal, -12)
            .contentShape(Rectangle())
            .stableHover { isHovered = $0 }
        if let onTap {
            row.onTapGesture(perform: onTap)
        } else {
            row
        }
    }
}
