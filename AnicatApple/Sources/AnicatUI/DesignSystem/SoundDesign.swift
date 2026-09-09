import Foundation
import AVFoundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Feedback defaults

/// The three keys the Feedback card in Settings writes. Spelled literally at
/// each `@AppStorage` there — the property wrapper needs a literal — so the
/// two must agree.
public enum FeedbackDefaults {
    public static let soundsKey = "anicat_sounds"
    public static let soundVolumeKey = "anicat_sounds_volume"
    public static let hapticsKey = "anicat_haptics"

    /// Off. Every one of these fires during ordinary navigation, so a default
    /// of on would be a new noise the user did not ask for on first launch.
    public static var soundsEnabled: Bool {
        UserDefaults.standard.object(forKey: soundsKey) as? Bool ?? false
    }

    /// 0.3. Read through `object(forKey:)` rather than `double(forKey:)`,
    /// which answers 0.0 for an unwritten key and would mute the whole set.
    public static var soundVolume: Double {
        guard let stored = UserDefaults.standard.object(forKey: soundVolumeKey) as? Double else {
            return 0.3
        }
        return min(max(stored, 0), 1)
    }

    public static var hapticsEnabled: Bool {
        UserDefaults.standard.object(forKey: hapticsKey) as? Bool ?? true
    }
}

// MARK: - Sounds

/// The app's six UI sounds. Each is a short percussive tick synthesised in
/// memory the first time it plays.
///
/// **Not tones.** The first version of this was a sine or triangle at one
/// frequency per sound, and that is the sound a beep has: a pure partial with
/// a fixed pitch reads as a test tone, not as an object. Everything here is
/// instead a struck-object model -- a noise transient for the contact, then
/// two or three *inharmonic* partials decaying at their own rates -- because
/// that is what separates a pen tick from a beep. The partial ratios are
/// deliberately not 2:3:4; integer ratios fuse back into one pitched note.
///
/// The set is tuned to the "Ink & Index" language the rest of the app is:
/// paper, card stock and a stamp, all dull and close-miked, none of them
/// musical.
///
/// Synthesised into a WAV that an `AVAudioPlayer` reads, not rendered through
/// an `AVAudioEngine`: libmpv runs in this process and holds the output
/// device, and a second engine attached to the same device can force a format
/// change mid-playback. A player fed finished bytes asks nothing of the device
/// until it plays, and nothing at all while sounds are off.
public enum AppSounds: String, CaseIterable, Sendable {
    case tabChange
    case playerOpen
    case playerClose
    case swipeBack
    case watchedTick
    case error

    /// Plays the sound, or does nothing when `anicat_sounds` is off. Safe to
    /// call from anywhere on the main actor; the first call for a given sound
    /// synthesises it, later ones reuse the decoded player.
    @MainActor
    public static func play(_ sound: AppSounds) {
        guard FeedbackDefaults.soundsEnabled else { return }
        SoundBank.shared.play(sound, volume: FeedbackDefaults.soundVolume)
    }

    @MainActor
    public func play() {
        AppSounds.play(self)
    }

