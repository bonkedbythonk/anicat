import Foundation
import SwiftUI
import Observation
#if os(macOS)
import AppKit

/// The real Anicat content window, set once by `WindowConfigurator` in the
/// app target the moment SwiftUI hands it a window. `NSApp.keyWindow` is
/// racy during any transition where something else (mpv's render view, a
/// sheet, a popover) could briefly hold key status — this is the one
/// reference that's unambiguously "our window" for anything driving it from
/// AnicatUI, like the player's auto-fullscreen.
@MainActor
public enum AppWindow {
    public static weak var main: NSWindow?
}
#endif

@Observable
public final class PlayerController: @unchecked Sendable {
    public var isPlaying: Bool = true
    public var currentTime: Double = 0.0 // seconds
    public var duration: Double = 0.0 // seconds
    public var title: String = ""
    public var episodeNumber: Int = 1
    public var isBuffering: Bool = false
    // 0-100, or nil before mpv has reported anything — mirrors mpv's own
    // "cache-buffering-state" property so the spinner can say something
    // (buffering is driven by the torrent pre-buffer gate in core, which is
    // seconds not milliseconds; a bare spinner reads as hung over that long).
    public var bufferingPercent: Int? = nil
    public var volume: Double = 1.0 // 0 to 1
    public var isMuted: Bool = false
    
    // Anime4K & Video Quality (Single On/Off toggle from Tauri)
    public var isAnime4KEnabled: Bool = true

    public var activeAnime4KPreset: Anime4KPreset {
        get { isAnime4KEnabled ? .on : .off }
        set { isAnime4KEnabled = (newValue != .off) }
    }
    
    // AniSkip (Skip Intro / Outro)
    public var introStartTime: Double? = nil
    public var introEndTime: Double? = nil
    public var isIntroActive: Bool = false

    // Progress & Playback callbacks for real SQLite recording and libmpv sync
    public var onPositionChange: (@Sendable (_ currentTime: Double, _ duration: Double) -> Void)?
    public var onPlaybackStopped: (@Sendable () -> Void)?
    public var onSeek: (@Sendable (_ seconds: Double) -> Void)?
    public var onSetPause: (@Sendable (_ paused: Bool) -> Void)?
    public var isScrubbing: Bool = false

    // Info / more-options menu: cycling audio/subtitle tracks is an mpv
    // command (no separate track-picker UI to build against a full
    // track-list yet), and reading back the current one is a synchronous
    // mpv property read — both safe to call straight from the main thread,
    // so these aren't state, just callbacks the menu invokes on demand.
    public var onCycleAudioTrack: (@Sendable () -> Void)?
    public var onCycleSubtitleTrack: (@Sendable () -> Void)?
    public var onFetchTrackInfo: (@Sendable () -> (audio: String, subtitle: String))?
    
    // Autohide controls timer
    public var areControlsVisible: Bool = true
    private var autohideTask: Task<Void, Never>?

    public init(title: String = "", episodeNumber: Int = 1) {
        self.title = title
        self.episodeNumber = episodeNumber
        if UserDefaults.standard.object(forKey: "anicat_gpu_upscaling") != nil {
            self.isAnime4KEnabled = UserDefaults.standard.bool(forKey: "anicat_gpu_upscaling")
        }
    }

    public func togglePlayPause() {
        isPlaying.toggle()
        showControlsBriefly()
        onSetPause?(!isPlaying)
        if !isPlaying {
            onPositionChange?(currentTime, duration)
        }
    }

    public func play() {
        if !isPlaying {
            isPlaying = true
            showControlsBriefly()
            onSetPause?(false)
        }
    }

    public func pause() {
        if isPlaying {
            isPlaying = false
            showControlsBriefly()
            onSetPause?(true)
            onPositionChange?(currentTime, duration)
        }
    }

    public func seek(to seconds: Double) {
        currentTime = max(seconds, 0)
        if duration > 0 {
            currentTime = min(currentTime, duration)
        }
        checkIntroStatus()
        showControlsBriefly()
        onSeek?(currentTime)
        onPositionChange?(currentTime, duration)
    }

    public func seekRelative(by delta: Double) {
        seek(to: currentTime + delta)
    }

    public func toggleAnime4K() {
        isAnime4KEnabled.toggle()
        UserDefaults.standard.set(isAnime4KEnabled, forKey: "anicat_gpu_upscaling")
        showControlsBriefly()
    }

    public func cycleAnime4K() {
        toggleAnime4K()
    }

    public func skipIntro() {
        if let end = introEndTime {
            seek(to: end)
            isIntroActive = false
        }
    }

    public func checkIntroStatus() {
        if let start = introStartTime, let end = introEndTime {
            isIntroActive = (currentTime >= start && currentTime < end)
        } else {
            isIntroActive = false
        }
    }

    public func showControlsBriefly() {
        areControlsVisible = true
        autohideTask?.cancel()
        autohideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5s
            if !Task.isCancelled && isPlaying {
                await MainActor.run {
                    withAnimation(.smooth) {
                        self.areControlsVisible = false
                    }
                }
            }
        }
    }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return currentTime / duration
    }

    public var formattedCurrentTime: String {
        formatTime(currentTime)
    }

    public var formattedDuration: String {
        formatTime(duration)
    }

    private func formatTime(_ seconds: Double) -> String {
        let total = Int(seconds)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
