import Foundation

// uniffi generates SearchFilters as a plain struct with no Sendable
// conformance. It only ever holds String?/Int32? fields, so @unchecked is
// safe — without this a caller passing filters into a `Task { }` closure
// fails Swift 6's strict-concurrency check at the call site instead of here.
extension SearchFilters: @unchecked Sendable {}

// uniffi generates AnicatEngine as a plain class with no Sendable
// conformance, so the strict-concurrency checker refuses to send it into
// `async let` children — every AniList fetch on the home/library/detail
// load paths was forced sequential by this alone. The Rust side is safe for
// concurrent calls: the registry's SQLite connection is Mutex-guarded
// (core/src/db/service.rs), reqwest::Client pools its own connections, and
// TorrentManager synchronizes its own state internally.
extension AnicatEngine: @unchecked Sendable {}

extension AnicatEngine {
    /// Fetches chapters for an AniList manga ID by resolving its MangaDex mapping.
    public func mangaChapters(alId: Int64) async throws -> [MangaChapter] {
        let detail = try await self.mediaDetail(catalogId: alId, isManga: true)
        return try await mangaChapters(detail: detail)
    }

    /// The chapters for a title the app has the AniList detail of; see
    /// `mangaSource` for how the source is chosen.
    public func mangaChapters(detail: MediaDetail) async throws -> [MangaChapter] {
        await mangaSource(
            catalogId: detail.catalogId,
            titles: [detail.title, detail.romajiTitle].compactMap { $0 },
            finishedChapters: detail.status == "FINISHED" ? detail.chapterCount.map { Int($0) } : nil
        )?.chapters ?? []
    }

    /// Fetches chapter image URLs for a MangaDex chapter ID.
    public func mangaPages(chapterId: String) async throws -> [String] {
        return try await self.getMangaPages(chapterId: chapterId)
    }
}

// The people and thread records are value types of String/Int/arrays of the
// same, but uniffi emits them without Sendable. CI's toolchain (stricter
// than the local one) rejects returning them from the engine's nonisolated
// async methods into a @MainActor task: "non-sendable result type
// 'FfiCharacterDetail' cannot be sent from nonisolated context".
extension FfiCharacterDetail: @unchecked Sendable {}
extension FfiStaffDetail: @unchecked Sendable {}
extension FfiThreadDetail: @unchecked Sendable {}
extension FfiThreadCommentPage: @unchecked Sendable {}

// Every record the engine returns from an async method is awaited on the
// main actor somewhere in the UI, and CI's stricter toolchain rejects each
// one it meets ("non-sendable result type 'FfiStudioDetail' cannot be sent
// from nonisolated context"), one type per push. All of them are plain
// values of strings, numbers and arrays of the same, so the whole set is
// declared at once rather than chased one CI run at a time.
extension FfiAiringSlot: @unchecked Sendable {}
extension FfiCharacter: @unchecked Sendable {}
extension FfiCharacterAppearance: @unchecked Sendable {}
extension FfiCreditCharacter: @unchecked Sendable {}
extension FfiDayCount: @unchecked Sendable {}
extension FfiDiscussion: @unchecked Sendable {}
extension FfiRecommendation: @unchecked Sendable {}
extension FfiRecommendationRow: @unchecked Sendable {}
extension FfiRelation: @unchecked Sendable {}
extension FfiStaffCharacterCredit: @unchecked Sendable {}
extension FfiStaffMediaCredit: @unchecked Sendable {}
extension FfiStudioDetail: @unchecked Sendable {}
extension FfiStudioRef: @unchecked Sendable {}
extension FfiThreadComment: @unchecked Sendable {}

// The rest of the generated surface, declared in one go for the same reason:
// every record above was added after a CI run named it, one per push, and the
// list of types the UI awaits on the main actor only grows. These cover the
// cinema, download, reader and playback records plus `AnicatError`, which a
// throwing engine call has to carry across the same boundary.
extension AnicatError: @unchecked Sendable {}
extension CinemaCredit: @unchecked Sendable {}
extension CinemaExtras: @unchecked Sendable {}
extension CinemaPerson: @unchecked Sendable {}
extension CinemaSeason: @unchecked Sendable {}
extension EpisodeRow: @unchecked Sendable {}
extension FfiCinemaGenre: @unchecked Sendable {}
extension FfiDownloadStatus: @unchecked Sendable {}
extension FfiDownloadedEpisode: @unchecked Sendable {}
extension FfiLocalEntry: @unchecked Sendable {}
extension FfiNovelDownload: @unchecked Sendable {}
extension FfiOfflineChapter: @unchecked Sendable {}
extension FfiOfflineKind: @unchecked Sendable {}
extension FfiReadingProgress: @unchecked Sendable {}
extension FfiReadingRow: @unchecked Sendable {}
extension FfiResolvedRelease: @unchecked Sendable {}
extension FfiTitleHint: @unchecked Sendable {}
extension NovelChapterContent: @unchecked Sendable {}
extension NovelChapterRef: @unchecked Sendable {}
extension NovelImage: @unchecked Sendable {}
extension NovelInfo: @unchecked Sendable {}
extension RelatedTitle: @unchecked Sendable {}
extension StreamHandle: @unchecked Sendable {}
extension StreamRequest: @unchecked Sendable {}
extension ViewerProfile: @unchecked Sendable {}
extension FfiTitleCount: @unchecked Sendable {}
extension FfiTorrentChoice: @unchecked Sendable {}
extension FfiTrackPreference: @unchecked Sendable {}
extension FfiVoiceActor: @unchecked Sendable {}
extension FfiWatchStats: @unchecked Sendable {}
extension MangaChapter: @unchecked Sendable {}
extension MangaSummary: @unchecked Sendable {}
extension MediaDetail: @unchecked Sendable {}
extension MediaSummary: @unchecked Sendable {}
extension WatchProgress: @unchecked Sendable {}
// Payload-free enum; crosses from the main-actor `AppModel` into engine calls.
extension FfiCatalog: @unchecked Sendable {}
extension ActivityRow: @unchecked Sendable {}
