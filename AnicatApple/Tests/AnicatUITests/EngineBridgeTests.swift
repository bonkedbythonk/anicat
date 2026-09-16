import Testing
import Foundation
@testable import AnicatCoreKit

@Suite("AnicatEngine Swift-Rust Integration")
struct EngineBridgeTests {
    @Test("Instantiate Engine and Search Anime")
    func testEngineInitAndSearch() async throws {
        let tempDir = NSTemporaryDirectory() + "anicat_test_\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(atPath: tempDir)
        }

        // Initialize the Rust engine across the UniFFI boundary
        let engine = try AnicatEngine(
            dataDir: tempDir,
            anilistToken: nil,
            tmdbKey: nil,
            tmdbProxy: nil
        )

        // Verify dynamic stream port is assigned
        let port = try await engine.streamPort()
        #expect(port > 0)
        print("Engine loopback range-server bound to port: \(port)")

        // Test live AniList search query through Rust reqwest/GraphQL
        let results = try await engine.searchAnime(query: "Frieren")
        #expect(!results.isEmpty)
        
        if let first = results.first {
            print("Successfully resolved from Rust via UniFFI: \(first.title) (Catalog ID: \(first.catalogId))")
            #expect(first.title.contains("Frieren") || first.title.contains("Sousou"))
        }
    }
}
