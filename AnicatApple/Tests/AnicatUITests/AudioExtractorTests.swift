import Testing
import Foundation
@testable import AnicatUI

/// Decodes through the app's own libmpv, not the mpv command line the
/// fingerprinting was measured with: MPVKit's build has to have `ao=pcm`
/// and honour `untimed`. Needs a local video, so it runs only when
/// `ANICAT_SKIP_TEST_FILE` names one.
@Test(.enabled(if: ProcessInfo.processInfo.environment["ANICAT_SKIP_TEST_FILE"] != nil))
func audioExtractorWritesMonoPCM() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ANICAT_SKIP_TEST_FILE"])
    let out = FileManager.default.temporaryDirectory.appendingPathComponent("anicat-extract-test.raw")
    defer { try? FileManager.default.removeItem(at: out) }
    let began = Date()
    let ok = await AudioExtractor.extract(url: path, start: 60, length: 120, preferDub: false, to: out)
    let size = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    print("extracted \(size) bytes in \(Date().timeIntervalSince(began))s")
    #expect(ok)
    #expect(abs(size - 120 * AudioExtractor.sampleRate * 2) < AudioExtractor.sampleRate * 2)
}
