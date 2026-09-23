import Testing
import Foundation
@testable import AnicatUI

@Suite("Chapter predownload selection")
struct ChapterPredownloadTests {
    private func chapters(_ numbers: [String]) -> [MediaDetailView.MangaChapterItem] {
        numbers.enumerated().map { MediaDetailView.MangaChapterItem(id: "c\($0.offset)", number: $0.element, title: "") }
    }

    private func pick(_ numbers: [String], after progress: Double, count: Int = 2) -> [String] {
        AppModel.chaptersToPredownload(chapters(numbers), after: progress, count: count).map(\.number)
    }

    @Test("The next chapters after progress, in reading order whatever the feed order")
    func nextInOrder() {
        #expect(pick(["1", "2", "3", "4", "5"], after: 2) == ["3", "4"])
        #expect(pick(["5", "4", "3", "2", "1"], after: 2) == ["3", "4"])
    }

    @Test("A caught-up title fetches nothing")
    func caughtUp() {
        #expect(pick(["1", "2", "3"], after: 3).isEmpty)
        #expect(pick([], after: 0).isEmpty)
    }

    @Test("Nothing read yet starts at the first chapter")
    func fromTheStart() {
        #expect(pick(["1", "2", "3"], after: 0) == ["1", "2"])
    }

    @Test("A fractional chapter after progress counts as unread")
    func fractional() {
        #expect(pick(["10", "10.5", "11"], after: 10) == ["10.5", "11"])
    }

    @Test("Unparseable numbers are skipped and duplicate numbers count once")
    func oddRows() {
        #expect(pick(["Oneshot", "3", "3", "4"], after: 2) == ["3", "4"])
        let first = AppModel.chaptersToPredownload(chapters(["3", "3"]), after: 2, count: 2)
        #expect(first.map(\.id) == ["c0"])
    }
}
