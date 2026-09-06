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
            if let first = info.chapters.first {
                await loadSyosetuChapter(url: first.url, index: 0)
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
        } catch {
            guard syosetuSession?.sourceURL == sourceURL else { return }
            syosetuSession?.isLoading = false
            syosetuSession?.errorMessage = error.localizedDescription
        }
    }

    public func closeReader() {
        activeReadingSession = nil
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
        isLoading = true
        defer { isLoading = false }
        do {
            let pages = try await engine.mangaPages(chapterId: chapter.id)
            let urls = pages.compactMap { URL(string: $0) }
            let index = allChapters.firstIndex(where: { $0.id == chapter.id }) ?? 0
            let displayTitle = chapter.title.isEmpty ? "Chapter \(chapter.number)" : "CH \(chapter.number): \(chapter.title)"
            self.activeReadingSession = MangaReadingSession(
                title: title,
                chapterTitle: displayTitle,
                chapterId: chapter.id,
                pageURLs: urls,
                chapterIndex: index,
                chapters: allChapters,
                anilistId: anilistId
            )
            ContinuityManager.shared.advertiseReading(
                mangaId: chapter.id,
                anilistId: anilistId,
                title: title,
                chapter: chapter.number,
                pageIndex: 0
            )
        } catch {
            errorMessage = "Could not load chapter pages: \(error.localizedDescription)"
            print("Manga pages load failed: \(error)")
        }
    }
}
