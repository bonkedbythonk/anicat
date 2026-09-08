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
    /// Restores what is already on disk, so the Downloads page and the
    /// episode rows know about downloads made in earlier sessions.
    ///
    /// The engine's own download map is session-only and the files are not:
    /// without this the app forgot every relaunch that it had an episode,
    /// and pressing Play fetched a file already on the disk.
    @MainActor
    public func loadDownloadedEpisodes() {
        guard let engine else { return }
        let rows = (try? engine.downloadedEpisodes()) ?? []
        // Rows for episodes the app is downloading right now win: they carry
        // live progress, and the stored row only knows about finished ones.
        var restored: [LibraryDownload] = []
        for row in rows where !libraryDownloads.contains(where: {
            $0.catalogId == row.catalogId && $0.episode == Int(row.episodeNumber)
        }) {
            restored.append(
                LibraryDownload(
                    catalogId: row.catalogId,
                    episode: Int(row.episodeNumber),
                    title: row.title ?? "Media \(row.catalogId)",
                    coverURL: knownCovers[row.catalogId],
                    state: .done(path: row.path),
                    catalog: row.catalog == .tmdbMovie
                        ? .tmdbMovie
                        : (row.catalog == .tmdbTv ? .tmdbTv : .anilist)
                )
            )
        }
        libraryDownloads.append(contentsOf: restored)
    }

    public func finishedDownload(
        catalog: MediaCard.CardCatalog,
        catalogId: Int64,
        episode: Int
    ) -> LibraryDownload? {
        guard let download = libraryDownloads.first(where: {
                  $0.catalog == catalog && $0.catalogId == catalogId && $0.episode == episode
              }),
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
        let catalog: FfiCatalog = {
            switch download.catalog {
            case .tmdbMovie: return .tmdbMovie
            case .tmdbTv: return .tmdbTv
            case .anilist: return .anilist
            }
        }()
        currentPlaybackCatalog = catalog
        currentPlaybackCatalogId = catalogId
        currentPlaybackEpisode = episode
        playerController.awaitingNewFile = !replayingCurrent
        playerController.currentReleaseName = nil
        ensurePlaybackEpisodes(for: catalogId, engine: engine, catalog: catalog)
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
        if let progress = try? engine.getProgress(catalog: catalog, catalogId: catalogId, episodeNumber: episode) {
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
        playerController.titleTrackMemory = await loadTrackMemory(catalog: catalog, catalogId: catalogId, engine: engine)
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
            catalog: Self.handoffCatalog(catalog),
            title: title,
            episode: download.episode,
            timePositionSeconds: playerController.currentTime
        )

        if Self.isDiscordPresenceEnabled {
            // Queued, not inline: see the same call in `resolveAndPlay`.
            let episodeTitle = playerController.episodeTitle
            let totalEpisodes = Int64(playbackEpisodes.count)
            let pos = Int64(playerController.currentTime)
            let duration = Int64(playerController.duration)
            engineIOQueue.async {
                engine.discordSetPresence(
                    title: title,
                    episode: episode,
                    episodeTitle: episodeTitle,
                    totalEpisodes: totalEpisodes,
                    pos: pos,
                    duration: duration,
                    paused: false
                )
            }
        }
    }
}