    /// What is struck, and how hard.
    ///
    /// Nothing maps to a `/System/Library/Sounds` file any more. Tink and Pop
    /// were the two most recognisable sounds on macOS, so the app's own
    /// feedback was the part of it that sounded like every other app.
    var recipe: SoundRecipe {
        // Retuned 2026-09-09. The first set was a paper-and-card model:
        // loud noise transients (0.45 of the mix on a tab change), a hard
        // contact and almost no body. Close up that reads as a pen tick on a
        // desk, which is exactly what it was designed as -- and next to the
        // system's own feedback it reads as dry and thin. This set keeps the
        // struck-object model and the inharmonic partials but moves the
        // balance the other way: the contact drops to a tenth of the mix, the
        // body carries the sound, and the low end is warmer. Still bound by
        // `FeedbackTests`: nothing over 220ms, nothing over 0.35 peak, and
        // everything spent to under 8% by 120ms -- which is what caps the
        // decay constants below at about 45ms.
        switch self {
        // A soft wooden tock. The old one was 45% noise; the ring under it
        // was never what you heard.
        case .tabChange:
            return SoundRecipe(
                partials: [
                    Partial(frequency: 620, amplitude: 0.42, decay: 0.030),
                    Partial(frequency: 877, amplitude: 0.12, decay: 0.018)
                ],
                noise: NoiseBurst(amplitude: 0.10, decay: 0.006),
                cutoff: 3_400,
                duration: 0.120,
                peak: 0.15
            )
        // Opening: a warm low body with a second partial that outlasts the
        // first, so it leans upward without ever becoming a chord.
        case .playerOpen:
            return SoundRecipe(
                partials: [
                    Partial(frequency: 233, amplitude: 0.55, decay: 0.045),
                    Partial(frequency: 331, amplitude: 0.22, decay: 0.040),
                    Partial(frequency: 505, amplitude: 0.07, decay: 0.020)
                ],
                noise: NoiseBurst(amplitude: 0.08, decay: 0.010),
                cutoff: 2_600,
                duration: 0.200,
                peak: 0.22
            )
        // Closing: the same object lower, and the upper partial dies first so
        // the shape falls instead of rising.
        case .playerClose:
            return SoundRecipe(
                partials: [
                    Partial(frequency: 196, amplitude: 0.55, decay: 0.042),
                    Partial(frequency: 279, amplitude: 0.20, decay: 0.028)
                ],
                noise: NoiseBurst(amplitude: 0.08, decay: 0.009),
                cutoff: 2_200,
                duration: 0.190,
                peak: 0.21
            )
        // A back-swipe fires constantly, so this stays the quietest thing in
        // the set and the only one still mostly air.
        case .swipeBack:
            return SoundRecipe(
                partials: [Partial(frequency: 392, amplitude: 0.18, decay: 0.030)],
                noise: NoiseBurst(amplitude: 0.16, decay: 0.018),
                cutoff: 2_800,
                duration: 0.130,
                peak: 0.13
            )
        // Marking an episode watched: the one moment worth a bright note, so
        // it sits higher than the rest and rings a little longer than a tick.
        case .watchedTick:
            return SoundRecipe(
                partials: [
                    Partial(frequency: 784, amplitude: 0.34, decay: 0.032),
                    Partial(frequency: 1_109, amplitude: 0.12, decay: 0.018)
                ],
                noise: NoiseBurst(amplitude: 0.10, decay: 0.004),
                cutoff: 4_000,
                duration: 0.140,
                peak: 0.17
            )
        // Low and dull rather than loud: an error the user can hear from the
        // next room is a punishment, not a signal.
        case .error:
            return SoundRecipe(
                partials: [
                    Partial(frequency: 174, amplitude: 0.55, decay: 0.045),
                    Partial(frequency: 247, amplitude: 0.24, decay: 0.032),
                    Partial(frequency: 379, amplitude: 0.08, decay: 0.016)
                ],
                noise: NoiseBurst(amplitude: 0.10, decay: 0.007),
                cutoff: 1_700,
                duration: 0.210,
                peak: 0.24
            )
        }
    }
}

/// One decaying sine of a struck object.
public struct Partial: Sendable {
    public let frequency: Double
    public let amplitude: Double
    /// Time constant of `exp(-t/decay)`, in seconds -- not a total length.
    public let decay: Double

    public init(frequency: Double, amplitude: Double, decay: Double) {
        self.frequency = frequency
        self.amplitude = amplitude
        self.decay = decay
    }
}

/// The contact transient. Without one every sound starts on a pitch, which is
/// the single most "synthesised" thing a UI sound can do.
public struct NoiseBurst: Sendable {
    public let amplitude: Double
    public let decay: Double

    public init(amplitude: Double, decay: Double) {
        self.amplitude = amplitude
        self.decay = decay
    }
}

public struct SoundRecipe: Sendable {
    public let partials: [Partial]
    public let noise: NoiseBurst?
    /// One-pole lowpass corner, in Hz. The noise burst is white; unfiltered it
    /// is a hiss, and every sound in the set ends up with the same bright top
    /// regardless of what it is meant to be.
    public let cutoff: Double
    /// Total rendered length. Longer than what is audible, because a partial
    /// cut off before its decay finishes clicks.
    public let duration: Double
    /// Peak amplitude before the user's volume setting, 0...1. Kept well under
    /// 1 so a tick layered over a playing episode is a texture, not a duck.
    public let peak: Double

    public init(partials: [Partial], noise: NoiseBurst?, cutoff: Double, duration: Double, peak: Double) {
        self.partials = partials
        self.noise = noise
        self.cutoff = cutoff
        self.duration = duration
        self.peak = peak
    }
}

@MainActor
final class SoundBank {
    static let shared = SoundBank()

    private var players: [AppSounds: AVAudioPlayer] = [:]

    func play(_ sound: AppSounds, volume: Double) {
        let player: AVAudioPlayer
        if let cached = players[sound] {
            player = cached
        } else {
            guard let synthesised = try? AVAudioPlayer(data: Self.wav(for: sound.recipe)) else { return }
            synthesised.prepareToPlay()
            players[sound] = synthesised
            player = synthesised
        }
        player.volume = Float(volume)
        player.currentTime = 0
        player.play()
    }

    // MARK: WAV synthesis

    nonisolated static let sampleRate = 44_100.0

