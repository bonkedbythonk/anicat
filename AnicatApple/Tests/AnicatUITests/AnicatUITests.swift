import Testing
import Foundation
@testable import AnicatUI

@Suite("Sumi Ledger & Anime4K Tests")
struct AnicatUITests {
    @Test("Anime4K Preset Shader Count")
    func testPresetShaders() {
        let preset = Anime4KPreset.modeAFast
        #expect(preset.shaderFileNames.count == 6)
        #expect(preset.shaderFileNames.first == "Anime4K_Clamp_Highlights.glsl")
    }

    @Test("Sumi Ledger Tokens")
    func testThemeTokens() {
        #expect(SumiTheme.radiusMd == 10)
        #expect(SumiTheme.spaceLg == 24)
    }

    @Test("Sidebar NavSection Shortcuts Mapping")
    func testNavSectionShortcuts() {
        #expect(SidebarView.NavSection.fromNumberKey(1) == .upNext)
        #expect(SidebarView.NavSection.fromNumberKey(2) == .schedule)
        #expect(SidebarView.NavSection.fromNumberKey(3) == .library)
        #expect(SidebarView.NavSection.fromNumberKey(4) == .manga)
        #expect(SidebarView.NavSection.fromNumberKey(5) == .novels)
        #expect(SidebarView.NavSection.fromNumberKey(6) == .search)
        #expect(SidebarView.NavSection.fromNumberKey(7) == .history)
        #expect(SidebarView.NavSection.fromNumberKey(8) == .settings)
        #expect(SidebarView.NavSection.fromNumberKey(9) == .downloads)
        #expect(SidebarView.NavSection.fromNumberKey(0) == nil)
        #expect(SidebarView.NavSection.fromNumberKey(10) == nil)

        #expect(SidebarView.NavSection.fromLetterKey("h") == .upNext)
        #expect(SidebarView.NavSection.fromLetterKey("H") == .upNext)
        #expect(SidebarView.NavSection.fromLetterKey("l") == .library)
        #expect(SidebarView.NavSection.fromLetterKey("m") == .manga)
        #expect(SidebarView.NavSection.fromLetterKey("n") == .novels)
        #expect(SidebarView.NavSection.fromLetterKey("d") == .downloads)
        #expect(SidebarView.NavSection.fromLetterKey("z") == nil)
    }

    @Test("AniList Token Local Keychain & Config.json Persistence")
    func testTokenPersistence() {
        let service = iCloudSyncService.shared
        let originalToken = service.getAniListToken()
        defer {
            if let orig = originalToken {
                _ = service.saveAniListToken(orig)
            } else {
                service.deleteAniListToken()
            }
        }

        let testToken = "test_oauth_token_12345"
        let saved = service.saveAniListToken(testToken)
        #expect(saved)

        let retrieved = service.getAniListToken()
        #expect(retrieved == testToken)

        // Verify config.json was created
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let configURL = appSupport.appendingPathComponent("AniCat", isDirectory: true).appendingPathComponent("config.json")
        #expect(FileManager.default.fileExists(atPath: configURL.path))

        // Clean up
        service.deleteAniListToken()
        #expect(service.getAniListToken() == nil)
    }

    @Test("AppModel.resolveAndPlay error propagation and player configuration")
    func testResolveAndPlayErrorAndConfiguration() async {
        let model = AppModel()
        // Engine is nil, resolveAndPlay MUST throw error, not silently succeed or swallow
        do {
            _ = try await model.resolveAndPlay(catalogId: 12345, episode: 1, title: "Test Anime")
            Issue.record("Expected error when engine is nil")
        } catch {
            #expect(error.localizedDescription.contains("Engine not initialized"))
        }

        #expect(model.playerController.title == "Test Anime")
        #expect(model.playerController.episodeNumber == 1)
    }

    @Test("MediaDetailView onClose callback triggers")
    @MainActor
    func testMediaDetailViewOnClose() {
        var closed = false
        let details = HeroBanner.Details(
            id: 154587,
            title: "Frieren",
            romajiTitle: nil,
            bannerURL: nil,
            coverURL: nil,
            format: "TV",
            year: 2023,
            studio: "Madhouse",
            synopsis: "Test synopsis",
            genres: ["Adventure"],
            averageScore: 90,
            nextEpisodeText: nil,
            status: "FINISHED",
            episodeCount: 28,
            resumeEpisode: 1,
            resumeSeconds: 100,
            prequel: nil,
            sequel: nil
        )

        let detailView = MediaDetailView(
            details: details,
            episodes: [],
            mangaChapters: [],
            characters: [],
            onClose: {
                closed = true
            }
        )

        detailView.onClose()
        #expect(closed == true)
    }

