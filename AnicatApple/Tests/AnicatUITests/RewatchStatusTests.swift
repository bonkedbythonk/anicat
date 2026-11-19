import Testing
@testable import AnicatUI

@Suite("Rewatch status")
@MainActor
struct RewatchStatusTests {
    private func update(_ episode: Int, _ status: String?, listed: Int?, total: Int? = 12) -> (Int, String?) {
        let r = AppModel.listEntryUpdate(episode: episode, watched: true, episodeCount: total,
                                         listStatus: status, listProgress: listed)
        return (r.progress, r.status)
    }

    @Test("Any episode short of the finale on a finished round starts Rewatching")
    func completedStartsRound() {
        #expect(update(1, "COMPLETED", listed: 12) == (1, "REPEATING"))
        #expect(update(3, "COMPLETED", listed: 12) == (3, "REPEATING"))
        // Rewatching picked by hand, progress still at the total.
        #expect(update(1, "REPEATING", listed: 12) == (1, "REPEATING"))
    }

    @Test("Replaying the finale alone leaves Completed alone")
    func finaleReplay() {
        #expect(update(12, "COMPLETED", listed: 12) == (12, "COMPLETED"))
        #expect(!AppModel.beginsRewatch(episode: 12, episodeCount: 12, listStatus: "COMPLETED", listProgress: 12))
    }

    @Test("A rewatch in progress advances, and its last episode completes it")
    func roundInProgress() {
        #expect(update(5, "REPEATING", listed: 4) == (5, nil))
        #expect(update(12, "REPEATING", listed: 11) == (12, "COMPLETED"))
        #expect(!AppModel.beginsRewatch(episode: 5, episodeCount: 12, listStatus: "REPEATING", listProgress: 4))
    }

    @Test("Watching a Paused or Dropped title moves it back to Watching")
    func shelvedResumes() {
        #expect(update(4, "PAUSED", listed: 3) == (4, "CURRENT"))
        #expect(update(4, "DROPPED", listed: 3) == (4, "CURRENT"))
        #expect(update(12, "PAUSED", listed: 11) == (12, "COMPLETED"))
        // Un-checking an episode is not picking the title back up.
        let r = AppModel.listEntryUpdate(episode: 4, watched: false, episodeCount: 12,
                                         listStatus: "PAUSED", listProgress: 4)
        #expect(r.progress == 3 && r.status == nil)
    }

    @Test("Other statuses and unknown totals are unchanged")
    func unchanged() {
        #expect(update(1, nil, listed: nil) == (1, "CURRENT"))
        #expect(update(1, "PLANNING", listed: 0) == (1, "CURRENT"))
        #expect(update(4, "CURRENT", listed: 3) == (4, nil))
        #expect(update(4, "COMPLETED", listed: 12, total: nil) == (4, nil))
        #expect(!AppModel.beginsRewatch(episode: 3, episodeCount: 12, listStatus: "PAUSED", listProgress: 12))
    }
}
