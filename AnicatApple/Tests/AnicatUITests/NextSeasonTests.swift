import Testing
@testable import AnicatUI

@Suite("Next season")
struct NextSeasonTests {
    @Test("Only a finished season with a known total is a finale")
    func finale() {
        #expect(NextSeason.isFinale(episode: 12, total: 12))
        #expect(NextSeason.isFinale(episode: 13, total: 12))
        #expect(!NextSeason.isFinale(episode: 11, total: 12))
        // A caught-up weekly show and a film have no total to finish.
        #expect(!NextSeason.isFinale(episode: 5, total: nil))
        #expect(!NextSeason.isFinale(episode: 1, total: 0))
    }

    @Test("A sequel the viewer has already decided on is not offered")
    func offerable() {
        #expect(NextSeason.isOfferable(listStatus: nil))
        #expect(NextSeason.isOfferable(listStatus: "PLANNING"))
        for status in ["CURRENT", "REPEATING", "COMPLETED", "PAUSED", "DROPPED"] {
            #expect(!NextSeason.isOfferable(listStatus: status))
        }
    }

    @Test("Released sequels go to Watching, unaired ones to Planning")
    func statusToWrite() {
        #expect(NextSeason.statusToWrite(listStatus: nil, isReleased: true) == "CURRENT")
        #expect(NextSeason.statusToWrite(listStatus: "PLANNING", isReleased: true) == "CURRENT")
        #expect(NextSeason.statusToWrite(listStatus: nil, isReleased: false) == "PLANNING")
        #expect(NextSeason.statusToWrite(listStatus: "PLANNING", isReleased: false) == nil)
        #expect(NextSeason.statusToWrite(listStatus: "CURRENT", isReleased: true) == nil)
    }
}
