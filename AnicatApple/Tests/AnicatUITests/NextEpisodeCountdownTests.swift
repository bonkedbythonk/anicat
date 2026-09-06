import Testing
import Foundation
@testable import AnicatUI

/// `#expect` cannot take a mutating call directly (the macro binds its
/// operand immutably), so every transition below is made on its own line and
/// the result is what gets asserted.
@Suite("Next-episode countdown")
struct NextEpisodeCountdownTests {
    @Test("Counts down to a single fire")
    func firesOnce() {
        var countdown = NextEpisodeCountdown()
        let armed = countdown.arm(at: 1300)
        #expect(armed)
        #expect(countdown.isVisible)
        let early = countdown.advance(to: 1304, duration: 1440)
        #expect(!early)
        #expect(countdown.remaining(at: 1304) == 4)
        let fired = countdown.advance(to: 1308, duration: 1440)
        #expect(fired)
        #expect(countdown.phase == .fired)
        // The tick that expires it is the only one that fires: without this
        // every later position tick would start another episode.
        let again = countdown.advance(to: 1309, duration: 1440)
        #expect(!again)
    }

    @Test("Arming is once per episode")
    func armsOnce() {
        var countdown = NextEpisodeCountdown()
        let first = countdown.arm(at: 1300)
        #expect(first)
        let second = countdown.arm(at: 1305)
        #expect(!second)
        #expect(countdown.remaining(at: 1305) == 3)
    }

    /// The rule the card exists for: a viewer who said no once should not
    /// have to say it again forty seconds later.
    @Test("Cancel is final for this episode")
    func cancelNeverRearms() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1300)
        countdown.cancel()
        #expect(countdown.phase == .cancelled)
        #expect(!countdown.isVisible)
        let rearmed = countdown.arm(at: 1350)
        #expect(!rearmed)
        let fired = countdown.advance(to: 1400, duration: 1440)
        #expect(!fired)
        // Still resolved, which is what keeps AppModel's own end-of-episode
        // auto-next from firing on top of the cancel.
        #expect(countdown.isResolved)
    }

    @Test("Cancel does nothing to a countdown that never armed")
    func cancelBeforeArmIsInert() {
        var countdown = NextEpisodeCountdown()
        countdown.cancel()
        #expect(countdown.phase == .idle)
        #expect(!countdown.isResolved)
        let armed = countdown.arm(at: 1300)
        #expect(armed)
    }

    @Test("Play now fires immediately and only once")
    func playNowFiresOnce() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1300)
        let played = countdown.playNow()
        #expect(played)
        #expect(countdown.phase == .fired)
        let twice = countdown.playNow()
        #expect(!twice)
        let expired = countdown.advance(to: 1400, duration: 1440)
        #expect(!expired)
    }

    @Test("Play now does nothing while no card is up")
    func playNowNeedsACard() {
        var countdown = NextEpisodeCountdown()
        let played = countdown.playNow()
        #expect(!played)
        #expect(countdown.phase == .idle)
    }

    /// A seek backwards moves the position behind the arming point; the
    /// countdown must read as full rather than as more than full.
    @Test("Remaining is clamped both ways")
    func remainingClamps() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1300)
        #expect(countdown.remaining(at: 1200) == NextEpisodeCountdown.seconds)
        #expect(countdown.elapsedFraction(at: 1200) == 0)
        #expect(countdown.remaining(at: 1400) == 0)
        #expect(countdown.elapsedFraction(at: 1304) == 0.5)
    }

    @Test("A resolved countdown has nothing left to show")
    func resolvedShowsNothing() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1300)
        countdown.cancel()
        #expect(countdown.remaining(at: 1302) == 0)
    }

    /// Armed at the end of the file there are no position-seconds left to
    /// count with, and without this the card would sit at eight forever with
    /// `isResolved` true — which also suppresses AppModel's own
    /// end-of-episode auto-next.
    @Test("The end of the file expires it on the spot")
    func endOfFileExpires() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1440)
        let fired = countdown.advance(to: 1440, duration: 1440)
        #expect(fired)
    }

    @Test("An unknown duration never counts as the end of the file")
    func unknownDurationDoesNotExpire() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1440)
        let fired = countdown.advance(to: 1440, duration: 0)
        #expect(!fired)
    }

    @Test("Reset returns it to a fresh episode's state")
    func resetClears() {
        var countdown = NextEpisodeCountdown()
        countdown.arm(at: 1300)
        countdown.cancel()
        countdown.reset()
        #expect(countdown.phase == .idle)
        #expect(!countdown.isResolved)
        let armed = countdown.arm(at: 10)
        #expect(armed)
    }
}

/// `PlayerController`'s callbacks are `@Sendable`, so a test that watches one
/// fire needs somewhere to record it that a `@Sendable` closure may write to.
private final class Flag: @unchecked Sendable {
    var value = false
}

@Suite("Countdown arming from playback")
@MainActor
struct CountdownArmingTests {
    private func makeController(nextEpisode: Bool) -> PlayerController {
        let controller = PlayerController()
        controller.duration = 1440
        controller.autoPlayNextEnabled = true
        controller.autoSkipEnabled = false
        controller.hasNextEpisode = nextEpisode
        return controller
    }

    @Test("With no outro window it arms in the last thirty seconds")
    func armsOnTail() {
        let controller = makeController(nextEpisode: true)
        controller.currentTime = 1400
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.phase == .idle)
        controller.currentTime = 1411
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.isVisible)
    }

    @Test("An outro window arms it at the window's start")
    func armsOnOutro() {
        let controller = makeController(nextEpisode: true)
        controller.setAniSkipTimes(AniSkipClient.SkipTimes(
            introStart: nil, introEnd: nil, outroStart: 1300, outroEnd: 1390
        ))
        controller.currentTime = 1299
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.phase == .idle)
        controller.currentTime = 1301
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.isVisible)
    }

    /// The default configuration on a chaptered release: auto-skip jumps the
    /// ending to the end of the file, and the countdown has to resolve in
    /// that same pass. Anything else leaves auto-next never firing at all,
    /// because a counting card suppresses AppModel's own end-of-episode path.
    @Test("An ending that runs to the end of the file still advances")
    func chapteredEndingStillAdvances() {
        let controller = makeController(nextEpisode: true)
        let advanced = Flag()
        controller.onNextEpisode = { advanced.value = true }
        controller.autoSkipEnabled = true
        controller.setChapters([
            PlayerChapter(title: "Part A", time: 0),
            PlayerChapter(title: "Ending", time: 1300),
        ], duration: 1440)
        controller.currentTime = 1301
        controller.checkIntroStatus()
        #expect(controller.currentTime == 1440)
        #expect(advanced.value)
        #expect(controller.nextEpisodeCountdown.phase == .fired)
    }

    @Test("Nothing arms behind a mini-player")
    func miniPlayerDoesNotArm() {
        let controller = makeController(nextEpisode: true)
        controller.isMiniPlayerActive = true
        controller.currentTime = 1420
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.phase == .idle)
    }

    @Test("Nothing arms on the last episode")
    func lastEpisodeDoesNotArm() {
        let controller = makeController(nextEpisode: false)
        controller.currentTime = 1420
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.phase == .idle)
    }

    @Test("Nothing arms with auto-play next off")
    func autoPlayOffDoesNotArm() {
        let controller = makeController(nextEpisode: true)
        controller.autoPlayNextEnabled = false
        controller.currentTime = 1420
        controller.checkIntroStatus()
        #expect(controller.nextEpisodeCountdown.phase == .idle)
    }
}