    @Test("Dismissal hierarchy order: Palette -> Player -> Reader -> Detail via handleEscapeKey")
    @MainActor
    func testDismissalHierarchy() {
        let model = AppModel()
        model.activeStreamURL = URL(string: "http://127.0.0.1:8080/stream/1")
        model.activeReadingSession = AppModel.MangaReadingSession(
            title: "Test Manga", chapterTitle: "Ch 1", chapterId: "c1",
            pageURLs: [], chapterIndex: 0, chapters: [], anilistId: nil
        )
        model.paletteOpen = true
        model.selectedMediaDetails = HeroBanner.Details(
            id: 1, title: "Test", romajiTitle: nil, bannerURL: nil, coverURL: nil,
            format: "TV", year: 2023, studio: nil, synopsis: nil, genres: [],
            averageScore: nil, nextEpisodeText: nil, status: "FINISHED",
            episodeCount: nil, resumeEpisode: nil, resumeSeconds: nil, prequel: nil, sequel: nil
        )

        // 1. First ESC must dismiss CommandPalette if open
        #expect(model.paletteOpen == true)
        let handled1 = model.handleEscapeKey()
        #expect(handled1 == true)
        #expect(model.paletteOpen == false)
        #expect(model.activeStreamURL != nil) // video playback remains undisturbed!

        // 2. Second ESC must dismiss PlayerView
        let handled2 = model.handleEscapeKey()
        #expect(handled2 == true)
        #expect(model.activeStreamURL == nil)
        #expect(model.activeReadingSession != nil)

        // 3. Third ESC must dismiss MangaReaderView
        let handled3 = model.handleEscapeKey()
        #expect(handled3 == true)
        #expect(model.activeReadingSession == nil)
        #expect(model.selectedMediaDetails != nil)

        // 4. Fourth ESC must dismiss MediaDetailView
        let handled4 = model.handleEscapeKey()
        #expect(handled4 == true)
        #expect(model.selectedMediaDetails == nil)

        // 5. Fifth ESC has nothing to dismiss, returns false
        let handled5 = model.handleEscapeKey()
        #expect(handled5 == false)
    }

    @Test("PlayerController seeking and play/pause callbacks trigger correctly")
    func testPlayerControllerSeekingAndPausing() {
        let controller = PlayerController(title: "Frieren", episodeNumber: 1)
        controller.duration = 1440.0 // 24 minutes

        final class CallbackBox: @unchecked Sendable {
            var soughtPosition: Double?
            var pausedState: Bool?
        }
        let box = CallbackBox()

        controller.onSeek = { pos in
            box.soughtPosition = pos
        }

        controller.onSetPause = { paused in
            box.pausedState = paused
        }

        // Test seek(to:)
        controller.seek(to: 120.0)
        #expect(controller.currentTime == 120.0)
        #expect(box.soughtPosition == 120.0)

        // Test seekRelative(by: +15)
        controller.seekRelative(by: 15.0)
        #expect(controller.currentTime == 135.0)
        #expect(box.soughtPosition == 135.0)

        // Test seekRelative(by: -30)
        controller.seekRelative(by: -30.0)
        #expect(controller.currentTime == 105.0)
        #expect(box.soughtPosition == 105.0)

        // Test togglePlayPause()
        #expect(controller.isPlaying == true)
        controller.togglePlayPause()
        #expect(controller.isPlaying == false)
        #expect(box.pausedState == true)

        controller.play()
        #expect(controller.isPlaying == true)
        #expect(box.pausedState == false)

        controller.pause()
        #expect(controller.isPlaying == false)
        #expect(box.pausedState == true)
    }

    @Test("AppModel.navigate(to:) clears overlays and switches nav section")
    @MainActor
    func testAppModelNavigate() {
        let model = AppModel()
        model.activeStreamURL = URL(string: "http://127.0.0.1:8080/stream/1")
        model.activeReadingSession = AppModel.MangaReadingSession(
            title: "Test Manga", chapterTitle: "Ch 1", chapterId: "c1",
            pageURLs: [], chapterIndex: 0, chapters: [], anilistId: nil
        )
        model.selectedMediaDetails = HeroBanner.Details(
            id: 1, title: "Test", romajiTitle: nil, bannerURL: nil, coverURL: nil,
            format: "TV", year: 2023, studio: nil, synopsis: nil, genres: [],
            averageScore: nil, nextEpisodeText: nil, status: "FINISHED",
            episodeCount: nil, resumeEpisode: nil, resumeSeconds: nil, prequel: nil, sequel: nil
        )

        model.navigate(to: .library)
        #expect(model.currentNavSection == .library)
        #expect(model.activeStreamURL == nil)
        #expect(model.activeReadingSession == nil)
        #expect(model.selectedMediaDetails == nil)
    }
}
