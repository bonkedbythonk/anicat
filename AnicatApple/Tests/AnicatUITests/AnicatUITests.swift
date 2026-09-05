import Testing
import Foundation
#if canImport(AppKit)
import AppKit
#endif
@testable import AnicatUI
import AnicatCoreKit

@Suite("Sumi Ledger & Anime4K Tests")
struct AnicatUITests {
    @Test("Anime4K Preset Shader Count")
    func testPresetShaders() {
        let preset = Anime4KPreset.modeAFast
        #expect(preset.shaderFileNames.count == 6)
        #expect(preset.shaderFileNames.first == "Anime4K_Clamp_Highlights.glsl")
    }

    @Test("Anime4K Single Toggle and 6-Shader Chain Exact Matching")
    func testAnime4KSingleToggle() {
        // Verify official 6-shader chain from Tauri Anicat
        let expectedShaders = [
            "Anime4K_Clamp_Highlights.glsl",
            "Anime4K_Restore_CNN_M.glsl",
            "Anime4K_Upscale_CNN_x2_M.glsl",
            "Anime4K_AutoDownscalePre_x2.glsl",
            "Anime4K_AutoDownscalePre_x4.glsl",
            "Anime4K_Upscale_CNN_x2_S.glsl"
        ]
        #expect(Anime4KPreset.on.shaderFileNames == expectedShaders)
        #expect(Anime4KPreset.off.shaderFileNames.isEmpty)
        #expect(Anime4KPreset.off.resolveMpvShaderString() == "")

        // Verify PlayerController toggle behavior
        let controller = PlayerController(title: "Frieren", episodeNumber: 1)
        controller.isAnime4KEnabled = true
        #expect(controller.activeAnime4KPreset == .on)

        controller.toggleAnime4K()
        #expect(controller.isAnime4KEnabled == false)
        #expect(controller.activeAnime4KPreset == .off)

        controller.cycleAnime4K()
        #expect(controller.isAnime4KEnabled == true)
        #expect(controller.activeAnime4KPreset == .on)
    }

