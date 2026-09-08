// AppModel, reader domain: the manga reader (chapters, pages, next and
// previous) and the Syosetu web-novel reader.

import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

extension AppModel {
    public func openSyosetuReader(url: String) {
        syosetuSession = SyosetuSession(sourceURL: url)
        Task { await loadSyosetuInfo(url: url) }
    }

    public func closeSyosetuReader() {
        syosetuSession = nil
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
            let chapter = try await engine.novelChapter(url: url)
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
            // A chapter the reader preloaded past 70% of the last one is
            // already here. Going back to the network for a list we hold would
            // put a spinner in front of the very turn the preload exists to
            // make instant.
            if let preloaded = await MainActor.run(body: { ReaderBridge.shared.takePreloadedPages(chapterId: chapter.id) }) {
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
