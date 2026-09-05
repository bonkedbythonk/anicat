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
    public static var isPlaybackActive: Bool = false

    public static func setToolbarVisible(_ visible: Bool) {
        main?.toolbar = nil
    }
}
#endif

@Observable
public final class PlayerController: @unchecked Sendable {
    public var isPlaying: Bool = true
    public var currentTime: Double = 0.0 // seconds
    public var duration: Double = 0.0 // seconds
    public var title: String = ""
    public var episodeNumber: Int = 1
    /// The episode's own title (AniZip's, same source `EpisodeItem.title`
    /// reads elsewhere) — separate from `title`, which is the show's.
    public var episodeTitle: String = ""

    // Decoded video size (post-rotation, post-pixel-aspect-ratio), reported
    // by mpv once the file's opened. The overlay chrome needs this to
    // position itself against the actual letterboxed video rect rather than
    // the whole window — a MacBook's screen aspect ratio rarely matches the
    // video's, so anything padded from the window's own edges (rather than
    // the video's) sits partly over a black bar instead of over the frame.
    public var videoDisplayWidth: Double?
    public var videoDisplayHeight: Double?
    public var videoAspectRatio: Double? {
        guard let w = videoDisplayWidth, let h = videoDisplayHeight, h > 0 else { return nil }
        return w / h
    }

    /// The video surface's own real on-screen size (`MpvRenderView.bounds`),
    /// reported directly by that view rather than measured a second time via
    /// a separate SwiftUI `GeometryReader` — see `reportContainerSize`'s doc
    /// comment on why the two can disagree.
    public var videoContainerSize: CGSize = .zero

    public var isBuffering: Bool = false
    // 0-100, or nil before mpv has reported anything — mirrors mpv's own
    // "cache-buffering-state" property so the spinner can say something
    // (buffering is driven by the torrent pre-buffer gate in core, which is
    // seconds not milliseconds; a bare spinner reads as hung over that long).
    public var bufferingPercent: Int? = nil
    public var volume: Double = 1.0 // 0 to 1
    public var isMuted: Bool = false
    public var playbackRate: Double = 1.0

    // Anime4K & Video Quality (Single On/Off toggle from Tauri). No longer
    // surfaced in the player UI — controlled from Settings only — but the
    // underlying mpv shader toggle stays, since Settings still reads/writes
    // the same `anicat_gpu_upscaling` default.
    public var isAnime4KEnabled: Bool = true

    /// Whether reaching the end of an episode should start the next one
    /// automatically. Read by `AppModel.handlePlaybackPositionChange`, set
    /// from the player's own toggle button (see `PlayerBottomBar`) — same
    /// direct-`UserDefaults` pattern as `isAnime4KEnabled` above, session
    /// state on this object with the default mirrored in on init.
    public var autoPlayNextEnabled: Bool = true {
        didSet { UserDefaults.standard.set(autoPlayNextEnabled, forKey: "anicat_autoplay_next") }
    }

    public func toggleAutoPlayNext() {
        autoPlayNextEnabled.toggle()
    }

    public var activeAnime4KPreset: Anime4KPreset {
        get { isAnime4KEnabled ? .on : .off }
        set { isAnime4KEnabled = (newValue != .off) }
    }

    // Episode navigation: set by whoever owns the episode list (AppModel).
    // Kept as optional callbacks + flags rather than the controller reaching
    // back into AppModel, same pattern as onSeek/onSetPause below.
    public var onNextEpisode: (@Sendable () -> Void)?
    public var onPreviousEpisode: (@Sendable () -> Void)?
    public var onSelectEpisode: (@Sendable (_ episodeNumber: Int) -> Void)?
    public var hasNextEpisode: Bool = false
    public var hasPreviousEpisode: Bool = false
    public var episodeList: [MediaDetailView.EpisodeItem] = []

    // Volume/mute/speed callbacks — mirror onSeek/onSetPause: state lives
    // here so the UI can bind to it, the actual mpv property set is wired by
    // MpvMetalSurface's coordinator once it has a live handle.
    public var onSetVolume: (@Sendable (_ volume: Double) -> Void)?
    public var onSetMuted: (@Sendable (_ muted: Bool) -> Void)?
    public var onSetSpeed: (@Sendable (_ rate: Double) -> Void)?

    // Rotate video 90 degrees — mirrors the mpv Lua script's "sideways mode"
    // (Shift+V) in the Tauri build: 0 = off, 1 = 90 CW, 2 = 90 CCW. Session-
    // only, tracks how the screen is physically turned right now rather than
    // a per-show preference, same reasoning as the Lua version.
    public var sidewaysState: Int = 0
    public var onCycleSideways: (@Sendable () -> Void)?

    // AniSkip (Skip Intro / Outro)
    public var introStartTime: Double? = nil
    public var introEndTime: Double? = nil
    public var isIntroActive: Bool = false
    public var outroStartTime: Double? = nil
    public var outroEndTime: Double? = nil
    public var isOutroActive: Bool = false
    /// Guards each interval firing its auto-skip once per episode rather than
    /// every single time-pos tick while `currentTime` sits inside the
    /// window — without it, seeking backward into an already-skipped intro
    /// (scrubbing, rewatching) would immediately auto-skip forward again with
    /// no way to actually watch that stretch.
    private var hasAutoSkippedIntro = false
    private var hasAutoSkippedOutro = false

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
    
