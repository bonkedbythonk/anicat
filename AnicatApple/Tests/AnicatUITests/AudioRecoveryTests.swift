import Testing
@testable import AnicatUI

@Suite("Dub and sub recovery")
struct AudioRecoveryTests {
    private func track(_ id: String, _ lang: String?, _ title: String? = nil) -> PlayerTrack {
        PlayerTrack(id: id, lang: lang, title: title, isSelected: false, isForced: false)
    }

    // MARK: Does the file carry the language

    @Test("the Anime Time Director's Cut episode: one Japanese track, so a dub is missing")
    func japaneseOnlyLacksDub() {
        let audio = [track("1", "jpn", "Japanese")]
        #expect(PlayerTrack.lacksWantedAudio(preferDub: true, audio: audio))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: false, audio: audio))
    }

    @Test("a real dual audio file satisfies either preference")
    func dualAudioSatisfiesBoth() {
        let audio = [track("1", "jpn", "Japanese"), track("2", "eng", "English")]
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: audio))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: false, audio: audio))
    }

    // MARK: When the menu needs its own Audio list

    @Test("plain Japanese plus English, and single-track files, leave it to Sub / Dub")
    func plainPairNeedsNoPicker() {
        #expect(!PlayerTrack.needsAudioPicker([]))
        #expect(!PlayerTrack.needsAudioPicker([track("1", "jpn", "Japanese")]))
        #expect(!PlayerTrack.needsAudioPicker([track("1", "jpn"), track("2", "eng")]))
        #expect(!PlayerTrack.needsAudioPicker([track("1", "ja", "Japanese"), track("2", "en", "English Dub")]))
    }

    @Test("two tracks in one language, or a third language, keep the list")
    func realChoiceKeepsPicker() {
        #expect(PlayerTrack.needsAudioPicker([track("1", "jpn"), track("2", "eng"), track("3", "eng", "Dub 5.1")]))
        #expect(PlayerTrack.needsAudioPicker([track("1", "jpn", "Japanese"), track("2", "jpn", "Japanese")]))
        #expect(PlayerTrack.needsAudioPicker([track("1", "jpn"), track("2", "fre", "French")]))
        #expect(PlayerTrack.needsAudioPicker([track("1", nil), track("2", nil)]))
    }

    @Test("a title is read by whole words: French and Commentary are not English")
    func titlesAreMatchedByWord() {
        #expect(PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "jpn"), track("2", nil, "French")]))
        #expect(PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "jpn"), track("2", nil, "Commentary")]))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "jpn"), track("2", nil, "English 5.1")]))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "jpn"), track("2", nil, "Funimation Dub")]))
    }

    @Test("an English-only file lacks the Japanese a sub viewer asked for")
    func englishOnlyLacksSub() {
        let audio = [track("1", "eng", "English")]
        #expect(PlayerTrack.lacksWantedAudio(preferDub: false, audio: audio))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: audio))
    }

    @Test("language is read from the title when the tag is missing, and from a bare dub label")
    func titleFallbacks() {
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", nil, "English 5.1")]))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "und", "Funimation Dub")]))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: false, audio: [track("1", nil, "Japanese")]))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: false, audio: [track("1", "ja", nil)]))
    }

    @Test("it stays silent when it cannot judge")
    func silentWhenUnknown() {
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: []))
        // One track nobody labelled: not evidence of a missing language.
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", nil, nil)]))
        #expect(!PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "und", "")]))
        // Two tracks, neither English and neither labelled: that is a miss.
        #expect(PlayerTrack.lacksWantedAudio(preferDub: true, audio: [track("1", "jpn", nil), track("2", "chi", nil)]))
    }

    // MARK: Retry budget

    private let key = AudioRecovery.Key(catalogId: 15583, episode: 3, preferDub: true)

    @Test("automatic attempts stop at the cap")
    func capsAutomaticAttempts() {
        var recovery = AudioRecovery()
        for _ in 0..<AudioRecovery.maxAttempts {
            let allowed = recovery.begin(key, userInitiated: false)
            #expect(allowed)
        }
        let allowed1 = recovery.begin(key, userInitiated: false)
        #expect(!allowed1)
    }

    @Test("pressing Dub starts a fresh count, and a file with the language clears it")
    func userRequestAndSuccessReset() {
        var recovery = AudioRecovery()
        for _ in 0..<AudioRecovery.maxAttempts { _ = recovery.begin(key, userInitiated: false) }
        let allowed2 = recovery.begin(key, userInitiated: false)
        #expect(!allowed2)
        let allowed3 = recovery.begin(key, userInitiated: true)
        #expect(allowed3, "a new request is allowed3 after the cap")
        recovery.settle(key)
        for _ in 0..<AudioRecovery.maxAttempts { let allowed = recovery.begin(key, userInitiated: false)
 #expect(allowed) }
    }

    @Test("the count says whether a search has already swapped the file")
    func countTracksSwaps() {
        var recovery = AudioRecovery()
        #expect(recovery.count(key) == 0)
        _ = recovery.begin(key, userInitiated: false)
        #expect(recovery.count(key) == 1)
        _ = recovery.begin(key, userInitiated: false)
        #expect(recovery.count(key) == 2)
    }

    @Test("episodes and languages are counted apart")
    func keysAreIndependent() {
        var recovery = AudioRecovery()
        for _ in 0..<AudioRecovery.maxAttempts { _ = recovery.begin(key, userInitiated: false) }
        let allowed4 = recovery.begin(AudioRecovery.Key(catalogId: 15583, episode: 4, preferDub: true), userInitiated: false)
        #expect(allowed4)
        let allowed5 = recovery.begin(AudioRecovery.Key(catalogId: 15583, episode: 3, preferDub: false), userInitiated: false)
        #expect(allowed5)
    }
}
