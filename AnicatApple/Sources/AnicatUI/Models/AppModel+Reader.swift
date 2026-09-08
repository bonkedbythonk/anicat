// AppModel, reader domain: the manga reader (chapters, pages, next and
// previous) and the Syosetu web-novel reader.

import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

extension AppModel {
    /// Loads volumes for a detail page, whichever way that page arrived.
    ///
    /// `loadDetail` returns early when the cached snapshot is still fresh,
    /// which skipped the fetch path entirely -- a novel opened once and
    /// reopened showed "nothing readable" without ever having looked.
    func refreshNovelVolumes(for details: HeroBanner.Details) async {
        guard details.format == "NOVEL" else {
            novelVolumes = []
            novelSourceMissing = false
            novelVolumesTitle = nil
            return
        }
        guard novelVolumesTitle != details.title else { return }
        novelVolumesTitle = details.title
        await loadLightNovelVolumes(title: details.title, romajiTitle: details.romajiTitle)
    }

    /// Finds a readable source for the open light novel and lists its
    /// volumes. Called when a NOVEL detail page opens.
    ///
    /// Both titles are offered because the index is slugged from English
    /// ones: a romaji-only match is the weaker of the two and should not win
    /// where an English title exists.
    public func loadLightNovelVolumes(title: String, romajiTitle: String?) async {
        guard let engine else { return }
        novelVolumes = []
        novelSourceMissing = false
        isLoadingNovelVolumes = true
        defer { isLoadingNovelVolumes = false }

        var titles = [title]
        if let romajiTitle, !romajiTitle.isEmpty, romajiTitle != title { titles.append(romajiTitle) }

        guard let series = try? await engine.lightNovelSource(titles: titles) else {
            // Nothing matched. An ordinary answer, not a failure: most of
            // AniList's light novels have no English translation indexed.
            novelSourceMissing = true
            return
        }
        let volumes = (try? await engine.lightNovelVolumes(seriesUrl: series)) ?? []
        novelVolumes = volumes
        novelSourceMissing = volumes.isEmpty
    }

    /// Opens one volume in the novel reader. The volume is a single page, so
    /// its table of contents becomes the reader's chapter list.
    public func openLightNovelVolume(bookURL: String, title: String) {
        novelReaderOpen = true
        syosetuSession = SyosetuSession(source: .lnori, sourceURL: bookURL)
        Task { await loadLightNovelVolume(bookURL: bookURL, title: title) }
    }

