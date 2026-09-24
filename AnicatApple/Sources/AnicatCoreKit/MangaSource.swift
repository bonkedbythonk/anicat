import Foundation

/// Where a title's chapters were read from, and the chapters.
public struct MangaSource {
    public let match: MangaSummary
    public let chapters: [MangaChapter]
}

/// The rules for accepting a search result as the manga that was asked for.
/// Each one is the fix for a title that read the wrong series or a fragment
/// of the right one, measured on the 90 most popular manga, manhwa and
/// manhua on AniList (2026-09-24, `MangaChapterAuditTests`).
enum MangaMatching {
    /// Lowercase letters and digits of a title without its edition label, so
    /// "ONE PIECE", "One-Piece" and "Onepunch-Man (ONE)" compare as the plain
    /// title does.
    static func key(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespaces)
        while t.hasSuffix(")"), let open = t.lastIndex(of: "("), open > t.startIndex {
            t = String(t[..<open]).trimmingCharacters(in: .whitespaces)
        }
        return t.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// A MangaDex result without AniList's own link is accepted only under
    /// one of the title's names. The two unconfirmed picks in the audit were
    /// both wrong: "Berserk" read three chapters of "VRMMO Chronicles of a
    /// Solo Cleric", and "Vagabond" a six-chapter colored fragment.
    static func isSameTitle(_ candidate: String, as titles: [String]) -> Bool {
        let wanted = Set(titles.map(key).filter { !$0.isEmpty })
        return wanted.contains(key(candidate))
    }

    /// MangaKatana results worth trying, best first: an exact name anywhere
    /// in the list, then the site's own order without spin-offs. The site
    /// ranks "My Hero Academia Team Up Mission" first for "My Hero Academia"
    /// and the series itself ("Boku no Hero Academia") fifth; "Tokyo
    /// Revengers: Letter from Keisuke Baji" and "Kaiju No. 8: B-Side" were
    /// read in place of their series. Its order is still kept for the rest,
    /// because it knows names AniList does not: "Solo Max-Level Newbie",
    /// "Ranker Who Lives A Second Time", "Return of the Mount Hua Sect".
    static func katanaOrder(_ results: [MangaSummary], titles: [String]) -> [MangaSummary] {
        let wanted = titles.map(key).filter { !$0.isEmpty }
        let exact = results.filter { wanted.contains(key($0.title)) }
        let rest = results.filter { result in
            let k = key(result.title)
            return !wanted.contains(k) && !wanted.contains { k.hasPrefix($0) }
        }
        return exact + rest
    }

    /// The feed misses most of the run: it starts past chapter 1, or holds
    /// fewer than half the chapters its own numbering reaches. The engine's
    /// `sparse_feed` test, applied after it has already tried to fill in.
    static func isPartial(_ chapters: [MangaChapter]) -> Bool {
        let numbers = chapters.compactMap { Double($0.number) }
        guard let lowest = numbers.min(), let highest = numbers.max() else { return true }
        return lowest > 1 || Double(chapters.count) * 2 < highest
    }

    /// Against a finished title's chapter count, when AniList has one. KR
    /// "Bastard" (94 chapters) matched the Japanese "Bastard!!" exactly by
    /// name and read 139 chapters of it. Generous either side: releases add
    /// extras and split chapters (Solo Leveling 200 of 201, Promised
    /// Neverland 181.9 of 181).
    static func isTooLong(_ chapters: [MangaChapter], finished: Int?) -> Bool {
        guard let finished, finished > 0,
              let highest = chapters.compactMap({ Double($0.number) }).max() else { return false }
        return highest > Double(finished) * 1.25 + 5
    }

    /// A MangaKatana list stands in for a MangaDex fragment only if it
    /// reaches about as far as the fragment proves the run goes. "The
    /// Swordmaster's Son" has chapters 156-157 on MangaDex, and the site's
    /// best answer for it was 7 chapters of "Bijo, Tokidoki Yajuu".
    /// "Apotheosis" (1293 of MangaDex's 1301 for Principles of Heavens)
    /// passes.
    static func reachesRun(_ chapters: [MangaChapter], of partial: MangaSource?) -> Bool {
        guard let known = partial?.chapters.compactMap({ Double($0.number) }).max() else { return true }
        return (chapters.compactMap { Double($0.number) }.max() ?? 0) >= known * 0.8
    }

    static func fuller(_ a: MangaSource?, _ b: MangaSource) -> MangaSource {
        guard let a else { return b }
        return b.chapters.count > a.chapters.count ? b : a
    }
}

extension AnicatEngine {
    /// The chapters to read for a title, and where they came from. MangaDex
    /// first; a result carrying AniList's link to this title settles the
    /// search there unless its feed is only a fragment, in which case
    /// MangaKatana is asked and the fuller of the two wins: Demon Slayer's
    /// only linked entry is the colored edition from chapter 140, and
    /// Komi's a fan-colored one of 9 chapters.
    public func mangaSource(catalogId: Int64, titles: [String], finishedChapters: Int?) async -> MangaSource? {
        var queries: [String] = []
        for title in titles where !title.isEmpty && !queries.contains(title) {
            queries.append(title)
        }
        for q in queries {
            let sanitized = q
                .replacingOccurrences(of: "[\\[\\]【】()（）:!?:~×*\"'`’‘]", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sanitized.isEmpty && !queries.contains(sanitized) {
                queries.append(sanitized)
            }
        }

        var partial: MangaSource?
        mangadexSearch: for query in queries {
            let matches = (try? await self.searchManga(query: query, anilistId: catalogId)) ?? []
            for match in matches.prefix(3) {
                guard match.matchesAnilist || MangaMatching.isSameTitle(match.title, as: titles) else { continue }
                let chapters = (try? await self.getMangaChapters(mangaId: match.id)) ?? []
                if !chapters.isEmpty {
                    let found = MangaSource(match: match, chapters: chapters)
                    if !MangaMatching.isPartial(chapters) { return found }
                    partial = MangaMatching.fuller(partial, found)
                }
                // A confirmed match is MangaDex's final answer for this
                // title. Carrying on down the results is how "Tomodachi
                // Game" once read chapter 1 of a different series.
                if match.matchesAnilist { break mangadexSearch }
            }
        }

        for query in queries {
            let results = (try? await self.searchMangaKatana(query: query)) ?? []
            for match in MangaMatching.katanaOrder(results, titles: titles).prefix(3) {
                let chapters = (try? await self.getMangaChapters(mangaId: match.id)) ?? []
                guard !chapters.isEmpty, !MangaMatching.isTooLong(chapters, finished: finishedChapters),
                      MangaMatching.reachesRun(chapters, of: partial) else { continue }
                let found = MangaSource(match: match, chapters: chapters)
                if !MangaMatching.isPartial(chapters), chapters.count > (partial?.chapters.count ?? 0) {
                    return found
                }
                partial = MangaMatching.fuller(partial, found)
            }
        }
        return partial
    }
}