    #if os(macOS)
    // Renders via libmpv's render API into an owned OpenGL context rather
    // than handing mpv a `wid` — see MpvMetalSurface.swift's doc comment.
    // There is no subview reparenting to constrain any more (that was the
    // wid/cocoa-cb design this replaced), so the test now covers what
    // actually matters here: the view is a real, usable OpenGL surface
    // before it's ever attached to a window, and mpv isn't touched until
    // it is (`attachMpv` is only ever called from `viewDidMoveToWindow`).
    @Test("MpvRenderView creates an accelerated OpenGL context before attaching to a window")
    @MainActor
    func testMpvRenderView() {
        let view = MpvRenderView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        #expect(view.window == nil)
        #expect(view.coordinator == nil)
        #expect(view.openGLContext != nil)

        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 720)
        #expect(view.bounds.size == NSSize(width: 1280, height: 720))
    }
    #endif

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
        let configURL = appSupport.appendingPathComponent("Anicat", isDirectory: true).appendingPathComponent("config.json")
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

    @Test("Dismissal hierarchy order: Shortcuts -> Palette -> Player -> Reader -> Detail via handleEscapeKey")
    @MainActor
    func testDismissalHierarchy() {
        let model = AppModel()
        model.activeStreamURL = URL(string: "http://127.0.0.1:8080/stream/1")
        model.activeReadingSession = AppModel.MangaReadingSession(
            title: "Test Manga", chapterTitle: "Ch 1", chapterId: "c1",
            pageURLs: [], chapterIndex: 0, chapters: [], anilistId: nil
        )
        model.paletteOpen = true
        model.shortcutsOpen = true
        model.selectedMediaDetails = HeroBanner.Details(
            id: 1, title: "Test", romajiTitle: nil, bannerURL: nil, coverURL: nil,
            format: "TV", year: 2023, studio: nil, synopsis: nil, genres: [],
            averageScore: nil, nextEpisodeText: nil, status: "FINISHED",
            episodeCount: nil, resumeEpisode: nil, resumeSeconds: nil, prequel: nil, sequel: nil
        )

        // 1. First ESC must dismiss KeyboardShortcutsOverlay if open
        #expect(model.shortcutsOpen == true)
        let handled0 = model.handleEscapeKey()
        #expect(handled0 == true)
        #expect(model.shortcutsOpen == false)
        #expect(model.paletteOpen == true)

        // 2. Second ESC must dismiss CommandPalette if open
        #expect(model.paletteOpen == true)
        let handled1 = model.handleEscapeKey()
        #expect(handled1 == true)
        #expect(model.paletteOpen == false)
        #expect(model.activeStreamURL != nil) // video playback remains undisturbed!

        // 3. Third ESC must dismiss PlayerView
        let handled2 = model.handleEscapeKey()
        #expect(handled2 == true)
        #expect(model.activeStreamURL == nil)
        #expect(model.activeReadingSession != nil)

        // 4. Fourth ESC must dismiss MangaReaderView
        let handled3 = model.handleEscapeKey()
        #expect(handled3 == true)
        #expect(model.activeReadingSession == nil)
        #expect(model.selectedMediaDetails != nil)

        // 5. Fifth ESC must dismiss MediaDetailView
        let handled4 = model.handleEscapeKey()
        #expect(handled4 == true)
        #expect(model.selectedMediaDetails == nil)

        // 6. Sixth ESC has nothing to dismiss, returns false
        let handled5 = model.handleEscapeKey()
        #expect(handled5 == false)
    }

    @Test("KeyboardShortcutsOverlay sections and default state")
    @MainActor
    func testKeyboardShortcutsOverlay() {
        let model = AppModel()
        #expect(model.shortcutsOpen == false)

        model.shortcutsOpen = true
        #expect(model.shortcutsOpen == true)

        #expect(KeyboardShortcutsOverlay.defaultSections.count == 3)
        #expect(KeyboardShortcutsOverlay.defaultSections[0].title == "Navigation")
        #expect(KeyboardShortcutsOverlay.defaultSections[1].title == "Player")
        #expect(KeyboardShortcutsOverlay.defaultSections[2].title == "Manga reader")

        // Verify ESC closes shortcuts
        let handled = model.handleEscapeKey()
        #expect(handled == true)
        #expect(model.shortcutsOpen == false)
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

    @Test("PlayerController autohide state, isMenuOpen, and cancelAutohide")
    func testPlayerControllerAutohideAndMenuState() {
        let controller = PlayerController(title: "Frieren", episodeNumber: 1)
        #expect(controller.areControlsVisible == true)
        #expect(controller.isMenuOpen == false)

        controller.showControlsBriefly()
        #expect(controller.areControlsVisible == true)

        controller.isMenuOpen = true
        #expect(controller.isMenuOpen == true)

        controller.cancelAutohide()
        #expect(controller.areControlsVisible == true)
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

    @Test("Time Formatting 12h and 24h Modes")
    func testTimeFormatting() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 4
        components.hour = 14
        components.minute = 30
        components.second = 0
        let date = calendar.date(from: components)!

        let f24 = SumiTimeFormatter.timeFormatter(timeFormat: "24-hour")
        f24.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(f24.string(from: date) == "14:30")

        let f12 = SumiTimeFormatter.timeFormatter(timeFormat: "12-hour (AM/PM)")
        f12.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(f12.string(from: date) == "2:30 PM")

        let h24 = SumiTimeFormatter.historyDateFormatter(timeFormat: "24-hour")
        h24.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(h24.string(from: date).contains("14:30"))

        let h12 = SumiTimeFormatter.historyDateFormatter(timeFormat: "12-hour (AM/PM)")
        h12.timeZone = TimeZone(secondsFromGMT: 0)!
        #expect(h12.string(from: date).contains("02:30 PM") || h12.string(from: date).contains("2:30 PM"))
    }

    @Test("AniList Outage Detection - Threshold and Reset")
    @MainActor
    func testAniListOutageThresholdAndReset() {
        let model = AppModel()
        #expect(model.isAniListDown == false)

        let networkError = AnicatError.Network(msg: "Connection reset by peer")
        model.recordAniListFailure(networkError)
        #expect(model.isAniListDown == false)
        #expect(model.aniListFailureTimestamps.count == 1)

        model.recordAniListFailure(networkError)
        #expect(model.isAniListDown == false)
        #expect(model.aniListFailureTimestamps.count == 2)

        model.recordAniListFailure(networkError)
        #expect(model.isAniListDown == true)
        #expect(model.aniListFailureTimestamps.count == 3)

        model.recordAniListSuccess()
        #expect(model.isAniListDown == false)
        #expect(model.aniListFailureTimestamps.isEmpty)
    }

    @Test("AniList Outage Detection - Rolling Window Expiration")
    @MainActor
    func testAniListOutageRollingWindowExpiration() {
        let model = AppModel()
        let networkError = AnicatError.Network(msg: "Gateway timeout")

        // Record an error outside the 30-second window
        let oldDate = Date().addingTimeInterval(-35)
        model.recordAniListFailure(networkError, at: oldDate)
        #expect(model.isAniListDown == false)

        // Two current errors + one expired error should not exceed threshold of 3
        let now = Date()
        model.recordAniListFailure(networkError, at: now)
        model.recordAniListFailure(networkError, at: now)
        #expect(model.isAniListDown == false)
        #expect(model.aniListFailureTimestamps.count == 2)

        // Third current error triggers outage
        model.recordAniListFailure(networkError, at: now)
        #expect(model.isAniListDown == true)
    }

    @Test("AniList Outage Detection - Explicit anilist_down Prefix")
    @MainActor
    func testAniListOutageExplicitPrefix() {
        let model = AppModel()
        let outageError = AnicatError.Network(msg: "anilist_down:AniList servers under maintenance")

        model.recordAniListFailure(outageError)
        #expect(model.isAniListDown == true)

        model.recordAniListSuccess()
        #expect(model.isAniListDown == false)
    }

    @Test("AniList Outage Detection - Non-Network Errors Ignored")
    @MainActor
    func testAniListOutageNonNetworkErrorsIgnored() {
        let model = AppModel()
        let notFound = AnicatError.NotFound(msg: "Media not found")
        let storageError = AnicatError.Storage(msg: "Disk write error")

        model.recordAniListFailure(notFound)
        model.recordAniListFailure(storageError)
        #expect(model.isAniListDown == false)
        #expect(model.aniListFailureTimestamps.isEmpty)
    }

    @Test("MediaSkeleton Components and Layout Defaults")
    @MainActor
    func testMediaSkeletonComponents() {
        let cardSkeleton = MediaCardSkeleton()
        _ = cardSkeleton.body

        let gridSkeleton = MediaGridSkeleton()
        #expect(gridSkeleton.count == 12)
        _ = gridSkeleton.body

        let customGrid = MediaGridSkeleton(count: 6)
        #expect(customGrid.count == 6)

        let aliasSkeleton: LibrarySkeleton = MediaGridSkeleton(count: 12)
        #expect(aliasSkeleton.count == 12)

        let rowSkeleton = MediaRowSkeleton(title: "Trending Now")
        #expect(rowSkeleton.title == "Trending Now")
        #expect(rowSkeleton.count == 6)
        _ = rowSkeleton.body

        let customRow = MediaRowSkeleton(title: "Watching", count: 8)
        #expect(customRow.title == "Watching")
        #expect(customRow.count == 8)

        let episodeRow = EpisodeRowSkeleton(isCompact: false)
        _ = episodeRow.body

        let compactEpisodeRow = EpisodeRowSkeleton(isCompact: true)
        _ = compactEpisodeRow.body

        let episodeList = EpisodeListSkeleton(count: 4, isCompact: false)
        #expect(episodeList.count == 4)
        _ = episodeList.body

        let synopsisSkeleton = SynopsisSkeleton()
        _ = synopsisSkeleton.body
    }

    @Test("DetailCache LRU and TTL Automatic Pruning")
    func testDetailCachePruning() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("detail-cache-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let now = Date()
        // File 1: very old (should be purged by TTL)
        let oldURL = tempDir.appendingPathComponent("anime-1.json")
        try "{}".write(to: oldURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-200)], ofItemAtPath: oldURL.path)

        // File 2, 3, 4, 5: fresh (should be capped to maxCount = 2 by LRU)
        for i in 2...5 {
            let u = tempDir.appendingPathComponent("anime-\(i).json")
            try "{}".write(to: u, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(Double(i))], ofItemAtPath: u.path)
        }

        DetailCache.pruneCacheIfNeeded(targetDirectory: tempDir, maxCount: 2, maxTime: 100)

        let remaining = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        #expect(remaining.count == 2)
        #expect(!remaining.contains(where: { $0.lastPathComponent == "anime-1.json" }))
        #expect(remaining.contains(where: { $0.lastPathComponent == "anime-5.json" }))
        #expect(remaining.contains(where: { $0.lastPathComponent == "anime-4.json" }))
    }

    @Test("AppModel closeDetail clears forward stack when closing to home")
    @MainActor
    func testDetailForwardStackRetention() {
        let model = AppModel()
        model.selectedMediaDetails = HeroBanner.Details(
            id: 12345, title: "Test Anime", romajiTitle: nil, bannerURL: nil, coverURL: nil,
            format: "TV", year: 2024, studio: nil, synopsis: nil, genres: [],
            averageScore: nil, nextEpisodeText: nil, status: "RELEASING",
            episodeCount: 12, resumeEpisode: nil, resumeSeconds: nil, prequel: nil, sequel: nil
        )

        #expect(model.canGoForward == false)
        model.closeDetail()

        // Detail is closed (home view active)
        #expect(model.selectedMediaDetails == nil)
        // Closing to home must clear forward stack so home scrolling is never hijacked
        #expect(model.canGoForward == false)
    }
}

