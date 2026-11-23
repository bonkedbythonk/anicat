import Testing
@testable import AnicatUI

@MainActor
struct SeekLandingTests {
    @Test func positionsFromBeforeASeekAreHeldBackUntilItLands() {
        let controller = PlayerController()
        controller.duration = 1440
        #expect(controller.acceptsPosition(300))
        controller.seek(to: 81.3)
        #expect(controller.currentTime == 81.3)
        // mpv still on the old frames.
        #expect(!controller.acceptsPosition(300.1))
        #expect(!controller.acceptsPosition(90.5))
        #expect(controller.acceptsPosition(81.4))
        // Landed: anything goes again.
        #expect(controller.acceptsPosition(300))
    }

    @Test func aNewFileDropsASeekStillInFlight() {
        let controller = PlayerController()
        controller.duration = 1440
        controller.seek(to: 600)
        controller.awaitingNewFile = true
        #expect(controller.acceptsPosition(0))
    }
}