    // Autohide controls timer & state
    public var areControlsVisible: Bool = true
    public var isMenuOpen: Bool = false
    private var autohideTask: Task<Void, Never>?

    public init(title: String = "", episodeNumber: Int = 1) {
        self.title = title
        self.episodeNumber = episodeNumber
        if UserDefaults.standard.object(forKey: "anicat_gpu_upscaling") != nil {
            self.isAnime4KEnabled = UserDefaults.standard.bool(forKey: "anicat_gpu_upscaling")
        }
        if UserDefaults.standard.object(forKey: "anicat_autoplay_next") != nil {
            self.autoPlayNextEnabled = UserDefaults.standard.bool(forKey: "anicat_autoplay_next")
        }
    }

    public func togglePlayPause() {
        isPlaying.toggle()
        showControlsBriefly()
        onSetPause?(!isPlaying)
        if !isPlaying {
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(false)
            #endif
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
            #if os(macOS)
            NSCursor.setHiddenUntilMouseMoves(false)
            #endif
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

    public func setVolume(_ newVolume: Double) {
        volume = min(max(newVolume, 0), 1)
        if volume > 0 { isMuted = false }
        onSetVolume?(volume)
        onSetMuted?(isMuted)
        showControlsBriefly()
    }

    public func toggleMute() {
        isMuted.toggle()
        onSetMuted?(isMuted)
        showControlsBriefly()
    }

    public func setPlaybackRate(_ rate: Double) {
        playbackRate = rate
        onSetSpeed?(rate)
        showControlsBriefly()
    }

    public func nextEpisode() {
        guard hasNextEpisode else { return }
        onNextEpisode?()
    }

    public func previousEpisode() {
        guard hasPreviousEpisode else { return }
        onPreviousEpisode?()
    }

    public func selectEpisode(_ number: Int) {
        guard number != episodeNumber else { return }
        onSelectEpisode?(number)
    }

    public func cycleSideways() {
        onCycleSideways?()
        showControlsBriefly()
    }

    public func skipIntro() {
        if let end = introEndTime {
            hasAutoSkippedIntro = true
            seek(to: end)
            isIntroActive = false
        }
    }

    public func skipOutro() {
        if let end = outroEndTime {
            hasAutoSkippedOutro = true
            seek(to: end)
            isOutroActive = false
        }
    }

    /// Called by `AniSkipClient`'s result for this episode. Resets the
    /// per-episode auto-skip guards so a freshly loaded episode's intro/outro
    /// can auto-skip again even though a previous episode already did.
    public func setAniSkipTimes(_ times: AniSkipClient.SkipTimes?) {
        introStartTime = times?.introStart
        introEndTime = times?.introEnd
        outroStartTime = times?.outroStart
        outroEndTime = times?.outroEnd
        hasAutoSkippedIntro = false
        hasAutoSkippedOutro = false
        checkIntroStatus()
    }

    /// Whether the auto-skip setting should act the moment `currentTime`
    /// enters a skip window, rather than just surfacing the manual "Skip"
    /// button. Read fresh each check instead of cached at init — Settings can
    /// toggle it mid-episode.
    private var autoSkipEnabled: Bool {
        UserDefaults.standard.object(forKey: "anicat_autoskip") as? Bool ?? true
    }

    /// Despite the name (kept to avoid touching every call site), this
    /// checks both the intro and outro windows against `currentTime`.
    public func checkIntroStatus() {
        if let start = introStartTime, let end = introEndTime {
            isIntroActive = (currentTime >= start && currentTime < end)
            if isIntroActive, !hasAutoSkippedIntro, autoSkipEnabled {
                skipIntro()
            }
        } else {
            isIntroActive = false
        }

        if let start = outroStartTime, let end = outroEndTime {
            isOutroActive = (currentTime >= start && currentTime < end)
            if isOutroActive, !hasAutoSkippedOutro, autoSkipEnabled {
                skipOutro()
            }
        } else {
            isOutroActive = false
        }
    }

    public func showControlsBriefly() {
        if !areControlsVisible {
            areControlsVisible = true
        }
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(false)
        #endif
        autohideTask?.cancel()
        autohideTask = Task {
            try? await Task.sleep(nanoseconds: 3_500_000_000) // 3.5s
            if !Task.isCancelled && isPlaying && !isScrubbing && !isMenuOpen {
                await MainActor.run {
                    withAnimation(.smooth) {
                        self.areControlsVisible = false
                    }
                    #if os(macOS)
                    NSCursor.setHiddenUntilMouseMoves(true)
                    #endif
                }
            }
        }
    }

    public func cancelAutohide() {
        autohideTask?.cancel()
        autohideTask = nil
        areControlsVisible = true
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(false)
        #endif
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
