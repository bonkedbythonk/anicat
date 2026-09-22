import Testing
import Foundation
@testable import AnicatUI

@Suite("MangaDex@Home report classifier")
struct MangaDexHomeReporterTests {
    private func url(_ s: String) -> URL { URL(string: s)! }

    @Test("A node page under /data/ is reported, with or without a token segment")
    func nodePages() {
        #expect(MangaDexHomeReporter.isAtHomeURL(url(
            "https://cmdxd98sb0x3yprd.mangadex.network/data/3303dd03ac8d85f3d0e7e0f8e3e3e3e3/1-a1b2c3.png")))
        #expect(MangaDexHomeReporter.isAtHomeURL(url(
            "https://cmdxd98sb0x3yprd.mangadex.network:443/eyJhbGciOiJIUzI1NiJ9.abc/data/3303dd03ac8d85f3d0e7e0f8e3e3e3e3/1-a1b2c3.png")))
        #expect(MangaDexHomeReporter.isAtHomeURL(url(
            "https://cmdxd98sb0x3yprd.mangadex.network/data-saver/3303dd03ac8d85f3d0e7e0f8e3e3e3e3/1-a1b2c3.jpg")))
    }

    @Test("MangaDex's own origin is never reported, pages or covers")
    func mangadexOrigin() {
        #expect(!MangaDexHomeReporter.isAtHomeURL(url(
            "https://uploads.mangadex.org/data/3303dd03ac8d85f3d0e7e0f8e3e3e3e3/1-a1b2c3.png")))
        #expect(!MangaDexHomeReporter.isAtHomeURL(url(
            "https://uploads.mangadex.org/covers/6d5e2f1a-0b3c-4d5e-8f9a-1b2c3d4e5f60/cover.jpg")))
        #expect(!MangaDexHomeReporter.isAtHomeURL(url("https://mangadex.org/data/x/y.png")))
        #expect(!MangaDexHomeReporter.isAtHomeURL(url("https://api.mangadex.org/at-home/server/abc")))
    }

    @Test("MangaKatana, AniList and offline chapters are not the network's business")
    func otherSources() {
        #expect(!MangaDexHomeReporter.isAtHomeURL(url("https://i3.mangakatana.com/some-title/c12/001.jpg")))
        #expect(!MangaDexHomeReporter.isAtHomeURL(url(
            "https://s4.anilist.co/file/anilistcdn/media/manga/cover/large/bx30002.jpg")))
        // A downloaded chapter is read back from disk; a `/data/` in the path
        // would still be no fetch.
        #expect(!MangaDexHomeReporter.isAtHomeURL(url(
            "file:///Users/x/Library/Application%20Support/Anicat/offline/data/abc/1.png")))
        #expect(!MangaDexHomeReporter.isAtHomeURL(url("https://example.com/data")))
        #expect(!MangaDexHomeReporter.isAtHomeURL(url("https://example.com/database/1.png")))
    }

    @Test("A report carries the node's X-Cache verdict, HTTP success and whole milliseconds")
    func reportShape() {
        let page = url("https://node.mangadex.network/data/abc/1.png")
        let hit = MangaDexHomeReporter.makeReport(
            url: page, statusCode: 200, xCache: "HIT", bytes: 123_456, durationNanoseconds: 1_234_567_890)
        #expect(hit == MangaDexHomeReporter.Report(
            url: page.absoluteString, success: true, bytes: 123_456, duration: 1234, cached: true))

        // Nodes answer with "HIT from cluster" style values and a lowercase
        // "hit" has been seen; the prefix is what counts.
        #expect(MangaDexHomeReporter.makeReport(
            url: page, statusCode: 200, xCache: "hit from cluster", bytes: 1, durationNanoseconds: 0).cached)
        #expect(!MangaDexHomeReporter.makeReport(
            url: page, statusCode: 200, xCache: "MISS", bytes: 1, durationNanoseconds: 0).cached)
        #expect(!MangaDexHomeReporter.makeReport(
            url: page, statusCode: 200, xCache: nil, bytes: 1, durationNanoseconds: 0).cached)

        // A 404 body still arrives as data; it is not a successful image.
        #expect(!MangaDexHomeReporter.makeReport(
            url: page, statusCode: 404, xCache: nil, bytes: 512, durationNanoseconds: 0).success)
        // No response at all is a failure with nothing received.
        let dead = MangaDexHomeReporter.makeReport(
            url: page, statusCode: nil, xCache: nil, bytes: 0, durationNanoseconds: 10_000_000_000)
        #expect(!dead.success)
        #expect(dead.duration == 10_000)
    }

    @Test("The JSON keys are the ones the endpoint reads")
    func jsonKeys() throws {
        let report = MangaDexHomeReporter.Report(
            url: "https://node.mangadex.network/data/abc/1.png", success: true, bytes: 42, duration: 7, cached: false)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any]
        #expect(json?["url"] as? String == "https://node.mangadex.network/data/abc/1.png")
        #expect(json?["success"] as? Bool == true)
        #expect(json?["bytes"] as? Int == 42)
        #expect(json?["duration"] as? Int == 7)
        #expect(json?["cached"] as? Bool == false)
    }
}
