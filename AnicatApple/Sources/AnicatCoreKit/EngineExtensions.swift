import Foundation

// uniffi generates SearchFilters as a plain struct with no Sendable
// conformance. It only ever holds String?/Int32? fields, so @unchecked is
// safe — without this a caller passing filters into a `Task { }` closure
// fails Swift 6's strict-concurrency check at the call site instead of here.
extension SearchFilters: @unchecked Sendable {}

extension AnicatEngine {
    /// Fetches chapters for an AniList manga ID by resolving its MangaDex mapping.
    public func mangaChapters(alId: Int64) async throws -> [MangaChapter] {
        let detail = try await self.mediaDetail(catalogId: alId, isManga: true)
        return try await mangaChapters(detail: detail)
    }

    /// Fetches chapters using an already fetched MediaDetail, trying primary and Romaji
    /// titles with punctuation-stripped fallback to ensure maximum MangaDex hit rate.
    public func mangaChapters(detail: MediaDetail) async throws -> [MangaChapter] {
        let alId = detail.catalogId
        var queries: [String] = []

        if !detail.title.isEmpty {
            queries.append(detail.title)
        }
        if let romaji = detail.romajiTitle, !romaji.isEmpty, !queries.contains(romaji) {
            queries.append(romaji)
        }

        // Add sanitized titles (without punctuation, brackets, special quotes)
        let initialQueries = queries
        for q in initialQueries {
            let sanitized = q
                .replacingOccurrences(of: "[\\[\\]【】()（）:!?:~×*\"'`’‘]", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty && !queries.contains(sanitized) {
                queries.append(sanitized)
            }
        }

        // MangaDex's own `links.al` confirms a result IS the AniList entry
        // we're looking for, not just a title that happened to match the
        // search text — so once one is found, MangaDex's queries stop
        // rather than trying further candidates. Falling through past a
        // confirmed match onto the next search result is exactly how a
        // completely unrelated manga's chapters ended up being served under
        // this title's name: "Tomodachi Game" only had 2 untranslated
        // chapters on MangaDex, and continuing past that confirmed match
        // onto "Sometimes Even Reality Is a Lie!" (which merely shares some
        // search-relevant words) produced a false "1 chapter" that was
        // actually chapter 1 of a different series.
        mangadexSearch: for query in queries {
            let matches = (try? await self.searchManga(query: query, anilistId: alId)) ?? []
            for match in matches.prefix(3) {
                let chapters = (try? await self.getMangaChapters(mangaId: match.id)) ?? []
                if match.matchesAnilist {
                    if !chapters.isEmpty {
                        return chapters
                    }
                    // Identity confirmed, but every English chapter is gone
                    // (a publisher takedown leaves them at `pages: 0`, which
                    // is exactly the real "Tomodachi Game" case). That is
                    // MangaDex's final answer for this title — MangaKatana
                    // carries no such takedown and often still has the full
                    // run, so it gets one try before giving up outright.
                    break mangadexSearch
                }
                if !chapters.isEmpty {
                    return chapters
                }
            }
        }

        for query in queries {
            let matches = (try? await self.searchMangaKatana(query: query)) ?? []
            for match in matches.prefix(3) {
                let chapters = (try? await self.getMangaChapters(mangaId: match.id)) ?? []
                if !chapters.isEmpty {
                    return chapters
                }
            }
        }

        return []
    }

    /// Fetches chapter image URLs for a MangaDex chapter ID.
    public func mangaPages(chapterId: String) async throws -> [String] {
        return try await self.getMangaPages(chapterId: chapterId)
    }
}
