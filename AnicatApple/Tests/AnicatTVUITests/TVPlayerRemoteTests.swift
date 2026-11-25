import XCTest

/// Walks the player through every remote input `XCUIRemote` can send, on a
/// local file (`ANICAT_DEBUG_PLAY_FILE`), so no AniList, torrent or progress
/// write is involved. Needs a Debug build: the hook is compiled out of
/// Release.
///
///   ANICAT_UITEST_PLAY_FILE=/abs/clip.mkv ANICAT_UITEST_SCREENSHOT_DIR=/abs/dir \
///   xcodebuild test -scheme AnicatTV -only-testing AnicatTVUITests/TVPlayerRemoteTests ...
///
/// Each step is written with a timestamp to `steps.txt` in the screenshot
/// directory, to line up against the app's `[remote]` log lines. Swipes on
/// the touch surface cannot be sent from here: `XCUIRemote` has buttons only.
@MainActor
final class TVPlayerRemoteTests: XCTestCase {
    private var app: XCUIApplication!
    private var remote: XCUIRemote { XCUIRemote.shared }
    private var dir: URL? {
        ProcessInfo.processInfo.environment["ANICAT_UITEST_SCREENSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        let file = try XCTUnwrap(env["ANICAT_UITEST_PLAY_FILE"], "set ANICAT_UITEST_PLAY_FILE")
        app = XCUIApplication()
        app.launchEnvironment["ANICAT_DEBUG_PLAY_FILE"] = file
        app.launch()
    }

    func testRemoteWalkthrough() {
        let player = app.descendants(matching: .any)["tv.player"]
        XCTAssertTrue(player.waitForExistence(timeout: 30), "no player for the debug file")
        step("player up")
        sleep(4)
        shot("01-start")

        // Chrome times out, focus goes to the invisible surface.
        sleep(10)
        step("chrome should be down")
        shot("02-chrome-down")

        // Edge clicks with the chrome down: quiet seeks, thin bar.
        press(.right, "edge right (chrome down)")
        sleep(1)
        shot("03-after-right")
        press(.left, "edge left (chrome down)")
        sleep(3)

        // A quick burst escalates the step.
        step("burst right x4")
        for _ in 0..<4 { remote.press(.right); usleep(150_000) }
        sleep(3)
        shot("04-after-burst")

        // Back with only the thin seek bar up must not close the player.
        press(.right, "edge right before Back")
        usleep(500_000)
        press(.menu, "Back with seek bar up")
        sleep(2)
        XCTAssertTrue(player.exists, "Back on the seek bar closed the player")
        sleep(2)

        // Holds.
        step("hold right 2 s")
        remote.press(.right, forDuration: 2)
        sleep(3)
        step("hold left 1.5 s")
        remote.press(.left, forDuration: 1.5)
        sleep(3)
        shot("05-after-holds")

        // Press on the picture only brings the chrome up; the next press,
        // with the chrome up, pauses and the one after plays.
        press(.select, "select on surface (show chrome)")
        sleep(2)
        shot("06-chrome-shown")
        press(.select, "select with chrome up (pause)")
        sleep(2)
        shot("06b-paused")
        press(.select, "select with chrome up (play)")
        sleep(2)
        press(.left, "edge left on timeline")
        sleep(1)
        press(.right, "edge right on timeline")
        sleep(2)
        shot("07-timeline-clicks")

        // Play/Pause button, twice.
        press(.playPause, "Play/Pause (pause)")
        sleep(2)
        press(.playPause, "Play/Pause (play)")
        sleep(2)

        // Back puts the chrome away, the player stays.
        press(.menu, "Back with chrome up")
        sleep(3)
        XCTAssertTrue(player.exists, "Back with the chrome up closed the player")
        shot("08-chrome-hidden")

        // Up brings the chrome with Play focused; walk the transport row.
        // The chrome hides 3 s after the last focus move, so keep moving.
        press(.up, "up (show chrome)")
        usleep(800_000)
        press(.right, "right (to forward)")
        usleep(600_000)
        shot("09-focus-forward")
        press(.select, "select forward +10")
        usleep(800_000)
        press(.left, "left (to play)")
        usleep(500_000)
        press(.left, "left (to back)")
        usleep(500_000)
        press(.select, "select back -10")
        usleep(800_000)
        step("right x4 (to options)")
        for _ in 0..<4 { remote.press(.right); usleep(400_000) }
        shot("10-focus-end")
        press(.menu, "Back (hide chrome)")
        sleep(3)
        XCTAssertTrue(player.exists, "Back with the chrome up closed the player")

        // Down from the surface opens the options panel; Back closes it only.
        press(.down, "down (options panel)")
        sleep(3)
        shot("11-options")
        press(.menu, "Back (close options)")
        sleep(3)
        XCTAssertTrue(player.exists, "Back on the options panel closed the player")
        shot("12-after-options")

        // Background and return mid-play.
        step("home")
        XCUIDevice.shared.press(.home)
        sleep(4)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15))
        step("back in front")
        sleep(3)
        shot("13-after-background")
        // Back from the background paused, chrome up: play, let it hide.
        press(.playPause, "Play/Pause after return")
        sleep(6)
        shot("13b-playing-again")

        // Out: chrome down, then Back leaves.
        press(.menu, "Back to leave")
        sleep(3)
        shot("14-after-leave")
        XCTAssertFalse(player.exists, "Back with the chrome down did not close the player")
        XCTAssertNotEqual(app.state, .notRunning, "app died leaving the player")
    }

    private func press(_ button: XCUIRemote.Button, _ name: String) {
        step(name)
        remote.press(button)
    }

    private func step(_ name: String) {
        guard let dir else { return }
        let line = String(format: "%.3f %@\n", Date().timeIntervalSince1970, name)
        let url = dir.appendingPathComponent("steps.txt")
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    private func shot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir {
            try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
