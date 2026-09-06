import Testing
import Foundation
@testable import AnicatUI

@Suite("Player track pickers")
struct PlayerTrackTests {
    private func track(
        id: String = "1",
        lang: String? = nil,
        title: String? = nil,
        selected: Bool = false,
        forced: Bool = false
    ) -> PlayerTrack {
        PlayerTrack(id: id, lang: lang, title: title, isSelected: selected, isForced: forced)
    }

    @Test("a known ISO code is spelled out, an unknown one is shown raw")
    func languageNames() {
        #expect(PlayerTrack.languageName("eng") == "English")
        #expect(PlayerTrack.languageName("JPN") == "Japanese")
        #expect(PlayerTrack.languageName("ja") == "Japanese")
        // Matroska's bibliographic three-letter codes, the ones
        // `Locale.localizedString(forLanguageCode:)` does not map.
        #expect(PlayerTrack.languageName("ger") == "German")
        #expect(PlayerTrack.languageName("chi") == "Chinese")
        #expect(PlayerTrack.languageName("qqq") == "qqq")
    }

    @Test("the row label pairs the language with the track title")
    func labels() {
        #expect(track(lang: "eng", title: "Full").label == "English (Full)")
        #expect(track(lang: "eng", title: "Signs & Songs").label == "English (Signs & Songs)")
        #expect(track(lang: "jpn").label == "Japanese")
        // A track tagged with neither is still selectable, so it has to say
        // something a viewer can tell apart from the next one.
        #expect(track(id: "3", title: "  ").label == "Track 3")
        #expect(track(id: PlayerTrack.off).label == "Off")
    }
}
