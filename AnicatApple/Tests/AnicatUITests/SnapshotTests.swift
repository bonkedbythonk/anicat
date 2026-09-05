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
        .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: hero)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 320)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap rep for HeroBanner")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
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

    @Test("Render MediaDetailView Snapshot")
    @MainActor
    func testRenderMediaDetail() throws {
        let details = HeroBanner.Details(
            title: "Rich Girl Caretaker: I'm Secretly the Caregiver of the Most Popular Girl in This Rich Kid School",
            romajiTitle: "Saijo no Osewa: Takane no Hanadarake na Meimonkou de...",
            bannerURL: URL(fileURLWithPath: "/Users/thomas/Documents/randomcode/personal/anicat/assets/branding/detail.png"),
            coverURL: URL(fileURLWithPath: "/Users/thomas/Documents/randomcode/personal/anicat/assets/branding/detail.png"),
            format: "TV",
            year: 2026,
            studio: "Brain's Base",
            synopsis: "Hinako Konohana is the perfect young lady—graceful, elegant, and flawless... or so everyone thinks. Behind closed doors, she's a total disaster who can't handle basic chores! When ordinary student Itsuki Tomonari becomes her caretaker, he's thrown into 24/7 damage control, maintaining her \"perfect\" image.",
            genres: ["Comedy", "Romance", "School"],
            averageScore: 70,
            status: "RELEASING",
            episodeCount: 12,
            resumeEpisode: 10,
            listStatus: "CURRENT"
        )

        let episodes = (1...12).map { i in
            MediaDetailView.EpisodeItem(
                id: Int64(i),
                number: i,
                title: "Episode \(i)",
                thumbnailURL: nil,
                isWatched: i < 10,
                synopsis: "Episode synopsis \(i)"
            )
        }
        let characters = (1...8).map { i in
            MediaDetailView.CharacterItem(id: Int64(i), name: "Character \(i)", role: "Main")
        }
        let relations = (1...2).map { i in
            MediaDetailView.RelationItem(id: Int64(i), relationType: "SEQUEL", title: "Season \(i + 1)")
        }
        let discussions = (1...14).map { i in
            MediaDetailView.DiscussionItem(id: Int64(i), title: "Discussion topic \(i)", replyCount: i * 3, viewCount: i * 20)
        }
        let recommendations = (1...10).map { i in
            MediaDetailView.RecommendationItem(id: Int64(i), title: "Similar Show \(i)")
        }

        let detailView = MediaDetailView(
            details: details,
            episodes: episodes,
            characters: characters,
            relations: relations,
            recommendations: recommendations,
            discussions: discussions
        )
        .frame(width: 824, height: 750)
        .background(SumiTheme.background)
        .preferredColorScheme(.dark)

        let hostingView = NSHostingView(rootView: detailView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 824, height: 750)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.layoutSubtreeIfNeeded()

        guard let bitmapRep = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            Issue.record("Failed to create bitmap rep for MediaDetailView")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmapRep)

        guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
            Issue.record("Failed to render MediaDetailView image")
            return
        }

        let outPath = "/tmp/anicat_detail_snapshot.png"
        try pngData.write(to: URL(fileURLWithPath: outPath))
        print("Successfully rendered MediaDetailView snapshot to \(outPath)")
    }
}
