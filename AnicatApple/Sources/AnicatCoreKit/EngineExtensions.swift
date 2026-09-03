import Foundation

extension AnicatEngine {
    /// Fetches chapters for an AniList manga ID by resolving its MangaDex mapping.
    public func mangaChapters(alId: Int64) async throws -> [MangaChapter] {
        let detail = try await self.mediaDetail(catalogId: alId, isManga: true)
        let matches = try await self.searchManga(query: detail.title, anilistId: alId)
        guard let first = matches.first else { return [] }
        return try await self.getMangaChapters(mangaId: first.id)
    }

    /// Fetches chapter image URLs for a MangaDex chapter ID.
    public func mangaPages(chapterId: String) async throws -> [String] {
        return try await self.getMangaPages(chapterId: chapterId)
    }
}
