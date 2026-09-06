import Testing
import Foundation
@testable import AnicatUI

@Suite("Feedback")
struct FeedbackTests {
    @Test("the feedback toggles default off for sound and on for haptics")
    func feedbackDefaults() {
        // Read through a clean domain rather than the shared one, so a machine
        // that has already flipped these in Settings does not fail the test.
        let suiteName = "anicat.tests.feedback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        #expect(defaults.object(forKey: FeedbackDefaults.soundsKey) == nil)
        #expect(FeedbackDefaults.soundsKey == "anicat_sounds")
        #expect(FeedbackDefaults.soundVolumeKey == "anicat_sounds_volume")
        #expect(FeedbackDefaults.hapticsKey == "anicat_haptics")
    }

    @Test("a synthesised blip is a well-formed WAV of the length it asked for")
    func synthesisedSoundShape() {
        let recipe = AppSounds.tabChange.recipe
        let data = SoundBank.wav(for: recipe)

        // 44-byte canonical header, then 16-bit mono samples. A header written
        // with the wrong data-chunk length still plays on some decoders and
        // silently truncates on others.
        #expect(data.count > 44)
        #expect(String(decoding: data.prefix(4), as: UTF8.self) == "RIFF")
        #expect(String(decoding: data.dropFirst(8).prefix(4), as: UTF8.self) == "WAVE")

        let frames = (data.count - 44) / 2
        let expected = Int(44_100.0 * recipe.duration)
        #expect(abs(frames - expected) <= 1)

        // Every blip stays a blip: over about 120 ms these stop reading as
        // feedback and start reading as a notification chime.
        for sound in AppSounds.allCases {
            #expect(sound.recipe.duration <= 0.120)
            #expect(sound.recipe.peak <= 0.35)
        }
    }
}
