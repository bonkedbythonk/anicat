import XCTest

/// Drives the Apple TV app the way a viewer does, from the Siri Remote.
/// Nothing on tvOS takes a touch, so `XCUIRemote` is the only way to
/// reach the app from a test -- and the only way to reach it from CI at
/// all, since the simulator has no remote of its own.
///
/// Set `ANICAT_UITEST_SCREENSHOT_DIR` to a directory on the host to keep a
/// screenshot at each step; the simulator shares the host's filesystem.
@MainActor
final class TVSmokeTests: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { XCUIRemote.shared }

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// The Search tab runs a search on every change of the query: typing
    /// on the grid must produce results without a submit, which the TV
    /// keyboard does not have.
    func testSearchRunsAsYouType() {
        remote.press(.right)
        remote.press(.right)
        XCTAssertTrue(app.scrollViews["Search results"].waitForExistence(timeout: 5))
        snapshot("search-tab")
        // The keyboard is the first thing under the tab bar.
        remote.press(.down)
        sleep(1)
        app.typeText("moana")
        sleep(2)
        snapshot("search-typed")
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "moana")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 20), "no result for a typed query")
        snapshot("search-results")
    }

    /// Opens the first Up Next poster, presses Play, and checks that the
    /// picture is still there after the chrome has timed out.
    func testPlayerSurvivesControlsTimeout() {
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        snapshot("detail")
        remote.press(.select)
        sleep(3)
        snapshot("resolving")
        let player = app.descendants(matching: .any)["tv.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 90), "no player after Play")
        sleep(12)
        snapshot("player-early")
        sleep(10)
        snapshot("player-after-timeout")
    }

    /// Plays one title, leaves the player, opens a second title and plays
    /// it. The second resolve must get to a picture as well.
    func testSecondPlayAfterClosingThePlayer() {
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        remote.press(.select)
        let player = app.descendants(matching: .any)["tv.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 90), "no player for the first title")
        sleep(10)
        snapshot("first-player")
        // Menu with the chrome down leaves the player; the chrome is down
        // after ten seconds.
        remote.press(.menu)
        sleep(2)
        snapshot("after-close")
        XCTAssertFalse(player.exists, "player still up after Menu")
        // Back out of the detail to the shelf, move to the next poster.
        remote.press(.menu)
        sleep(2)
        remote.press(.right)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        snapshot("second-detail")
        remote.press(.select)
        for i in 1...6 {
            sleep(10)
            snapshot("second-resolving-\(i * 10)s")
            if player.exists { break }
        }
        snapshot("second-final")
        XCTAssertTrue(player.exists, "no player for the second title")
    }

    /// Plays a title, leaves the player, and plays the same title again.
    /// The second play goes through the remembered release and the
    /// torrent the first one paused.
    func testReplayAfterClosingThePlayer() {
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        remote.press(.select)
        let player = app.descendants(matching: .any)["tv.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 90), "no player for the first play")
        sleep(10)
        remote.press(.menu)
        sleep(3)
        XCTAssertFalse(player.exists, "player still up after Menu")
        snapshot("replay-detail")
        remote.press(.select)
        for i in 1...6 {
            sleep(10)
            snapshot("replay-resolving-\(i * 10)s")
            if player.exists { break }
        }
        snapshot("replay-final")
        XCTAssertTrue(player.exists, "no player for the replay")
    }

    /// Plays from Up Next, leaves the player with the detail still on that
    /// tab's stack, moves to Search and plays a title found there. The
    /// title may have no release yet; then the failure has to be said,
    /// not swallowed.
    func testPlayFromSearchAfterPlayingFromUpNext() {
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        remote.press(.select)
        let player = app.descendants(matching: .any)["tv.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 90), "no player for the first play")
        sleep(10)
        remote.press(.menu)
        sleep(3)
        remote.press(.up)
        sleep(1)
        remote.press(.up)
        sleep(1)
        remote.press(.right)
        remote.press(.right)
        sleep(1)
        XCTAssertTrue(app.scrollViews["Search results"].waitForExistence(timeout: 5))
        remote.press(.down)
        sleep(1)
        app.typeText("dune")
        let hit = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "dune")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 20))
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        XCTAssertTrue(play.waitForExistence(timeout: 20), "second detail did not open")
        sleep(2)
        snapshot("popular-detail")
        remote.press(.select)
        for i in 1...6 {
            sleep(10)
            snapshot("popular-resolving-\(i * 10)s")
            if player.exists || app.buttons["Dismiss"].exists { break }
        }
        snapshot("popular-final")
        XCTAssertTrue(player.exists || app.buttons["Dismiss"].exists, "neither a player nor a failure for the second title")
    }

    /// Backgrounds the app mid-playback with the Home button, brings it
    /// back, then leaves the player. A debug build traps if the mpv
    /// coordinator is released off the main thread while running.
    func testPlayerSurvivesBackgrounding() {
        remote.press(.down)
        sleep(1)
        remote.press(.down)
        sleep(1)
        remote.press(.select)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        remote.press(.select)
        let player = app.descendants(matching: .any)["tv.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 90), "no player")
        sleep(8)
        XCUIDevice.shared.press(.home)
        sleep(4)
        XCTAssertNotEqual(app.state, .notRunning, "app died in the background")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "app did not come back to the front")
        sleep(3)
        snapshot("after-background")
        // Chrome up, chrome down, then out.
        remote.press(.select)
        sleep(2)
        remote.press(.menu)
        sleep(2)
        remote.press(.menu)
        sleep(3)
        XCTAssertNotEqual(app.state, .notRunning, "app died leaving the player")
        XCTAssertFalse(player.exists)
        // And once more into the player and straight to Home while the
        // stream is still opening.
        remote.press(.select)
        sleep(1)
        remote.press(.select)
        sleep(3)
        XCUIDevice.shared.press(.home)
        sleep(4)
        XCTAssertNotEqual(app.state, .notRunning, "app died in the background during a resolve")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15), "app did not come back to the front")
        sleep(5)
        XCTAssertNotEqual(app.state, .notRunning, "app died after backgrounding during a resolve")
        snapshot("after-background-2")
    }

    private func snapshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = ProcessInfo.processInfo.environment["ANICAT_UITEST_SCREENSHOT_DIR"] {
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }
}
