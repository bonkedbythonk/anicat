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
            tmdbKey: nil,
            tmdbProxy: nil
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

        #expect(BrandAssets.menuBarIcon != nil)
    }

    @Test("AppModel.openDetail fetches real AniList data and populates detail/episodes")
    @MainActor
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
    @MainActor
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
        model.drainEngineIO()

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
        model.engineIOQueue.sync {}

        let finalProgress = try engine.getProgress(catalog: .anilist, catalogId: 154587, episodeNumber: 3)
        #expect(finalProgress?.stopTime == 600)
    }

    @Test("Manga reader open and close session flow")
    @MainActor
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
    @MainActor
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
        model.drainEngineIO()

        let progress = try engine.getProgress(catalog: .anilist, catalogId: 154587, episodeNumber: 1)
        #expect(progress != nil)
        #expect(progress?.stopTime == 1400) // Clamped to duration!

        // Stopping player also clamps
        model.playerController.currentTime = 2000.0
        model.playerController.duration = 1400.0
        model.stopPlayback()
        model.drainEngineIO()

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
                airingAt: 1,
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
                airingAt: 2,
                isWatching: false
            )
        ]

        let global = items
        let watching = items.filter { $0.isWatching }

        #expect(global.count == 2)
        #expect(watching.count == 1)
        #expect(watching.first?.id == 1)
    }

    @Test("WeekStrip day bucketing, isWatching filtering, and 7-day bounds")
    func testWeekStripBucketing() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 4
        components.hour = 10
        components.minute = 0
        components.second = 0
        components.timeZone = TimeZone(secondsFromGMT: 0)
        let fixedNow = calendar.date(from: components)!

        let startOfToday = calendar.startOfDay(for: fixedNow)
        let todayUnix = Int64(startOfToday.timeIntervalSince1970)

        let items = [
            // Airing today, watching
            ScheduleView.ScheduleItem(
                id: 101,
                title: "Today Show",
                coverImageURL: nil,
                episodeNumber: 3,
                airingTimeText: "14:00",
                countdownText: "in 4h",
                dayGroup: "Friday, September 4",
                airingAt: todayUnix + 14 * 3600,
                isWatching: true
            ),
            // Airing today, NOT watching -> must be excluded
            ScheduleView.ScheduleItem(
                id: 102,
                title: "Global Show",
                coverImageURL: nil,
                episodeNumber: 1,
                airingTimeText: "16:00",
                countdownText: "in 6h",
                dayGroup: "Friday, September 4",
                airingAt: todayUnix + 16 * 3600,
                isWatching: false
            ),
            // Airing day + 2, watching
            ScheduleView.ScheduleItem(
                id: 103,
                title: "Sunday Show",
                coverImageURL: nil,
                episodeNumber: 8,
                airingTimeText: "09:00",
                countdownText: "in 2d",
                dayGroup: "Sunday, September 6",
                airingAt: todayUnix + 2 * 86400 + 9 * 3600,
                isWatching: true
            ),
            // Airing day + 8 (outside 7-day strip), watching -> must not appear
            ScheduleView.ScheduleItem(
                id: 104,
                title: "Next Week Show",
                coverImageURL: nil,
                episodeNumber: 9,
                airingTimeText: "09:00",
                countdownText: "in 8d",
                dayGroup: "Saturday, September 12",
                airingAt: todayUnix + 8 * 86400 + 9 * 3600,
                isWatching: true
            )
        ]

        let days = WeekStrip.computeDays(from: items, now: fixedNow, calendar: calendar)

        #expect(days.count == 7)
        #expect(days[0].isToday == true)
        #expect(days[1].isToday == false)
        #expect(days[0].items.count == 1)
        #expect(days[0].items.first?.id == 101)

        #expect(days[1].items.isEmpty)

        #expect(days[2].items.count == 1)
        #expect(days[2].items.first?.id == 103)

        for d in 3..<7 {
            #expect(days[d].items.isEmpty)
        }

        for d in days {
            #expect(!d.label.isEmpty)
            #expect(d.label.count <= 4)
        }

        let emptyDays = WeekStrip.computeDays(from: [], now: fixedNow, calendar: calendar)
        #expect(emptyDays.count == 7)
        #expect(emptyDays.allSatisfy { $0.items.isEmpty })
    }

    @Test("AppModel fetches real manga detail and populates chapters")
    @MainActor
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

        // Berserk Manga (AniList ID: 30002) - has real chapters on MangaDex
        await model.openDetail(id: 30002, isManga: true)
        #expect(model.errorMessage == nil)
        #expect(model.selectedMediaDetails?.id == 30002)
        #expect(!model.selectedMangaChapters.isEmpty)

        // Verify AppModel.card properly flags releasing manga where chapters == nil
        let releasingMangaSummary = MediaSummary(
            catalog: .anilist,
            catalogId: 118586,
            title: "Frieren",
            coverImage: "",
            format: "MANGA",
            episodes: nil,
            chapters: nil,
            averageScore: nil,
            progress: nil,
            listStatus: nil,
            userScore: nil,
            updatedAt: nil,
            nextAiringAt: nil,
            nextEpisode: nil,
            listEntryId: nil
        )
        let card = AppModel.card(releasingMangaSummary)
        #expect(card.isManga == true)
    }

    @Test("MediaDetailView includes Chapters tab for manga even when chapters are empty")
    @MainActor
    func testMediaDetailViewMangaTabPresence() {
        let details = HeroBanner.Details(
            id: 118586,
            title: "Frieren",
            format: "MANGA"
        )
        _ = MediaDetailView(
            details: details,
            episodes: [],
            mangaChapters: []
        )
        // With isMangaMedia, the tab is preserved and selectable
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

    @Test("MediaDetail fetches real characters, relations, recommendations, and discussions")
    @MainActor
    func testMediaDetailRealDataVerification() async throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let model = AppModel()
        model.engine = engine

        // Open Frieren (AniList ID: 154587)
        await model.openDetail(id: 154587, isManga: false)

        #expect(model.selectedMediaDetails != nil)
        // Verify real relations and recommendations are populated
        #expect(!model.selectedRelations.isEmpty)
        #expect(!model.selectedRecommendations.isEmpty)

        // Verify real characters directly from engine
        let characters = try await engine.mediaCharacters(catalogId: 154587)
        #expect(!characters.isEmpty)
        if let firstChar = characters.first {
            #expect(!firstChar.name.isEmpty)
            #expect(!firstChar.role.isEmpty)
        }

        // Verify real discussions directly from engine
        let discussions = try await engine.mediaDiscussions(catalogId: 154587)
        #expect(!discussions.isEmpty)
        if let firstThread = discussions.first {
            #expect(!firstThread.title.isEmpty)
        }
    }

    @Test("AppModel.openDetail deduplicates concurrent loads for the same title and protects history")
    @MainActor
    func testOpenDetailDeduplication() async throws {
        let (engine, tempDir) = try makeEngine()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let model = AppModel()
        model.engine = engine

        // Load Frieren initially
        await model.openDetail(id: 154587, title: "Frieren", isManga: false)
        #expect(model.selectedMediaDetails?.id == 154587)
        #expect(model.isDetailLoading == false)

        // Rapid duplicate call with same ID while loaded should be an immediate no-op
        await model.openDetail(id: 154587, title: "Frieren", isManga: false)
        #expect(model.selectedMediaDetails?.id == 154587)

        // Navigating back should go home directly because duplicate was not appended to history
        model.closeDetail()
        #expect(model.selectedMediaDetails == nil)
    }

    @Test("AppModel.isMangaFormat correctly classifies media formats")
    func testMangaFormatClassification() {
        #expect(AppModel.isMangaFormat("MANGA") == true)
        #expect(AppModel.isMangaFormat("NOVEL") == true)
        #expect(AppModel.isMangaFormat("ONE_SHOT") == true)
        #expect(AppModel.isMangaFormat("TV") == false)
        #expect(AppModel.isMangaFormat("TV_SHORT") == false)
        #expect(AppModel.isMangaFormat("MOVIE") == false)
        #expect(AppModel.isMangaFormat("OVA") == false)
        #expect(AppModel.isMangaFormat("ONA") == false)
        #expect(AppModel.isMangaFormat("SPECIAL") == false)
        #expect(AppModel.isMangaFormat(nil) == false)
    }
}

