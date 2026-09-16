import Testing
import Foundation
@testable import AnicatUI

@Suite("Chapter skip windows")
struct PlayerChapterTests {
    @Test("Marker titles classify", arguments: [
        ("OP", SkipKind.opening),
        ("op", SkipKind.opening),
        ("Opening", SkipKind.opening),
        ("OP1", SkipKind.opening),
        ("OP 2", SkipKind.opening),
        ("Intro", SkipKind.opening),
        ("Opening Theme", SkipKind.opening),
        ("NCOP", SkipKind.opening),
        ("ED", SkipKind.ending),
        ("ED 2", SkipKind.ending),
        ("Ending", SkipKind.ending),
        ("Ending Credits", SkipKind.ending),
        ("Outro", SkipKind.ending),
        ("Preview", SkipKind.preview),
        ("Next Episode Preview", SkipKind.preview),
    ])
    func classifies(title: String, expected: SkipKind) {
        #expect(SkipKind.from(chapterTitle: title) == expected)
    }

    /// The negatives are the whole reason this is not a substring match.
    /// "Opening Act" is a real chapter title, and skipping it would jump the
    /// first minutes of the episode.
    @Test("Non-marker titles classify as nothing", arguments: [
        "Opening Act",
        "Episode 1",
        "Part A",
        "Part B",
        "",
        "   ",
        "Chapter 3",
        "The Ending of Everything",
        "Prologue",
        "OP/ED Medley",
    ])
    func rejects(title: String) {
        #expect(SkipKind.from(chapterTitle: title) == nil)
    }

    /// "Intro, OP, Part A" is a real chapter layout: the intro is the cold
    /// open, and auto-skip jumped it along with the song.
    @Test("An Intro beside an explicit OP is the cold open, not a window")
    func introBesideExplicitOpening() {
        let chapters = [
            PlayerChapter(title: "Intro", time: 0),
            PlayerChapter(title: "OP", time: 95),
            PlayerChapter(title: "Part A", time: 185),
            PlayerChapter(title: "ED", time: 1300),
        ]
        let windows = PlayerChapters.skipWindows(chapters: chapters, duration: 1420)
        #expect(windows.map(\.start) == [95, 1300])
        // Alone, the alias still names the opening.
        let alone = PlayerChapters.skipWindows(chapters: [
            PlayerChapter(title: "Intro", time: 0),
            PlayerChapter(title: "Part A", time: 90),
        ], duration: 1420)
        #expect(alone.map(\.start) == [0])
        #expect(SkipKind.from(chapterTitle: "Avant") == nil)
    }

    @Test("AniSkip overrules an Intro chapter it does not overlap")
    @MainActor
    func aniSkipOverrulesIntroAlias() {
        let controller = PlayerController()
        controller.setChapters([
            PlayerChapter(title: "Intro", time: 0),
            PlayerChapter(title: "Part A", time: 80),
        ], duration: 1420)
        #expect(controller.skipWindows.map(\.start) == [0])
        controller.setAniSkipTimes(AniSkipClient.SkipTimes(introStart: 80, introEnd: 170, outroStart: nil, outroEnd: nil))
        #expect(controller.skipWindows.map(\.start) == [80])
        #expect(controller.skipWindows.first?.chapterTitle == "")
        // An AniSkip opening that agrees with the chapter leaves it in place.
        controller.setAniSkipTimes(AniSkipClient.SkipTimes(introStart: 2, introEnd: 85, outroStart: nil, outroEnd: nil))
        #expect(controller.skipWindows.first?.chapterTitle == "Intro")
    }