    func loadLightNovelVolume(bookURL: String, title: String) async {
        guard let engine else { return }
        syosetuSession?.isLoading = true
        syosetuSession?.errorMessage = nil
        // The stored table of contents first. Reading a chapter offline is no
        // use if listing the volume's chapters still needs the network -- the
        // chapter list is fetched before any chapter is, so a downloaded book
        // would have failed here and never reached the stored text.
        if let anilistId = selectedMediaDetails?.id {
            let stored = engine.offlineLightNovelVolume(
                catalog: .anilist,
                catalogId: anilistId,
                bookUrl: bookURL
            )
            if !stored.isEmpty {
                syosetuSession?.info = NovelInfo(
                    title: title,
                    author: "",
                    description: "",
                    chapters: stored
                )
                syosetuSession?.isLoading = false
                if let first = stored.first {
                    await loadSyosetuChapter(url: first.url, index: 0)
                }
                return
            }
        }
        do {
            let chapters = try await engine.lightNovelChapters(bookUrl: bookURL)
            guard syosetuSession?.sourceURL == bookURL else { return }
            syosetuSession?.info = NovelInfo(
                title: title,
                author: "",
                description: "",
                chapters: chapters
            )
            syosetuSession?.isLoading = false
            if let first = chapters.first {
                await loadSyosetuChapter(url: first.url, index: 0)
            }
        } catch {
            guard syosetuSession?.sourceURL == bookURL else { return }
            syosetuSession?.isLoading = false
            syosetuSession?.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Keeping a volume

    /// What the volume rows on a detail page show. Derived from the registry
    /// rather than kept alongside it, so a download made on another page is
    /// already reflected when this one opens.
    public var novelVolumeStates: [String: MediaDetailView.ChapterOfflineState] {
        var states = novelVolumeWork
        for row in offlineChapters where row.kind == .novel {
            if states[row.chapterId] == nil { states[row.chapterId] = .stored }
        }
        return states
    }

    /// Fetches a whole volume and keeps it.
    public func downloadNovelVolume(_ volume: NovelChapterRef) {
        guard let engine, let anilistId = selectedMediaDetails?.id else { return }
        // AniList fills this from the staff credit for a novel; empty is
        // fine, the engine writes "Unknown" rather than an empty creator.
        let author = selectedMediaDetails?.studio ?? ""
        novelVolumeWork[volume.url] = .downloading
        Task { @MainActor in
            do {
                _ = try await engine.downloadLightNovelVolume(
                    catalog: .anilist,
                    catalogId: anilistId,
                    bookUrl: volume.url,
                    seriesTitle: selectedMediaDetails?.title ?? "",
                    volumeTitle: volume.title,
                    author: author
                )
                novelVolumeWork[volume.url] = nil
                loadOfflineChapters()
            } catch {
                novelVolumeWork[volume.url] = .failed
                errorMessage = "Could not download \(volume.title): \(error.localizedDescription)"
            }
        }
    }

    public func deleteNovelVolumeDownload(_ volume: NovelChapterRef) {
        guard let engine, let anilistId = selectedMediaDetails?.id else { return }
        try? engine.removeLightNovelDownload(
            catalog: .anilist,
            catalogId: anilistId,
            bookUrl: volume.url
        )
        novelVolumeWork[volume.url] = nil
        loadOfflineChapters()
    }

    /// Writes the volume out as an EPUB and reveals it.
    ///
    /// Revealed rather than reported: the file's whole purpose is to be
    /// dragged onto a device, and a path in a message is something the user
    /// then has to go and find.
    public func exportNovelVolume(_ volume: NovelChapterRef) {
        guard let engine, let anilistId = selectedMediaDetails?.id else { return }
        // AniList fills this from the staff credit for a novel; empty is
        // fine, the engine writes "Unknown" rather than an empty creator.
        let author = selectedMediaDetails?.studio ?? ""
        novelVolumeWork[volume.url] = .exporting
        Task { @MainActor in
            do {
                let path = try await engine.exportLightNovelEpub(
                    catalog: .anilist,
                    catalogId: anilistId,
                    bookUrl: volume.url,
                    seriesTitle: selectedMediaDetails?.title ?? "",
                    volumeTitle: volume.title,
                    author: author
                )
                novelVolumeWork[volume.url] = nil
                loadOfflineChapters()
                revealInFinder(path)
            } catch {
                novelVolumeWork[volume.url] = .failed
                errorMessage = "Could not export \(volume.title): \(error.localizedDescription)"
            }
        }
    }

    private func revealInFinder(_ path: String) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        #endif
    }

    /// Opens the reader with no source yet, for the "Open a Syosetu URL"
    /// entry point.
    public func openNovelReaderEntry() {
        novelReaderOpen = true
    }

    public func openSyosetuReader(url: String) {
        novelReaderOpen = true
        syosetuSession = SyosetuSession(sourceURL: url)
        Task { await loadSyosetuInfo(url: url) }
    }

    public func closeSyosetuReader() {
        syosetuSession = nil
        novelReaderOpen = false
    }

    func loadSyosetuInfo(url: String) async {
        guard let engine else { return }
        syosetuSession?.isLoading = true
        syosetuSession?.errorMessage = nil
        do {
            let info = try await engine.novelInfo(url: url)
            guard syosetuSession?.sourceURL == url else { return }
            syosetuSession?.info = info
            syosetuSession?.isLoading = false
            // Resume where this novel was left off rather than at chapter one:
            // the stored chapter is what the Novels page offers to continue,
            // and opening the same link had to mean the same thing as tapping
            // that offer or the two would disagree.
            let resume = NovelPreferences.lastNovel().flatMap { last -> Int? in
                guard NovelPreferences.ncode(from: last.url) == NovelPreferences.ncode(from: url) else { return nil }
                return info.chapters.indices.contains(last.chapter) ? last.chapter : nil
            }
            let start = resume ?? 0
            if info.chapters.indices.contains(start) {
                await loadSyosetuChapter(url: info.chapters[start].url, index: start)
            }
        } catch {
            guard syosetuSession?.sourceURL == url else { return }
            syosetuSession?.isLoading = false
            syosetuSession?.errorMessage = error.localizedDescription
        }
    }

    public func loadSyosetuChapter(url: String, index: Int) async {
        guard let engine, let session = syosetuSession else { return }
        let sourceURL = session.sourceURL
        syosetuSession?.isLoading = true
        syosetuSession?.errorMessage = nil
        do {
            // An lnori chapter is an anchor into one big volume page, so the
            // fragment carries the section and the rest is the book.
            let chapter: NovelChapterContent
            if session.source == .lnori {
                let parts = url.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
                let bookURL = String(parts[0])
                // The downloaded copy first, and without announcing itself:
                // the point of downloading a volume is that reading it later
                // is the same act, on a train with no signal included.
                if let anilistId = selectedMediaDetails?.id,
                   let stored = engine.offlineLightNovelChapter(
                       catalog: .anilist,
                       catalogId: anilistId,
                       bookUrl: bookURL,
                       chapterUrl: url
                   ) {
                    chapter = stored
                } else {
                    chapter = try await engine.lightNovelChapter(
                        bookUrl: bookURL,
                        anchor: parts.count > 1 ? String(parts[1]) : ""
                    )
                }
            } else {
                chapter = try await engine.novelChapter(url: url)
            }
            guard syosetuSession?.sourceURL == sourceURL else { return }
            syosetuSession?.currentChapterIndex = index
            syosetuSession?.chapterTitle = chapter.title
            syosetuSession?.chapterText = chapter.text
            syosetuSession?.isLoading = false
            NovelPreferences.setLastNovel(
                url: sourceURL,
                title: syosetuSession?.info?.title ?? chapter.title,
                chapter: index
            )
        } catch {
            guard syosetuSession?.sourceURL == sourceURL else { return }
            syosetuSession?.isLoading = false
            syosetuSession?.errorMessage = error.localizedDescription
        }
    }

    public func closeReader() {
        // The pin goes with the reader: nothing is being read now, so
        // eviction may consider every chapter again.
        if let anilistId = activeReadingSession?.anilistId {
            engine?.setReadingChapter(catalog: .anilist, catalogId: anilistId, chapterId: nil)
        }
        activeReadingSession = nil
        // Hopped rather than called inline: this is reached from
        // `handleEscapeKey`, which is synchronous and not main-actor isolated,
        // and the bridge's task handles are only safe to touch there.
        Task { @MainActor in ReaderBridge.shared.close() }
        ContinuityManager.shared.stopAdvertising()
    }

    public func nextChapter() async {
        guard let session = activeReadingSession else { return }
        let nextIndex = session.chapterIndex + 1
        if nextIndex < session.chapters.count {
            let nextChapter = session.chapters[nextIndex]
            await openReader(
                title: session.title,
                chapter: nextChapter,
                allChapters: session.chapters,
                anilistId: session.anilistId
            )
        }
    }

    public func prevChapter() async {
        guard let session = activeReadingSession else { return }
        let prevIndex = session.chapterIndex - 1
        if prevIndex >= 0 {
            let prevChapter = session.chapters[prevIndex]
            await openReader(
                title: session.title,
                chapter: prevChapter,
                allChapters: session.chapters,
                anilistId: session.anilistId
            )
        }
    }

    /// Opens the manga reader for a selected chapter, fetching real page images via engine.mangaPages.
    public func openReader(
        title: String,
        chapter: MediaDetailView.MangaChapterItem,
        allChapters: [MediaDetailView.MangaChapterItem] = [],
        anilistId: Int64? = nil
    ) async {
        guard let engine else { return }
        let index = allChapters.firstIndex(where: { $0.id == chapter.id }) ?? 0
        do {
            let urls: [URL]
            // Downloaded pages first, and without asking the network at all:
            // that is what "offline" has to mean, and a stored chapter opens
            // at disk speed rather than at the provider's.
            let stored = anilistId.map {
                engine.offlineChapterPages(catalog: .anilist, catalogId: $0, chapterId: chapter.id)
            } ?? []
            // A chapter the reader preloaded past 70% of the last one is
            // already here. Going back to the network for a list we hold would
            // put a spinner in front of the very turn the preload exists to
            // make instant.
            if !stored.isEmpty {
                urls = stored.compactMap { URL(string: $0) }
            } else if let preloaded = await MainActor.run(body: { ReaderBridge.shared.takePreloadedPages(chapterId: chapter.id) }) {
                urls = preloaded
            } else {
                isLoading = true
                defer { isLoading = false }
                let pages = try await engine.mangaPages(chapterId: chapter.id)
                urls = pages.compactMap { URL(string: $0) }
            }
            let displayTitle = chapter.title.isEmpty ? "Chapter \(chapter.number)" : "CH \(chapter.number): \(chapter.title)"
            // Strictly before `activeReadingSession` is assigned: that
            // assignment is what makes RootView build `MangaReaderView`, and
            // the view's `init` reads the bridge for the catalog id its
            // per-title preferences are keyed on. Await it here and the
            // ordering holds however the two actors interleave.
            await MainActor.run {
                ReaderBridge.shared.begin(
                    model: self,
                    catalogId: anilistId,
                    chapters: allChapters,
                    chapterIndex: index,
                    chapterNumber: chapter.number
                )
            }
            // Where this chapter was left. A chapter finished to its last
            // page opens at the start again rather than on the final page,
            // which is a reread, not a resume.
            var startPage = 0
            if let anilistId,
               let progress = try? engine.readingProgress(
                   catalog: .anilist, catalogId: anilistId, chapterId: chapter.id
               ),
               progress.page > 0,
               progress.page < Int64(urls.count) - 1 {
                startPage = Int(progress.page)
            }
            if let anilistId {
                // Pinned for as long as it is open: a download that lands
                // mid-chapter must not evict the pages being read.
                engine.setReadingChapter(
                    catalog: .anilist, catalogId: anilistId, chapterId: chapter.id
                )
            }
            self.activeReadingSession = MangaReadingSession(
                title: title,
                chapterTitle: displayTitle,
                chapterId: chapter.id,
                pageURLs: urls,
                chapterIndex: index,
                chapters: allChapters,
                anilistId: anilistId,
                startPage: startPage
            )
            ContinuityManager.shared.advertiseReading(
                mangaId: chapter.id,
                anilistId: anilistId,
                title: title,
                chapter: chapter.number,
                pageIndex: startPage
            )
        } catch {
            errorMessage = "Could not load chapter pages: \(error.localizedDescription)"
            print("Manga pages load failed: \(error)")
        }
    }

    /// Picks up a chapter handed off from another device: the title's page,
    /// then the chapter, at the page it was left on there.
    ///
    /// The detail page is opened first because that is where the chapter
    /// list comes from -- the activity carries a chapter id and a number,
    /// and the reader needs the chapter itself and its neighbours to offer
    /// next and previous.
    public func openReadingHandoff(anilistId: Int64, chapterId: String, page: Int) async {
        await openDetail(id: anilistId, isManga: true)
        guard let chapter = selectedMangaChapters.first(where: { $0.id == chapterId }) else { return }
        // Written before the reader opens, so the resume the reader already
        // does picks it up. The other device's page wins: it is where the
        // reading actually got to.
        if page > 0, let engine {
            try? engine.recordReadingProgress(
                catalog: .anilist,
                catalogId: anilistId,
                chapterId: chapterId,
                chapterNumber: chapter.number,
                page: Int64(page),
                pageCount: 0
            )
        }
        await openReader(
            title: selectedMediaDetails?.title ?? "",
            chapter: chapter,
            allChapters: selectedMangaChapters,
            anilistId: anilistId
        )
    }

    /// Downloads a chapter for reading with no network.
    ///
    /// The pages are fetched and written by the engine; this only tracks the
    /// row's state, because the button has to say something while it runs.
    public func downloadChapter(_ chapter: MediaDetailView.MangaChapterItem) {
        guard let engine, let details = selectedMediaDetails else { return }
        guard chapterOfflineStates[chapter.id] != .downloading else { return }
        chapterOfflineStates[chapter.id] = .downloading
        let catalogId = details.id
        let title = details.title
        Task { [weak self] in
            do {
                _ = try await engine.downloadChapter(
                    catalog: .anilist,
                    catalogId: catalogId,
                    chapterId: chapter.id,
                    chapterNumber: chapter.number,
                    title: title
                )
                guard let self else { return }
                self.chapterOfflineStates[chapter.id] = .stored
                self.loadOfflineChapters()
            } catch {
                guard let self else { return }
                self.chapterOfflineStates[chapter.id] = .failed
                self.errorMessage = "Could not download chapter \(chapter.number): \(error.localizedDescription)"
            }
        }
    }

    public func deleteChapterDownload(_ chapter: MediaDetailView.MangaChapterItem) {
        guard let engine, let details = selectedMediaDetails else { return }
        try? engine.deleteOfflineChapter(
            catalog: .anilist, catalogId: details.id, chapterId: chapter.id
        )
        chapterOfflineStates[chapter.id] = MediaDetailView.ChapterOfflineState.none
        loadOfflineChapters()
    }

    /// Removes one downloaded chapter from the Downloads page, where there
    /// is no open title to read the id from.
    public func deleteOfflineChapter(_ row: FfiOfflineChapter) {
        guard let engine else { return }
        try? engine.deleteOfflineChapter(
            catalog: row.catalog, catalogId: row.catalogId, chapterId: row.chapterId
        )
        chapterOfflineStates[row.chapterId] = MediaDetailView.ChapterOfflineState.none
        loadOfflineChapters()
    }

    /// What the newest chapter of each followed manga was, last time this
    /// looked. `anicat_last_seen_chapter` in UserDefaults, keyed by AniList
    /// id.
    static let lastSeenChapterKey = "anicat_last_seen_chapter"

    /// Announces manga whose source has published a chapter since the last
    /// check.
    ///
    /// Not driven off the Up Next queue like the episode check: that queue is
    /// built from AniList's *watching* list and only ever holds anime, which
    /// is why including chapters there announced nothing. AniList also has no
    /// "next chapter" field to read -- `chapters` is the published total and
    /// is null for most ongoing series -- so the answer has to come from the
    /// same source the reader reads: whatever MangaDex or MangaKatana lists
    /// as the newest chapter.
    ///
    /// One pass over what is actually being read, capped, in the background.
    @MainActor
    public func checkForNewChapters() async {
        guard let engine, SystemNotifications.areNewEpisodeNotificationsEnabled else { return }
        var seen = (UserDefaults.standard.dictionary(forKey: Self.lastSeenChapterKey) as? [String: Double]) ?? [:]

        for item in mangaReading.prefix(8) {
            guard let manga = try? await engine.searchManga(query: item.title, anilistId: item.id),
                  let first = manga.first else { continue }
            let chapters = (try? await engine.getMangaChapters(mangaId: first.id)) ?? []
            // Chapters number fractionally and arrive in feed order, so the
            // newest is the largest number rather than the last row.
            guard let newest = chapters.compactMap({ Double($0.number) }).max() else { continue }

            let key = String(item.id)
            defer { seen[key] = newest }
            // The first look at a title only records: everything already
            // published counts as new against an empty history, and
            // announcing a back catalogue is a notification storm.
            guard let previous = seen[key], newest > previous else { continue }

            let id = item.id
            let title = item.title
            let cover = item.coverImageURL
            let chapter = Int(newest.rounded(.down))
            Task.detached(priority: .utility) {
                await SystemNotifications.shared.notifyNewEpisode(
                    catalogId: id,
                    title: title,
                    episode: chapter,
                    coverURL: cover,
                    unit: .chapter
                )
            }
        }
        UserDefaults.standard.set(seen, forKey: Self.lastSeenChapterKey)
    }

    /// Tells the engine the cap Settings holds. Called at launch and
    /// whenever the control changes: the engine keeps it in memory, so it is
    /// this side's job to say what it is.
    public func applyOfflineLimit() {
        guard let engine else { return }
        let stored = UserDefaults.standard.object(forKey: Self.offlineCapDefaultsKey) as? Int
        // Two gigabytes unless someone has chosen otherwise -- the engine's
        // own default, repeated here so the Settings control has something
        // to show before it is ever touched.
        let gigabytes = stored ?? 2
        engine.setOfflineLimitBytes(bytes: UInt64(max(0, gigabytes)) * 1024 * 1024 * 1024)
    }

    /// What is on disk, for the Downloads page and for the chapter rows of
    /// the open title.
    public func loadOfflineChapters() {
        guard let engine else { return }
        offlineChapters = (try? engine.offlineChapters()) ?? []
        offlineBytes = engine.offlineSizeBytes()
        offlineCapBytes = engine.offlineLimitBytes()
        guard let details = selectedMediaDetails else { return }
        var states = chapterOfflineStates
        for row in offlineChapters where row.catalogId == details.id {
            // A download in flight keeps its own state: the row is written
            // when it finishes, so anything mid-flight is not in this list
            // yet and must not be reset to "not downloaded".
            if states[row.chapterId] != .downloading { states[row.chapterId] = .stored }
        }
        chapterOfflineStates = states
    }

    /// Records the page a chapter is on, so reopening it resumes there.
    ///
    /// Local only, like an episode's stop position: AniList tracks whole
    /// chapters and knows nothing about a page inside one.
    public func recordReadingPage(chapterId: String, page: Int, pageCount: Int) {
        guard let engine, let session = activeReadingSession,
              let anilistId = session.anilistId else { return }
        let number = session.chapters.first { $0.id == chapterId }?.number ?? ""
        try? engine.recordReadingProgress(
            catalog: .anilist,
            catalogId: anilistId,
            chapterId: chapterId,
            chapterNumber: number,
            page: Int64(page),
            pageCount: Int64(pageCount)
        )
    }

    /// What finishing a chapter did to the AniList entry.
    public enum MangaProgressSync: Sendable, Equatable {
        /// The mutation went out and the entry moved forward.
        case sent
        /// The list was already at or past this chapter — nothing to do, and
        /// nothing to tell the reader about either.
        case alreadyAhead
        case failed
    }

    /// Moves the signed-in user's AniList entry to a finished chapter.
    ///
    /// Deliberately not routed through `updateListEntry`, which opens with
    /// `guard let details = selectedMediaDetails`: a chapter opened from the
    /// Reading shelf has no detail page behind it, so every such read would
    /// have silently skipped the mutation. This is the same shape as
    /// `advanceAniListProgress` on the anime side — fetch the entry, compare,
    /// mutate — with the chapter total feeding the COMPLETED clamp.
    ///
    /// The live progress is read rather than assumed: re-sending a chapter the
    /// list has already passed would drag the entry backwards on a reread.
    func advanceMangaProgress(catalogId: Int64, chapter: Int) async -> MangaProgressSync {
        guard let engine else { return .failed }
        do {
            let detail = try await engine.mediaDetail(catalogId: catalogId, isManga: true)
            guard Int(detail.listProgress ?? 0) < chapter else { return .alreadyAhead }
            let (progress, status) = Self.listEntryUpdate(
                episode: chapter,
                watched: true,
                episodeCount: detail.chapterCount.map(Int.init),
                listStatus: detail.listStatus
            )
            try await engine.updateListEntry(
                catalogId: catalogId,
                status: status,
                score: nil,
                progress: Int64(progress)
            )
            await recordAniListSuccess()
            refreshListsAfterEdit()
            return .sent
        } catch {
            await recordAniListFailure(error)
            return .failed
        }
    }
}

// MARK: - Reader bridge

/// The manga reader's link back to the model.
///
/// `MangaReaderView` is built from plain values — a title, a chapter name and
/// a list of page URLs — and nothing in the app puts `AppModel` into the
/// SwiftUI environment, so the view has no route to the engine for the two
/// things it needs that are not drawing: warming the next chapter before the
/// reader asks for it, and moving the AniList entry when one is finished.
/// Holding that in one object rather than threading four more closures
/// through the construction site also keeps reader policy (when to preload,
/// when a chapter counts as read) out of the view layer.
///
/// Pointed at the open session by `AppModel.openReader`, and emptied by
/// `closeReader`. The model reference is weak because this outlives every
/// session by design and a strong one would pin the whole app graph.
@MainActor
public final class ReaderBridge {
    public static let shared = ReaderBridge()

