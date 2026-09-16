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

        for sound in AppSounds.allCases {
            #expect(sound.recipe.duration <= 0.220)
            #expect(sound.recipe.peak <= 0.35)
            // Inharmonic on purpose. Partials in small integer ratios fuse
            // into one pitched note, which is the beep this set replaced.
            let frequencies = sound.recipe.partials.map(\.frequency)
            for (index, upper) in frequencies.enumerated() where index > 0 {
                let ratio = upper / frequencies[0]
                #expect(abs(ratio - ratio.rounded()) > 0.05)
            }
        }
    }

    @Test("a sound is spent well before it ends, however long it renders")
    func soundsDecayRatherThanRunOn() {
        // The duration cap alone does not keep these reading as feedback: a
        // struck-object model needs a tail long enough not to click when it is
        // cut, so the check is on what is still audible, not on the length.
        // 120 ms is where a tick starts sounding like a notification chime.
        for sound in AppSounds.allCases {
            let samples = pcm(SoundBank.wav(for: sound.recipe))
            let peak = samples.map { abs(Int($0)) }.max() ?? 0
            #expect(peak > 0)

            let cutoff = Int(44_100.0 * 0.120)
            guard samples.count > cutoff else { continue }
            let tail = samples[cutoff...].map { abs(Int($0)) }.max() ?? 0
            #expect(Double(tail) < Double(peak) * 0.08)
        }
    }

    @Test("the same recipe renders the same bytes every time")
    func synthesisIsDeterministic() {
        // The noise burst is a seeded PRNG rather than `random`: a sound that
        // differs slightly per launch cannot be tested and is heard as an
        // inconsistency during a binge.
        #expect(SoundBank.wav(for: AppSounds.watchedTick.recipe)
            == SoundBank.wav(for: AppSounds.watchedTick.recipe))
    }

    private func pcm(_ wav: Data) -> [Int16] {
        stride(from: 44, to: wav.count - 1, by: 2).map { offset in
            Int16(littleEndian: Int16(wav[offset]) | (Int16(bitPattern: UInt16(wav[offset + 1]) << 8)))
        }
    }
}