    /// A 16-bit mono PCM WAV of one struck object.
    ///
    /// Three things happen per frame, in this order, and the order is the
    /// design:
    ///
    /// 1. Each partial is a sine under its own `exp(-t/decay)`. Different
    ///    decay rates per partial are what makes it a struck thing rather than
    ///    a chord -- the top dies first and the sound darkens as it falls.
    /// 2. The noise burst is added under a much faster decay. This is the
    ///    contact, and it is why the sound has an onset instead of a pitch.
    /// 3. A one-pole lowpass over the sum. White noise unfiltered is a hiss
    ///    that sounds identical whatever it is layered on.
    ///
    /// A 1.5 ms raised-cosine attack sits in front of all of it: a waveform
    /// that starts at full amplitude clips, and the click is louder than the
    /// sound.
    nonisolated static func wav(for recipe: SoundRecipe) -> Data {
        let frameCount = max(1, Int(sampleRate * recipe.duration))
        let attackFrames = max(1, Int(sampleRate * 0.0015))

        // Deterministic, so the same recipe always renders the same bytes and
        // a test can assert on them. A per-run `random` would also mean the
        // sound differed slightly every launch.
        var rng = SplitMix64(seed: 0x5EED_A11C_E5_1234)

        // One-pole coefficient from the corner frequency, the standard
        // `1 - exp(-2*pi*fc/fs)` mapping.
        let alpha = 1 - exp(-2 * .pi * recipe.cutoff / sampleRate)
        var filtered = 0.0

        var raw = [Double]()
        raw.reserveCapacity(frameCount)
        var loudest = 0.0

        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate

            var value = 0.0
            for partial in recipe.partials {
                value += partial.amplitude * sin(2 * .pi * partial.frequency * t) * exp(-t / partial.decay)
            }
            if let noise = recipe.noise {
                value += noise.amplitude * rng.nextBipolar() * exp(-t / noise.decay)
            }

            filtered += alpha * (value - filtered)

            let attack = frame < attackFrames
                ? 0.5 - 0.5 * cos(.pi * Double(frame) / Double(attackFrames))
                : 1.0
            let sample = filtered * attack
            raw.append(sample)
            loudest = max(loudest, abs(sample))
        }

        // Normalised to the recipe's peak rather than trusting the amplitudes
        // to sum there. Partials interfere, the lowpass takes energy out, and
        // the noise seed changes the maximum; without this the six sounds
        // arrive at noticeably different loudnesses from numbers that read as
        // if they were matched.
        let gain = loudest > 0 ? recipe.peak / loudest : 0
        let samples = raw.map { sample -> Int16 in
            Int16(max(-1, min(1, sample * gain)) * Double(Int16.max))
        }

        return riff(samples: samples)
    }

    nonisolated private static func riff(samples: [Int16]) -> Data {
        let byteCount = samples.count * MemoryLayout<Int16>.size
        var data = Data(capacity: 44 + byteCount)

        func append(_ string: String) {
            data.append(contentsOf: Array(string.utf8))
        }
        func append32(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func append16(_ value: UInt16) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }

        append("RIFF")
        append32(UInt32(36 + byteCount))
        append("WAVE")
        append("fmt ")
        append32(16)                              // PCM chunk size
        append16(1)                               // format: PCM
        append16(1)                               // channels: mono
        append32(UInt32(sampleRate))
        append32(UInt32(sampleRate) * 2)          // byte rate
        append16(2)                               // block align
        append16(16)                              // bits per sample
        append("data")
        append32(UInt32(byteCount))
        samples.forEach { sample in
            withUnsafeBytes(of: sample.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Whitened counter PRNG. `arc4random` would do, but the render has to be
/// reproducible for the same recipe.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// -1...1.
    mutating func nextBipolar() -> Double {
        Double(next() >> 11) / Double(1 << 53) * 2 - 1
    }
}

// MARK: - Haptics

/// The two gesture haptics, separate from `SumiHaptics.selection` (which is
/// the tap/selection tick every control already fires and has no toggle).
/// These two ride continuous gestures, so they need a way to be turned off
/// without silencing the rest of the app.
public enum AppHaptics {
    public static var isEnabled: Bool { FeedbackDefaults.hapticsEnabled }

    /// The moment a horizontal drag crosses the distance that will commit a
    /// back navigation. `.alignment` is the snap pattern, which is what
    /// "you have crossed the line" feels like on a trackpad.
    @MainActor
    public static func swipeThreshold() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        #elseif canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// A scrub landing on a chapter or a skip boundary. `.levelChange` is the
    /// heavier of the two patterns, so a seek reads as a bigger event than a
    /// swipe crossing its threshold.
    @MainActor
    public static func seekSnap() {
        guard isEnabled else { return }
        #if os(macOS)
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #elseif canImport(UIKit)
        UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
        #endif
    }
}
