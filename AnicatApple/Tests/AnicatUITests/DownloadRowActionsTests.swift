import Testing
import Foundation
@testable import AnicatUI

@Suite("Downloads row actions")
struct DownloadRowActionsTests {
    typealias State = MediaDetailView.EpisodeDownloadState

    @Test("A download in flight offers no Remove, because the poll would put the row straight back")
    func downloadingIsNotRemovable() {
        #expect(DownloadsView.isRemovable(.downloading(percent: 0)) == false)
        #expect(DownloadsView.isRemovable(.downloading(percent: 99.9)) == false)
    }

    @Test("Every state the poll loop has stopped at is removable")
    func terminalStatesAreRemovable() {
        #expect(DownloadsView.isRemovable(.notStarted))
        #expect(DownloadsView.isRemovable(.done(path: "/tmp/ep1.mkv")))
        #expect(DownloadsView.isRemovable(.failed(message: "no seeders")))
    }

    @Test("Play and Reveal are offered only where there is a file to act on")
    func donePathOnlyForFinishedRows() {
        #expect(DownloadsView.donePath(.done(path: "/tmp/ep1.mkv")) == "/tmp/ep1.mkv")
        #expect(DownloadsView.donePath(.notStarted) == nil)
        #expect(DownloadsView.donePath(.downloading(percent: 50)) == nil)
        #expect(DownloadsView.donePath(.failed(message: "no seeders")) == nil)
    }
}
