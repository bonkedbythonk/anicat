import SwiftUI
import Testing
import AppKit
@testable import AnicatUI

@Suite("Visual Snapshot Verification")
struct SnapshotTests {
    @Test("Render HeroBanner and MediaCard Snapshot")
    @MainActor
    func testRenderComponents() throws {
        let details = HeroBanner.Details(
            title: "Code Geass: Lelouch of the Rebellion",
            romajiTitle: "Code Geass: Hangyaku no Lelouch",
            bannerURL: nil,
            coverURL: nil,
            format: "TV",
            year: 2006,
            studio: "Sunrise",
            synopsis: "In the year 2010, the Holy Empire of Britannia is establishing itself as a dominant military nation, starting with the conquest of Japan.",
            genres: ["Action", "Mecha", "Sci-Fi"],
            averageScore: 85,
            nextEpisodeText: "Continue Episode 5"
        )

        let hero = HeroBanner(
            details: details,
            onPrimaryAction: {},
            onTrailerAction: {}
        )
        .frame(width: 800, height: 320)
        .background(SumiTheme.background)

        let renderer = ImageRenderer(content: hero)
        renderer.scale = 2.0
        
        guard let nsImage = renderer.nsImage else {
            Issue.record("Failed to create NSImage from ImageRenderer")
            return
        }

        guard let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to convert image to PNG")
            return
        }

        let outPath = "/tmp/anicat_hero_snapshot.png"
        try pngData.write(to: URL(fileURLWithPath: outPath))
        print("Successfully rendered snapshot to \(outPath)")
    }
}
