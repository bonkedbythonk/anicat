import Testing
import Foundation
@testable import AnicatUI

@Suite("Playback failure messages")
struct PlaybackFailureTests {
    private func nothingFound(airedRecently: Bool?) -> PlaybackFailure {
        let engine = NSError(domain: "t", code: 1, userInfo: [NSLocalizedDescriptionKey: "No HD torrent found for 'Senjou no Valkyria' episode 1"])
        return PlaybackFailure(engine, catalog: .anilist, episode: 1, airedRecently: airedRecently)
    }

    @Test("Only a new episode is told a release is on its way")
    func nothingFoundDependsOnAirDate() {
        #expect(nothingFound(airedRecently: true).kind == .nothingFound)
        #expect(nothingFound(airedRecently: true).errorDescription?.contains("within a day of airing") == true)
        // A 2009 show was told the same, and no release was ever coming.
        #expect(nothingFound(airedRecently: false).errorDescription?.contains("yet") == false)
        #expect(nothingFound(airedRecently: false).errorDescription?.contains("Nobody is sharing") == true)
        #expect(nothingFound(airedRecently: nil).errorDescription == "No release of episode 1 was found.")
    }
}
