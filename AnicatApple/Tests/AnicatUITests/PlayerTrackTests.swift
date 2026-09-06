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

    /// A dual-audio release as they actually ship: one full English track
    /// and one signs-and-songs track, both tagged English.
    private var dualSubtitleRelease: [PlayerTrack] {
        [
            track(id: "1", lang: "eng", title: "Full"),
            track(id: "2", lang: "eng", title: "Signs & Songs"),
        ]
    }

    @Test("Sub lands on the full English track, Dub on the signs one")
    func subDubRoundTrip() {
        let tracks = dualSubtitleRelease
        #expect(PlayerTrack.preferredSubtitle(preferDub: true, tracks: tracks, explicit: nil) == "2")
        // The round trip is the reported bug: back on Sub, the full track
        // has to be re-selected rather than the signs track left in place.
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: tracks, explicit: nil) == "1")
    }

    @Test("a forced track counts as signs even when the title does not say so")
    func forcedIsSigns() {
        let tracks = [
            track(id: "1", lang: "eng"),
            track(id: "2", lang: "eng", forced: true),
        ]
        #expect(PlayerTrack.preferredSubtitle(preferDub: true, tracks: tracks, explicit: nil) == "2")
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: tracks, explicit: nil) == "1")
    }

    @Test("an explicit pick survives a Sub/Dub toggle, Off included")
    func explicitPickWins() {
        let tracks = dualSubtitleRelease + [track(id: "3", lang: "spa")]
        #expect(PlayerTrack.preferredSubtitle(preferDub: true, tracks: tracks, explicit: "3") == "3")
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: tracks, explicit: "3") == "3")
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: tracks, explicit: PlayerTrack.off) == PlayerTrack.off)
        // A remembered id from a release that is no longer loaded means
        // nothing; the language rule takes over rather than setting `sid`
        // to a track this file does not have.
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: tracks, explicit: "9") == "1")
    }

    @Test("nothing suitable leaves the current track alone")
    func noMatchLeavesSubtitlesAlone() {
        // Dub on a release that carries one full English track and no signs
        // track: stripping subtitles here would be worse than keeping them.
        #expect(PlayerTrack.preferredSubtitle(preferDub: true, tracks: [track(id: "1", lang: "eng")], explicit: nil) == nil)
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: [track(id: "1", lang: "spa")], explicit: nil) == nil)
        #expect(PlayerTrack.preferredSubtitle(preferDub: false, tracks: [], explicit: nil) == nil)
    }
}
