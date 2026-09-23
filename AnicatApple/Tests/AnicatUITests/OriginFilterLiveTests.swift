import Testing
import Foundation
@testable import AnicatCoreKit

/// The Origin filter through the real engine and AniList, after a plain
/// browse has filled the engine's search cache. That order is the bug this
/// guards: the country was missing from the cache key, so "Korea" answered
/// with the cached unfiltered list. Live, so only on `ANICAT_LIVE=1`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANICAT_LIVE"] == "1"))
func originFilterIsNotServedFromTheUnfilteredCache() async throws {
    let dir = NSTemporaryDirectory() + "anicat_origin_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let engine = try AnicatEngine(dataDir: dir, anilistToken: nil, tmdbKey: nil, tmdbProxy: nil)
    func browse(_ country: String?) async throws -> [Int64] {
        let filters = SearchFilters(genre: nil, year: nil, season: nil, format: nil, minScore: nil,
                                    status: nil, sort: nil, country: country)
        return try await engine.searchCatalog(query: nil, mediaType: "MANGA", filters: filters, page: 1).map(\.catalogId)
    }
    let any = try await browse(nil)
    let korean = try await browse("KR")
    let chinese = try await browse("CN")
    print("any \(any.prefix(5)) korean \(korean.prefix(5)) chinese \(chinese.prefix(5))")
    #expect(!korean.isEmpty && !chinese.isEmpty)
    #expect(korean != any)
    #expect(Set(korean).isDisjoint(with: chinese))
}
