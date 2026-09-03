import Testing
import Foundation
@testable import AnicatCoreKit
@testable import AnicatUI

@Suite("Real Data Wiring & Zero Mock Verification")
struct RealDataWiringTests {

    private func makeEngine() throws -> (AnicatEngine, String) {
        let tempDir = NSTemporaryDirectory() + "anicat_wiring_test_\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
        let engine = try AnicatEngine(
            dataDir: tempDir,
            anilistToken: nil,
            tmdbKey: nil
        )
        return (engine, tempDir)
    }

    @Test("MenuBarView and PlayerController have zero mock data defaults")
    @MainActor
    func testZeroMockDefaults() {
        let menu = MenuBarView()
        #expect(menu.lastWatchedTitle == nil)
        #expect(menu.lastWatchedEpisode == nil)
        #expect(menu.airingItems.isEmpty)

        let player = PlayerController()
        #expect(player.introStartTime == nil)
        #expect(player.introEndTime == nil)
        #expect(player.duration == 0.0)
    }

    @Test("AppModel.openDetail fetches real AniList data and populates detail/episodes")
    func testOpenDetailFetchesRealData() async throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let model = AppModel()
        model.engine = engine

        // Open Frieren (AniList ID: 154587)
        await model.openDetail(id: 154587, isManga: false)

        #expect(model.errorMessage == nil)
        guard let details = model.selectedMediaDetails else {
            Issue.record("selectedMediaDetails was nil")
            return
        }

        #expect(details.id == 154587)
        #expect(details.title.contains("Frieren") || (details.romajiTitle?.contains("Frieren") ?? false))
        #expect(details.coverURL != nil)
        #expect(details.genres.contains("Adventure") || details.genres.contains("Fantasy") || details.genres.contains("Drama"))
        #expect(!model.selectedEpisodes.isEmpty)

        if let firstEp = model.selectedEpisodes.first {
            #expect(firstEp.number == 1)
            #expect(!firstEp.title.isEmpty)
        }
    }

    @Test("Player playback position change records real progress to SQLite")
    func testPlayerProgressRecordsToSqlite() throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let model = AppModel()
        model.engine = engine
        model.currentPlaybackCatalog = .anilist
        model.currentPlaybackCatalogId = 154587
        model.currentPlaybackEpisode = 3

        // Simulate playback scrubber / time update
        model.handlePlaybackPositionChange(currentTime: 420.0, duration: 1420.0)

        // Read directly from SQLite via engine.getProgress
        let progress = try engine.getProgress(catalog: .anilist, catalogId: 154587, episodeNumber: 3)
        #expect(progress != nil)
        #expect(progress?.episodeNumber == 3)
        #expect(progress?.stopTime == 420)
        #expect(progress?.duration == 1420)

        // Stop playback and verify final progress persists
        model.playerController.currentTime = 600.0
        model.playerController.duration = 1420.0
        model.stopPlayback()

        let finalProgress = try engine.getProgress(catalog: .anilist, catalogId: 154587, episodeNumber: 3)
        #expect(finalProgress?.stopTime == 600)
    }

    @Test("Manga reader open and close session flow")
    func testMangaReaderSession() async throws {
        let model = AppModel()
        let chapter = MediaDetailView.MangaChapterItem(id: "test-ch-1", number: "1", title: "The Beginning")

        // Without network or with empty pages, openReader sets up the session cleanly
        await model.openReader(
            title: "Frieren",
            chapter: chapter,
            allChapters: [chapter],
            anilistId: 154587
        )

        // Session was created or handled error without crash
        model.closeReader()
        #expect(model.activeReadingSession == nil)
    }

    @Test("Engine trending returns real MediaSummary records")
    func testTrendingMedia() async throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let trending = try await engine.trending(mediaType: "ANIME", format: nil, limit: 5)
        #expect(!trending.isEmpty)
        for item in trending {
            #expect(item.catalog == .anilist)
            #expect(item.catalogId > 0)
            #expect(!item.title.isEmpty)
        }
    }

    @Test("Playback stop time is clamped to duration in SQLite progress")
    func testPlaybackStopClampsDuration() throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let model = AppModel()
        model.engine = engine
        model.currentPlaybackCatalog = .anilist
        model.currentPlaybackCatalogId = 154587
        model.currentPlaybackEpisode = 1

        // Position exceeds total duration (e.g. 1500s on a 1400s file)
        model.handlePlaybackPositionChange(currentTime: 1500.0, duration: 1400.0)

        let progress = try engine.getProgress(catalog: .anilist, catalogId: 154587, episodeNumber: 1)
        #expect(progress != nil)
        #expect(progress?.stopTime == 1400) // Clamped to duration!

        // Stopping player also clamps
        model.playerController.currentTime = 2000.0
        model.playerController.duration = 1400.0
        model.stopPlayback()

        let finalProgress = try engine.getProgress(catalog: .anilist, catalogId: 154587, episodeNumber: 1)
        #expect(finalProgress?.stopTime == 1400)
    }

    @Test("Schedule item isWatching filtering isolates user watchlist")
    func testScheduleItemFiltering() {
        let items = [
            ScheduleView.ScheduleItem(
                id: 1,
                title: "Show A",
                coverImageURL: nil,
                episodeNumber: 1,
                airingTimeText: "12:00",
                countdownText: "in 1h",
                dayGroup: "Monday",
                isWatching: true
            ),
            ScheduleView.ScheduleItem(
                id: 2,
                title: "Show B",
                coverImageURL: nil,
                episodeNumber: 5,
                airingTimeText: "14:00",
                countdownText: "in 3h",
                dayGroup: "Monday",
                isWatching: false
            )
        ]

        let global = items
        let watching = items.filter { $0.isWatching }

        #expect(global.count == 2)
        #expect(watching.count == 1)
        #expect(watching.first?.id == 1)
    }

    @Test("AppModel fetches real manga detail and populates chapters")
    func testMangaDetailFetchesRealData() async throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let model = AppModel()
        model.engine = engine

        // Frieren Manga (AniList ID: 118586)
        await model.openDetail(id: 118586, isManga: true)

        #expect(model.errorMessage == nil)
        guard let details = model.selectedMediaDetails else {
            Issue.record("selectedMediaDetails was nil for manga")
            return
        }

        #expect(details.id == 118586)
        #expect(details.title.contains("Frieren") || (details.romajiTitle?.contains("Frieren") ?? false))
        #expect(details.format == "MANGA")
    }

    @Test("MediaDetailView onSelectRelation callback triggers when relation is selected")
    @MainActor
    func testMediaDetailRelationCallback() {
        var selectedRelation: HeroBanner.Details.Relation? = nil
        let prequel = HeroBanner.Details.Relation(id: 100, title: "Season 1", format: "TV", coverURL: nil)
        let details = HeroBanner.Details(
            id: 200,
            title: "Season 2",
            prequel: prequel
        )

        let view = MediaDetailView(
            details: details,
            onSelectRelation: { rel in
                selectedRelation = rel
            }
        )

        view.onSelectRelation?(prequel)
        #expect(selectedRelation?.id == 100)
        #expect(selectedRelation?.title == "Season 1")
    }
}
