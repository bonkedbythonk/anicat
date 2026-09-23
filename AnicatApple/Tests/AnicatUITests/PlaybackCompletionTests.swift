import Testing
import Foundation
@testable import AnicatUI

/// A stream that never played a frame must never read as a finished episode.
/// On 2026-09-23 a dead Buddy Daddies 03 on the simulator was recorded 1440
/// of 1440, completed, and moved the owner's AniList progress: the resolve had
/// written a position into `currentTime` that mpv never reached.
@MainActor
@Suite("Playback completion")
struct PlaybackCompletionTests {
    @Test("End of file with no real playback is a dead stream, whatever currentTime says")
    func deadStreamIsNotAnEnd() {
        let controller = PlayerController()
        var failure: String?
        var positions: [Double] = []
        controller.onPlaybackFailed = { failure = $0 }
        controller.onPositionChange = { time, _ in positions.append(time) }
        controller.duration = 1440
        controller.currentTime = 1440

        controller.handleEndOfFile()

        #expect(failure != nil)
        #expect(positions.isEmpty, "an end with no playback must not reach the completion rules")
    }

    @Test("A stall at the resume point counts as nothing played")
    func stallAtResumePoint() {
        let controller = PlayerController()
        controller.duration = 1440
        controller.notePlayedPosition(245)
        controller.notePlayedPosition(245)
        #expect(controller.secondsActuallyPlayed == 0)
        var failure: String?
        controller.onPlaybackFailed = { failure = $0 }
        controller.handleEndOfFile()
        #expect(failure != nil)
    }

    @Test("A file played to its end still finishes")
    func realEndFinishes() {
        let controller = PlayerController()
        var failure: String?
        var positions: [Double] = []
        controller.onPlaybackFailed = { failure = $0 }
        controller.onPositionChange = { time, _ in positions.append(time) }
        controller.duration = 1440
        controller.notePlayedPosition(0)
        controller.notePlayedPosition(1400)
        controller.currentTime = 1400

        controller.handleEndOfFile()

        #expect(failure == nil)
        #expect(positions.last == 1440)
        #expect(controller.secondsActuallyPlayed == 1400)
    }

    @Test("A new file starts with nothing played")
    func resetClearsTheSpan() {
        let controller = PlayerController()
        controller.notePlayedPosition(10)
        controller.notePlayedPosition(900)
        controller.resetPlayedSpan()
        #expect(controller.secondsActuallyPlayed == 0)
        #expect(controller.playedFrom == nil)
    }
}