    @Test("Windows run from each marker to the next chapter")
    func windowsSpanToNextChapter() {
        let chapters = [
            PlayerChapter(title: "Part A", time: 0),
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 150),
            PlayerChapter(title: "Ending", time: 1300),
            PlayerChapter(title: "Preview", time: 1390),
        ]
        let windows = PlayerChapters.skipWindows(chapters: chapters, duration: 1420)
        #expect(windows.count == 3)
        #expect(windows[0] == SkipWindow(start: 60, end: 150, kind: .opening, chapterTitle: "Opening"))
        #expect(windows[1].kind == .ending)
        #expect(windows[1].end == 1390)
        // The last chapter has no next one, so the file's duration bounds it.
        #expect(windows[2].kind == .preview)
        #expect(windows[2].end == 1420)
    }

    @Test("A trailing marker with no known duration yields no window")
    func trailingMarkerNeedsDuration() {
        let chapters = [
            PlayerChapter(title: "Part A", time: 0),
            PlayerChapter(title: "Preview", time: 1390),
        ]
        #expect(PlayerChapters.skipWindows(chapters: chapters, duration: nil).isEmpty)
    }

    /// Some releases place a bare marker to tag a moment rather than to
    /// bound a section; a two-second "window" is a button that does nothing.
    @Test("Markers shorter than the minimum are dropped")
    func dropsTinyWindows() {
        let chapters = [
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 62),
        ]
        #expect(PlayerChapters.skipWindows(chapters: chapters, duration: 1420).isEmpty)
    }

    @Test("Chapters out of file order are sorted before pairing")
    func sortsBeforePairing() {
        let chapters = [
            PlayerChapter(title: "Part B", time: 150),
            PlayerChapter(title: "Opening", time: 60),
        ]
        let windows = PlayerChapters.skipWindows(chapters: chapters, duration: 1420)
        #expect(windows == [SkipWindow(start: 60, end: 150, kind: .opening, chapterTitle: "Opening")])
    }

    @Test("The pill leads the window by two seconds")
    func pillLeadsWindow() {
        let window = SkipWindow(start: 60, end: 150, kind: .opening)
        #expect(!window.isPending(at: 57.9))
        #expect(window.isPending(at: 58.5))
        #expect(window.isPending(at: 149.9))
        #expect(!window.isPending(at: 150))
        #expect(!window.contains(58.5))
        #expect(window.contains(60))
    }

    @Test("The hover tooltip names the chapter the pointer is inside")
    func chapterAtTime() {
        let chapters = [
            PlayerChapter(title: "Part A", time: 0),
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 150),
        ]
        #expect(PlayerChapters.chapter(at: 100, in: chapters)?.title == "Opening")
        #expect(PlayerChapters.chapter(at: 0, in: chapters)?.title == "Part A")
        #expect(PlayerChapters.chapter(at: 5000, in: chapters)?.title == "Part B")
    }
}

@Suite("Skip window sources")
@MainActor
struct SkipSourceTests {
    /// Chapters take precedence, and AniSkip missing (which is what it
    /// reports for most episodes) must not wipe them — the setter used to
    /// assign all four fields unconditionally.
    @Test("An AniSkip miss leaves the chapter windows alone")
    func aniSkipMissKeepsChapters() {
        let controller = PlayerController()
        controller.setChapters([
            PlayerChapter(title: "Part A", time: 0),
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 150),
        ], duration: 1420)
        #expect(controller.introStartTime == 60)
        controller.setAniSkipTimes(nil)
        #expect(controller.introStartTime == 60)
        #expect(controller.introEndTime == 150)
    }

    /// A release that chapters its opening but not its ending is common;
    /// the ending should still come from AniSkip rather than being lost to
    /// the chapter source winning wholesale.
    @Test("AniSkip fills only the kinds chapters did not name")
    func aniSkipFillsGaps() {
        let controller = PlayerController()
        controller.setChapters([
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 150),
        ], duration: 1420)
        controller.setAniSkipTimes(AniSkipClient.SkipTimes(
            introStart: 90, introEnd: 180, outroStart: 1300, outroEnd: 1390
        ))
        #expect(controller.introStartTime == 60)
        #expect(controller.introEndTime == 150)
        #expect(controller.outroStartTime == 1300)
        #expect(controller.skipWindows.count == 2)
    }

    /// `resolveAndPlay` writes the incoming episode's `currentTime` and
    /// `duration` before the load, while `chapters` is still the outgoing
    /// file's until mpv reports the new one. Auto-skipping on that pair seeks
    /// to a window this file does not have, and `loadFile` reads the seeked
    /// position back as `--start` — the episode would open at a timestamp
    /// taken from the previous one's chapter list.
    @Test("Nothing auto-skips while a resolve is in flight")
    func noSkipMidResolve() {
        let controller = PlayerController()
        controller.autoSkipEnabled = true
        controller.setChapters([
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 150),
        ], duration: 1420)
        controller.awaitingNewFile = true
        controller.currentTime = 90
        controller.checkIntroStatus()
        #expect(controller.currentTime == 90)
        #expect(controller.pendingSkipWindow == nil)
        #expect(!controller.isIntroActive)
        // And it resumes the moment the new file lands.
        controller.awaitingNewFile = false
        controller.checkIntroStatus()
        #expect(controller.currentTime == 150)
    }

    @Test("A new file with no chapters drops the previous episode's windows")
    func chaptersClearedPerFile() {
        let controller = PlayerController()
        controller.setChapters([
            PlayerChapter(title: "Opening", time: 60),
            PlayerChapter(title: "Part B", time: 150),
        ], duration: 1420)
        controller.setChapters([], duration: 1420)
        #expect(controller.chapterWindows.isEmpty)
        #expect(controller.introStartTime == nil)
    }
}
