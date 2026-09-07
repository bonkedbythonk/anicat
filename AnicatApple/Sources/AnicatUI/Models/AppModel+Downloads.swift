// AppModel, downloads domain: opening an episode that finished downloading
// from the file the engine copied out, rather than from the swarm.

import Foundation
import SwiftUI
import AnicatCoreKit

extension AppModel {
    /// The finished download of `episode`, if its row is still listed and
    /// its file is still where the engine left it. A `.done` state records
    /// where the copy landed, not that it is still there: the folder is the
    /// user's own Downloads, and a file moved or deleted from it would
    /// otherwise reach mpv as a path that opens nothing.
    public func finishedDownload(catalogId: Int64, episode: Int) -> LibraryDownload? {
        guard let download = libraryDownloads.first(where: { $0.catalogId == catalogId && $0.episode == episode }),
              let path = DownloadsView.donePath(download.state),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return download
    }

    /// Plays a finished download from its own file.
    ///
    /// The Downloads page's Play used to go through `resolveAndPlay`, which
    /// searched the indexers again and streamed whichever release won: what
    /// played had nothing to do with the file in the row, and offline it
    /// failed outright. This is `resolveAndPlay` with the resolve taken out
    /// -- the same player state, resume position, Now Playing tile, Handoff
    /// and Discord presence -- so the episode is recorded and navigated like
    /// any other. `debugPlayLocalFile` is the bare version of the same idea.
    public func playDownloadedFile(_ download: LibraryDownload) async {
        guard let path = DownloadsView.donePath(download.state) else { return }
        guard FileManager.default.fileExists(atPath: path) else {
            errorMessage = "Episode \(download.episode) of \(download.title) is no longer at \(path)"
            errorRetryAction = nil
            playFeedback(.error)
            return
        }
        guard let engine else {
            errorMessage = "Engine not initialized"
            return
        }

        // A resolve still waiting for the swarm would land after this and
        // replace the file with its stream.
        cancelResolve()
        // No row is flying into the player: the Downloads row has no
        // thumbnail to morph from, and a key left over from the last play
        // would name a stale episode still.
        openingPlayerSourceKey = nil
        openingPlayerThumbnailURL = nil

        let fileURL = URL(fileURLWithPath: path)
        let catalogId = download.catalogId
        let episode = Int64(download.episode)
        let title = download.title

        playerController.title = title
        playerController.episodeNumber = download.episode
        playerController.isPlaying = true
        // Same gate as `resolveAndPlay`: the outgoing file's last ticks are
        // not this episode's. Except when this very file is already loaded
        // -- `MpvSurface.loadFile` opens nothing for a URL it has, so no
        // FILE_LOADED would ever lower the gate.
        let replayingCurrent = activeStreamURL == fileURL
        currentPlaybackCatalog = .anilist
        currentPlaybackCatalogId = catalogId
        currentPlaybackEpisode = episode
        playerController.awaitingNewFile = !replayingCurrent
        playerController.currentReleaseName = nil
        ensurePlaybackEpisodes(for: catalogId, engine: engine)
        currentPlaybackTitle = title
        isPlayerMinimized = false
        resetPerEpisodeDedupState(discordPaused: false)
        // The N+1 preload is a torrent resolve. A play from disk is how the
        // app is used offline, where it fails on every episode, and online it
        // would pull an episode nobody asked for at full speed alongside a
        // file that needs no bandwidth. Next prefers a finished download of
        // its own (`playAdjacentEpisode`) and otherwise resolves cold.
        hasPreloadedNextEpisode = true
        playerController.setAniSkipTimes(nil)
        aniSkipAwaitingDuration = false
        playerController.videoDisplayWidth = nil
        playerController.videoDisplayHeight = nil

        var initialTime = 0.0
        var initialDuration = 0.0
        if let progress = try? engine.getProgress(catalog: .anilist, catalogId: catalogId, episodeNumber: episode) {
            initialTime = Double(progress.stopTime)
            initialDuration = Double(progress.duration)
        }
        if initialDuration <= 0,
           let ep = playbackEpisodes.first(where: { $0.number == download.episode }),
           let runtime = ep.runtimeMinutes, runtime > 0 {
            initialDuration = Double(runtime * 60)
        }
        playerController.currentTime = initialTime
        playerController.duration = initialDuration

        // Above the assignment that hands mpv the URL -- see `loadTrackMemory`.
        playerController.titleTrackMemory = await loadTrackMemory(catalogId: catalogId, engine: engine)
        playerController.episodeTitle = playbackEpisodes.first(where: { $0.number == download.episode })?.title ?? ""

        // The curve `resolveAndPlay` opens with, so the two entrances match.
        withAnimation(.smooth(duration: 0.42)) {
            activeStreamURL = fileURL
        }
        playFeedback(.playerOpen)
        updateEpisodeNavigationState()
        syncPlaybackSession()
        requestAniSkipTimes(catalogId: catalogId, episode: episode)

        ContinuityManager.shared.advertisePlayback(
            catalogId: catalogId,
            title: title,
            episode: download.episode,
            timePositionSeconds: playerController.currentTime
        )

        if Self.isDiscordPresenceEnabled {
            engine.discordSetPresence(
                title: title,
                episode: episode,
                episodeTitle: playerController.episodeTitle,
                totalEpisodes: Int64(playbackEpisodes.count),
                pos: Int64(playerController.currentTime),
                duration: Int64(playerController.duration),
                paused: false
            )
        }
    }
}
