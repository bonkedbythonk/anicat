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

/// The app's six UI sounds. Each is a short blip synthesised in memory the
/// first time it plays, or a system sound where one already says the right
/// thing.
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

    /// The system sound this maps to on macOS, if any. Everything else is
    /// synthesised, and iOS synthesises all six — `/System/Library/Sounds` is
    /// a Mac directory.
    var systemSoundName: String? {
        #if os(macOS)
        switch self {
        case .watchedTick: return "Tink"
        case .playerClose: return "Pop"
        default: return nil
        }
        #else
        return nil
        #endif
    }

    /// Frequency, length and waveform of the synthesised blip. The two tab and
    /// swipe sounds sit low so they can repeat without becoming an alarm; the
    /// player and error tones are set apart in pitch so they are told apart
    /// without being looked at.
    var recipe: SoundRecipe {
        switch self {
        case .tabChange:
            return SoundRecipe(frequency: 660, duration: 0.035, waveform: .sine, peak: 0.22)
        case .playerOpen:
            return SoundRecipe(frequency: 523.25, duration: 0.070, waveform: .triangle, peak: 0.28)
        case .playerClose:
            return SoundRecipe(frequency: 392, duration: 0.060, waveform: .triangle, peak: 0.26)
        case .swipeBack:
            return SoundRecipe(frequency: 440, duration: 0.045, waveform: .sine, peak: 0.20)
        case .watchedTick:
            return SoundRecipe(frequency: 880, duration: 0.030, waveform: .sine, peak: 0.24)
        case .error:
            return SoundRecipe(frequency: 220, duration: 0.090, waveform: .triangle, peak: 0.30)
        }
    }
}

public struct SoundRecipe: Sendable {
    public enum Waveform: Sendable {
        case sine
        case triangle
    }

    public let frequency: Double
    public let duration: Double
    public let waveform: Waveform
    /// Peak amplitude before the user's volume setting, 0...1. Kept well under
    /// 1 so a blip layered over a playing episode is a texture, not a duck.
    public let peak: Double
}

@MainActor
final class SoundBank {
    static let shared = SoundBank()

    private var players: [AppSounds: AVAudioPlayer] = [:]
    #if os(macOS)
    private var systemSounds: [AppSounds: NSSound] = [:]
    #endif

    func play(_ sound: AppSounds, volume: Double) {
        #if os(macOS)
        if let name = sound.systemSoundName {
            let cached = systemSounds[sound] ?? NSSound(named: name)
            guard let cached else { return }
            systemSounds[sound] = cached
            // An NSSound already playing ignores `play()`; these fire faster
            // than they finish (a watched tick per episode boundary during a
            // binge), so the second one would be silently dropped.
            cached.stop()
            cached.volume = Float(volume)
            cached.play()
            return
        }
        #endif

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

    /// A 16-bit mono PCM WAV of one blip.
    ///
    /// The envelope is not decoration: a tone that starts and stops at full
    /// amplitude clips at both ends and the click is louder than the tone. A
    /// 4 ms raised-cosine attack and a cosine decay over the remainder remove
    /// both without lengthening the sound.
    nonisolated static func wav(for recipe: SoundRecipe) -> Data {
        let frameCount = max(1, Int(sampleRate * recipe.duration))
        let attackFrames = max(1, Int(sampleRate * 0.004))

        var samples = [Int16]()
        samples.reserveCapacity(frameCount)
        for frame in 0..<frameCount {
            let t = Double(frame) / sampleRate
            let phase = (recipe.frequency * t).truncatingRemainder(dividingBy: 1.0)
            let wave: Double
            switch recipe.waveform {
            case .sine:
                wave = sin(2 * .pi * phase)
            case .triangle:
                wave = 4 * abs(phase - 0.5) - 1
            }

            let envelope: Double
            if frame < attackFrames {
                envelope = 0.5 - 0.5 * cos(.pi * Double(frame) / Double(attackFrames))
            } else {
                let decayProgress = Double(frame - attackFrames) / Double(max(1, frameCount - attackFrames))
                envelope = 0.5 + 0.5 * cos(.pi * decayProgress)
            }

            let value = wave * envelope * recipe.peak
            samples.append(Int16(max(-1, min(1, value)) * Double(Int16.max)))
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