    /// How far into a chapter the next one starts loading. Early enough that
    /// a page list and three images have landed before the last page, late
    /// enough that a reader who opens a chapter and backs out immediately
    /// costs nothing.
    public static let preloadThreshold: Double = 0.70
    /// Only the first spread's worth plus one. Warming a whole chapter at the
    /// reader's own fit competes for the decode cache with the chapter being
    /// read, where a single page runs to ~19 MB.
    static let preloadedPageCount = 3

    private weak var model: AppModel?
    private(set) var catalogId: Int64?
    private var chapters: [MediaDetailView.MangaChapterItem] = []
    private var chapterIndex = 0
    private var chapterNumber = ""

    /// The fit the reader is decoding at, kept in step by its prefetch
    /// window. `ImageDecodeCache` is keyed on the fit, so a preload at any
    /// other one warms images the reader will never ask for and the spinner
    /// comes back regardless.
    var pageFit: ImageFit = .box(width: 1600, height: nil)

    private var preloadTask: Task<Void, Never>?
    private var prefetchTask: Task<Void, Never>?
    /// Keyed by chapter id rather than held as a single "next": the Next
    /// Chapter button can be pressed before the 70% threshold is ever
    /// crossed, and a preload for a chapter the reader then skipped past must
    /// not be handed out as if it were the one being opened.
    private var preloadedPages: [String: [URL]] = [:]

