import XCTest
@testable import AnicatCoreKit

/// Proves the Swift/Rust boundary itself works: the engine constructs, an
/// async Rust future completes back on the Swift side, records cross both
/// ways, and a Rust `Result::Err` arrives as a Swift `Error` rather than as a
/// sentinel value.
final class BridgeTests: XCTestCase {
    private func makeEngine() throws -> AnicatEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("anicat-bridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Port 0: nothing in this test opens the returned url, and the range
        // server that would own a real port is the host app's, not the
        // engine's.
        return try AnicatEngine(dataDir: dir.path, anilistToken: nil, tmdbKey: nil, proxyPort: 0)
    }

    func testEngineConstructsAndOpensItsRegistry() throws {
        _ = try makeEngine()
    }

    func testProgressRoundTripsThroughSqlite() throws {
        let engine = try makeEngine()
        XCTAssertNil(try engine.getProgress(catalog: .anilist, catalogId: 21, episodeNumber: 1))

        try engine.recordProgress(
            catalog: .anilist, catalogId: 21, episodeNumber: 1, stopTime: 340, duration: 1440)
        let saved = try XCTUnwrap(
            try engine.getProgress(catalog: .anilist, catalogId: 21, episodeNumber: 1))
        XCTAssertEqual(saved.stopTime, 340)
        XCTAssertEqual(saved.duration, 1440)

        // The composite key is the whole point of dropping the id banding:
        // the same integer under another catalog is a different show.
        XCTAssertNil(try engine.getProgress(catalog: .tmdbTv, catalogId: 21, episodeNumber: 1))
    }

    func testAnErrorFromRustSurfacesAsASwiftThrow() async throws {
        let engine = try makeEngine()
        do {
            _ = try await engine.getMangaPages(chapterId: "not-a-uuid")
            XCTFail("expected a thrown AnicatError")
        } catch let error as AnicatError {
            // Which variant depends on what MangaDex answers; that it is typed
            // and catchable is what this asserts.
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    /// Network test: hits the live AniList GraphQL API through the Rust
    /// client, so it proves the async runtime bridge end to end. Skipped
    /// rather than failed when the network is unavailable, so an offline
    /// `swift test` still means something.
    func testAsyncAnilistSearchCrossesTheBridge() async throws {
        let engine = try makeEngine()
        let results: [MediaSummary]
        do {
            results = try await engine.searchAnime(query: "Frieren")
        } catch {
            throw XCTSkip("AniList unreachable: \(error)")
        }
        XCTAssertFalse(results.isEmpty)
        let first = try XCTUnwrap(results.first)
        XCTAssertEqual(first.catalog, .anilist)
        XCTAssertGreaterThan(first.catalogId, 0)
        XCTAssertFalse(first.title.isEmpty)
    }
}
