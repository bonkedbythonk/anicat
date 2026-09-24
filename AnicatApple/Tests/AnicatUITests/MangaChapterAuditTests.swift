import Testing
import Foundation
@testable import AnicatCoreKit

/// Walks the most popular manga, manhwa and manhua on AniList through the
/// reader's chapter lookup and writes one JSON line per title to
/// `ANICAT_MANGA_AUDIT_OUT`: which source answered, under what title, and
/// what the chapter numbers look like. A report, not a pass/fail check; only
/// runs when that variable is set.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANICAT_MANGA_AUDIT_OUT"] != nil),
      .timeLimit(.minutes(60)))
func mangaChapterAudit() async throws {
    let out = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["ANICAT_MANGA_AUDIT_OUT"]))
    let perCountry = Int(ProcessInfo.processInfo.environment["ANICAT_MANGA_AUDIT_PER_COUNTRY"] ?? "") ?? 30
    let dir = NSTemporaryDirectory() + "anicat_manga_audit_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let engine = try AnicatEngine(dataDir: dir, anilistToken: nil, tmdbKey: nil, tmdbProxy: nil)
    FileManager.default.createFile(atPath: out.path, contents: nil)
    let handle = try FileHandle(forWritingTo: out)
    defer { try? handle.close() }

    for country in ["JP", "KR", "CN"] {
        var ids: [Int64] = []
        var page: Int32 = 1
        while ids.count < perCountry {
            let filters = SearchFilters(genre: nil, year: nil, season: nil, format: nil, minScore: nil,
                                        status: nil, sort: nil, country: country)
            let batch = try await patiently { try await engine.searchCatalog(query: nil, mediaType: "MANGA", filters: filters, page: page) }
            if batch.isEmpty { break }
            ids += batch.map(\.catalogId)
            page += 1
        }
        for id in ids.prefix(perCountry) {
            var row: [String: Any] = ["country": country, "id": id]
            do {
                let detail = try await patiently { try await engine.mediaDetail(catalogId: id, isManga: true) }
                row["title"] = detail.title
                row["romaji"] = detail.romajiTitle ?? ""
                row["anilistChapters"] = detail.chapterCount.map { Int($0) } ?? -1
                row["status"] = detail.status ?? ""
                row["format"] = detail.format ?? ""
                let began = Date()
                let source = await engine.mangaSource(
                    catalogId: detail.catalogId,
                    titles: [detail.title, detail.romajiTitle].compactMap { $0 },
                    finishedChapters: detail.status == "FINISHED" ? detail.chapterCount.map { Int($0) } : nil
                )
                let match = source?.match
                let chapters = source?.chapters ?? []
                row["seconds"] = Int(Date().timeIntervalSince(began))
                row["matchedTitle"] = match?.title ?? ""
                row["matchedId"] = match?.id ?? ""
                row["confirmed"] = match?.matchesAnilist ?? false
                row["count"] = chapters.count
                row["katanaRows"] = chapters.filter { $0.id.hasPrefix("http") }.count
                row["zeroPages"] = chapters.filter { $0.pages == 0 && !$0.id.hasPrefix("http") }.count
                let numbers = chapters.compactMap { Double($0.number) }
                row["unnumbered"] = chapters.count - numbers.count
                row["max"] = numbers.max() ?? -1
                row["min"] = numbers.min() ?? -1
                let whole = Set(numbers.filter { $0 >= 1 }.map { Int($0) })
                if let top = whole.max() {
                    row["missingWhole"] = (1...top).filter { !whole.contains($0) }.count
                }
                row["duplicates"] = chapters.count - Set(chapters.map(\.number)).count
                row["first"] = chapters.prefix(3).map { "\($0.number):\($0.title)" }
                row["last"] = chapters.suffix(2).map { "\($0.number):\($0.title)" }
            } catch {
                row["error"] = "\(error)"
            }
            let data = try JSONSerialization.data(withJSONObject: row)
            handle.write(data)
            handle.write(Data("\n".utf8))
            // AniList is on a degraded limit and shares this IP with the
            // owner's running app; keep this run well under it.
            try await Task.sleep(nanoseconds: 4_000_000_000)
        }
    }
}

/// AniList answers a burst with 429 and the engine passes it up rather than
/// waiting; a report should wait it out, not lose the title.
private func patiently<T>(_ call: () async throws -> T) async throws -> T {
    for _ in 0..<6 {
        do { return try await call() } catch where "\(error)".contains("429") {
            try await Task.sleep(nanoseconds: 20_000_000_000)
        }
    }
    return try await call()
}
