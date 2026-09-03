import Foundation
import SwiftUI
import Observation

@Observable
public final class PlayerController: @unchecked Sendable {
    public var isPlaying: Bool = true
    public var currentTime: Double = 0.0 // seconds
    public var duration: Double = 1440.0 // seconds (e.g. 24m)
    public var title: String = ""
    public var episodeNumber: Int = 1
    public var isBuffering: Bool = false
    public var volume: Double = 1.0 // 0 to 1
    public var isMuted: Bool = false
    
    // Anime4K & Video Quality
    public var activeAnime4KPreset: Anime4KPreset = .modeAFast
    
    // AniSkip (Skip Intro / Outro)
    public var introStartTime: Double? = 90.0 // sample 1:30
    public var introEndTime: Double? = 175.0   // sample 2:55
    public var isIntroActive: Bool = false
    
    // Autohide controls timer
    public var areControlsVisible: Bool = true
    private var autohideTask: Task<Void, Never>?

    public init(title: String = "", episodeNumber: Int = 1) {
        self.title = title
        self.episodeNumber = episodeNumber
    }

    public func togglePlayPause() {
        isPlaying.toggle()
        showControlsBriefly()
    }

    public func seek(to seconds: Double) {
        currentTime = min(max(seconds, 0), duration)
        checkIntroStatus()
        showControlsBriefly()
    }

    public func seekRelative(by delta: Double) {
        seek(to: currentTime + delta)
    }

    public func cycleAnime4K() {
        switch activeAnime4KPreset {
        case .off:
            activeAnime4KPreset = .modeAFast
        case .modeAFast:
            activeAnime4KPreset = .modeAHQ
        case .modeAHQ:
            activeAnime4KPreset = .modeBFast
        case .modeBFast:
            activeAnime4KPreset = .modeCFast
        case .modeCFast:
            activeAnime4KPreset = .off
        }
        showControlsBriefly()
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
                    withAnimation(.easeInOut(duration: 0.3)) {
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