    private init() {}

    func begin(
        model: AppModel,
        catalogId: Int64?,
        chapters: [MediaDetailView.MangaChapterItem],
        chapterIndex: Int,
        chapterNumber: String
    ) {
        self.model = model
        self.catalogId = catalogId
        self.chapters = chapters
        self.chapterIndex = chapterIndex
        self.chapterNumber = chapterNumber
        preloadTask?.cancel()
        preloadTask = nil
    }

    func close() {
        preloadTask?.cancel()
        preloadTask = nil
        prefetchTask?.cancel()
        prefetchTask = nil
        preloadedPages.removeAll()
        model = nil
        catalogId = nil
        chapters = []
        chapterNumber = ""
    }

    func takePreloadedPages(chapterId: String) -> [URL]? {
        preloadedPages.removeValue(forKey: chapterId)
    }

    /// Fetches the next chapter's page list and warms its opening pages.
    /// Idempotent: the reader calls it once per chapter, but a mode switch or
    /// a scroll back and forward past the threshold must not start a second
    /// fetch of the same list.
    func preloadNextChapter() {
        guard preloadTask == nil, let model else { return }
        let next = chapterIndex + 1
        guard chapters.indices.contains(next) else { return }
        let chapter = chapters[next]
        guard preloadedPages[chapter.id] == nil else { return }
        let fit = pageFit
        preloadTask = Task { [weak self] in
            guard let engine = model.engine,
                  let pages = try? await engine.mangaPages(chapterId: chapter.id) else { return }
            guard !Task.isCancelled, let self else { return }
            let urls = pages.compactMap { URL(string: $0) }
            self.preloadedPages[chapter.id] = urls
            self.prefetchTask = ImageDecodeCache.shared.prefetch(
                Array(urls.prefix(Self.preloadedPageCount)),
                fit: fit
            )
        }
    }

    /// Records the open chapter against the AniList entry, once.
    ///
    /// Returns true only when a mutation actually went out, so the reader's
    /// toast says "synced" for a sync and stays silent for a reread of
    /// something the list has already passed.
    func finishChapter() async -> Bool {
        guard let model, model.isSignedIn,
              let catalogId,
              let chapter = ReaderPreferences.chapterProgress(from: chapterNumber) else { return false }
        guard ReaderPreferences.syncedChapter(catalogId: catalogId) < chapter else { return false }
        let result = await model.advanceMangaProgress(catalogId: catalogId, chapter: chapter)
        switch result {
        case .sent, .alreadyAhead:
            // Marked local on "already ahead" too. Without it a reread would
            // pay for the entry fetch again on every turn to the last page,
            // to reach the same answer.
            ReaderPreferences.setSyncedChapter(chapter, catalogId: catalogId)
        case .failed:
            break
        }
        return result == .sent
    }
}
