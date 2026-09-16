import Foundation
import AnicatCoreKit

/// Notices a stream that stalls while opening, and moves on.
///
/// The engine's pre-buffer gate proves a swarm is delivering bytes at the
/// moment it hands back a URL, and then stops looking. A swarm can dry up
/// in the seconds after -- the one seeder leaves, the peers that answered
/// choke -- and from then on nothing anywhere gave up: mpv waited on the
/// head piece, `paused-for-cache` stayed true, the engine's stall-check
/// logged the zero every five seconds and did nothing with it, and the
/// player sat on a spinner until the viewer closed it. "When starting the
/// movie, downloading / buffering, it stalls. Sometimes; it's not
/// consistent."
///
/// This samples the playing torrent from the moment mpv has the URL until
/// the picture is moving. Twenty seconds without a single byte off the
/// swarm while the file has not started playing is a stall; the episode is
/// then re-resolved with the next release from the candidate list, by
/// name, which the engine treats as an instruction to skip the reuse cache
/// and the remembered release. Two such switches and it stops: the third
/// dead swarm in a row is the title's problem, not the release's, and the
/// player closes with a message that says so.
extension AppModel {
    /// No bytes for this long, with the file not yet playing, is a stall.
    /// Longer than one unchoke round (10s) so a slow-starting live swarm
    /// gets to send its first block; the engine's own zero-bytes cutoff
    /// inside the pre-buffer is 12s for the same reason.
    static let openingStallWindow: TimeInterval = 20
    /// A stream with no torrent stats to read (a remote stream served by
    /// another Anicat) is judged on the playhead alone, more generously.
    static let openingSilentWindow: TimeInterval = 60
    static let openingWatchdogSampleInterval: TimeInterval = 2
    static let openingWatchdogMaxSwitches = 2

    func cancelOpeningWatchdog() {
        openingWatchdogTask?.cancel()
        openingWatchdogTask = nil
    }

    func startOpeningWatchdog(catalog: FfiCatalog, catalogId: Int64, episode: Int64) {
        cancelOpeningWatchdog()
        guard let engine else { return }
        let startedAt = Date()
        openingWatchdogTask = Task { @MainActor [weak self] in
            var lastBytes: UInt64? = nil
            var lastProgressAt = startedAt
            var startTime: Double? = nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.openingWatchdogSampleInterval))
                guard !Task.isCancelled, let self else { return }
                // Not this episode any more: a Next, a switch, or a close
                // already cancelled this task, but check anyway.
                guard self.currentPlaybackCatalogId == catalogId,
                      self.currentPlaybackEpisode == episode,
                      self.activeStreamURL != nil else { return }

                let controller = self.playerController
                if startTime == nil, !controller.awaitingNewFile {
                    startTime = controller.currentTime
                }
                // Opened and moving: the swarm is keeping up, or mpv's own
                // cache handles it from here. Either way this is done.
                if let startTime, !controller.awaitingNewFile, !controller.isBuffering,
                   controller.currentTime - startTime >= 1 {
                    self.openingWatchdogTask = nil
                    return
                }

                let now = Date()
                if let stats = engine.playingTorrentStats() {
                    let bytes = stats.fileDownloadedBytes
                    if lastBytes == nil || bytes > lastBytes! {
                        lastBytes = bytes
                        lastProgressAt = now
                    }
                    let silent = now.timeIntervalSince(lastProgressAt)
                    guard silent >= Self.openingStallWindow else { continue }
                    PlayerLog.write(String(
                        format: "[watchdog] stalled opening: %.0fs without a byte, state=%@ peers live=%d connecting=%d seen=%d, %llu of %llu bytes",
                        silent, stats.state, stats.peersLive, stats.peersConnecting, stats.peersSeen,
                        stats.fileDownloadedBytes, stats.fileBytes))
                } else {
                    // Remote stream, or a torrent the engine is not tracking as
                    // playing: only the playhead can speak.
                    guard now.timeIntervalSince(startedAt) >= Self.openingSilentWindow else { continue }
                    PlayerLog.write("[watchdog] stalled opening: no playback after \(Int(Self.openingSilentWindow))s and no torrent stats to read")
                }
                self.openingWatchdogTask = nil
                await self.switchAwayFromStalledRelease(catalog: catalog, catalogId: catalogId, episode: episode, engine: engine)
                return
            }
        }
    }

    /// Re-resolves the episode with the next release that has not stalled
    /// yet, or closes the player with the reason when there is none left
    /// to try.
    private func switchAwayFromStalledRelease(catalog: FfiCatalog, catalogId: Int64, episode: Int64, engine: AnicatEngine) async {
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let current = playerController.currentReleaseName
            ?? engine.rememberedReleaseName(catalog: catalog, catalogId: catalogId, episode: episode, preferDub: preferDub)
        if let current { stalledReleaseNames.insert(current) }

        var next: String? = nil
        if stalledReleaseNames.count <= Self.openingWatchdogMaxSwitches {
            // Cached by the engine for a minute after the resolve that just
            // ran, so this is the list that resolve chose from, not a new
            // search wave.
            let candidates = (try? await playbackReleaseCandidates()) ?? []
            guard currentPlaybackCatalogId == catalogId, currentPlaybackEpisode == episode else { return }
            next = candidates.first { !stalledReleaseNames.contains($0.name) && $0.seeders > 0 }?.name
                ?? candidates.first { !stalledReleaseNames.contains($0.name) }?.name
        }

        guard let next else {
            PlayerLog.write("[watchdog] no release left to try after \(stalledReleaseNames.count) stalled")
            stopPlayback()
            errorMessage = "The stream stalled while opening and no other release came through. Try again later, or pick a release by hand."
            errorRetryAction = { [weak self] in
                guard let self else { return }
                self.errorMessage = nil
                self.errorRetryAction = nil
                self.activeResolveTask = Task { [weak self] in
                    _ = try? await self?.resolveAndPlay(catalog: catalog, catalogId: catalogId, episode: episode, forceNewFile: true)
                }
            }
            playFeedback(.error)
            return
        }

        PlayerLog.write("[watchdog] switching from '\(current ?? "?")' to '\(next)'")
        playerController.flashHUD("Stream stalled, trying another release", symbol: "arrow.triangle.2.circlepath")
        activeResolveTask?.cancel()
        activeResolveTask = Task { [weak self] in
            await self?.switchRelease(to: next)
        }
    }
}
