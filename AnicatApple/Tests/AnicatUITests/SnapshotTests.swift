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

    @Test("Render WeekStrip Snapshot")
    @MainActor
    func testRenderWeekStrip() throws {
        let calendar = Calendar.current
        let now = Date()
        let startOfToday = calendar.startOfDay(for: now)
        let todayUnix = Int64(startOfToday.timeIntervalSince1970)

        let items = [
            ScheduleView.ScheduleItem(
                id: 1,
                title: "Sousou no Frieren: Beyond Journey's End",
                coverImageURL: nil,
                episodeNumber: 28,
                airingTimeText: "23:00",
                countdownText: "in 5h",
                dayGroup: "Today",
                airingAt: todayUnix + 3600,
                isWatching: true
            ),
            ScheduleView.ScheduleItem(
                id: 2,
                title: "Dungeon Meshi",
                coverImageURL: nil,
                episodeNumber: 12,
                airingTimeText: "22:30",
                countdownText: "in 1d",
                dayGroup: "Tomorrow",
                airingAt: todayUnix + 86400 + 3600,
                isWatching: true
            ),
            ScheduleView.ScheduleItem(
                id: 3,
                title: "Solo Leveling Season 2: -Arise from the Shadow-",
                coverImageURL: nil,
                episodeNumber: 9,
                airingTimeText: "18:00",
                countdownText: "in 3d",
                dayGroup: "Day 3",
                airingAt: todayUnix + 3 * 86400 + 3600,
                isWatching: true
            ),
            ScheduleView.ScheduleItem(
                id: 4,
                title: "Re:Zero kara Hajimeru Isekai Seikatsu 3rd Season",
                coverImageURL: nil,
                episodeNumber: 6,
                airingTimeText: "20:00",
                countdownText: "in 3d",
                dayGroup: "Day 3",
                airingAt: todayUnix + 3 * 86400 + 7200,
                isWatching: true
            )
        ]

        let strip = WeekStrip(items: items, onSelect: { _ in })
            .frame(width: 800)
            .padding(20)
            .background(SumiTheme.background)

        let renderer = ImageRenderer(content: strip)
        renderer.scale = 2.0

        guard let nsImage = renderer.nsImage,
              let tiffData = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to render WeekStrip image")
            return
        }

        let outPath = "/tmp/anicat_weekstrip_snapshot.png"
        try pngData.write(to: URL(fileURLWithPath: outPath))
        print("Successfully rendered WeekStrip snapshot to \(outPath)")
    }
}
