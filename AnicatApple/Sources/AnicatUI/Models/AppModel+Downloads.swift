// AppModel, downloads domain: opening an episode that finished downloading
// from the file the engine copied out, rather than from the swarm.

import Foundation
import SwiftUI
import AnicatCoreKit

extension AppModel {
    /// Downloads take the smallest release that is as good a match (720p or
    /// HEVC) instead of streaming's pick, SubsPlease's 1.4 GB 1080p H.264:
    /// 587 MB for Frieren S2 05 and 225 MB for Buddy Daddies 03 (2026-09-23).
    /// On by default on the phone, where every download is its own storage;
    /// off on the Mac, whose copies land in the viewer's Downloads folder.
    static let smallerDownloadsKey = "anicat_smaller_downloads"
    static var prefersSmallerDownloads: Bool {
        UserDefaults.standard.object(forKey: smallerDownloadsKey) as? Bool ?? isPhoneDefault
    }

    /// A downloaded episode is deleted once it counts as watched. Same
    /// defaults, same reason: on the phone the file is in the app's own
    /// container and nothing but this app can ever remove it.
    static let deleteWatchedDownloadsKey = "anicat_delete_watched_downloads"
    static var deletesWatchedDownloads: Bool {
        UserDefaults.standard.object(forKey: deleteWatchedDownloadsKey) as? Bool ?? isPhoneDefault
    }

    /// Silence keeps the app from being suspended while a download runs in the
    /// background (`DownloadKeepAlive`). On by default; the switch is there
    /// because it costs battery.
    static let backgroundDownloadsKey = "anicat_background_downloads"
    static var keepsDownloadingInBackground: Bool {
        UserDefaults.standard.object(forKey: backgroundDownloadsKey) as? Bool ?? true
    }

    #if os(iOS)
    /// Whether the app is in the background, as the scene last reported it.
    /// Set by `SystemIntegrationObserver`; read by `syncDownloadKeepAlive`.
    static var isInBackground = false

    /// Starts or stops `DownloadKeepAlive` to match: in the background, a
    /// download in progress, nothing playing (a stream has its own audio
    /// session and keeps the app running already), no system task doing the
    /// job, and the setting on.
    func syncDownloadKeepAlive() {
        let downloading = libraryDownloads.contains {
            if case .downloading = $0.state { return true }
            return false
        }
        let wanted = Self.isInBackground
            && downloading
            && activeStreamURL == nil
            && !DownloadBackgroundTasks.shared.hasRunningTask
            && Self.keepsDownloadingInBackground
        DownloadKeepAlive.shared.setRunning(wanted)
    }

    /// The engine saves phone downloads under Documents/Anicat
    /// (`downloads_root`), and Documents goes into the iCloud backup by
    /// default: a season of episodes would be gigabytes of someone's backup
    /// quota for files a torrent can fetch again.
    static func excludeDownloadsFromBackup() {
        guard var folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Anicat", isDirectory: true) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? folder.setResourceValues(values)
    }
    #endif

    private static var isPhoneDefault: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    /// Forgets a download and, when asked, deletes its file. The phone's
    /// Downloads page used to drop the row only: the file stayed in the app's
    /// container, where nothing else can reach it, and the row came back at
    /// the next launch from the engine's table.
    public func removeDownload(_ download: LibraryDownload, deleteFile: Bool) {
        libraryDownloads.removeAll { $0.id == download.id }
        pendingWatchedDownloadRemovals.remove(download.id)
        if selectedMediaDetails?.id == download.catalogId {
            downloadStates[download.episode] = nil
        }
        guard let engine else { return }
        let catalog = download.catalog.ffi
        engineIOQueue.async {
            try? engine.removeDownloadedEpisode(
                catalog: catalog, catalogId: download.catalogId,
                episode: Int64(download.episode), deleteFile: deleteFile
            )
        }
    }

    /// Marks the playing episode's download, if it has one, for deletion
    /// once the file is no longer being read. Called where the episode
    /// counts as watched: the 85% line, and Next after real playback.
    func queueWatchedDownloadRemoval(catalogId: Int64, episode: Int64) {
        guard Self.deletesWatchedDownloads else { return }
        let card: MediaCard.CardCatalog = switch currentPlaybackCatalog {
        case .tmdbMovie: .tmdbMovie
        case .tmdbTv: .tmdbTv
        case .anilist, .mangaDex: .anilist
        }
        guard let download = finishedDownload(catalog: card, catalogId: catalogId, episode: Int(episode)),
              !pendingWatchedDownloadRemovals.contains(download.id) else { return }
        pendingWatchedDownloadRemovals.insert(download.id)
        AppLog.write("[downloads] ep \(episode) of \(catalogId) watched: its download goes when playback moves on")
    }

    /// Deletes the queued downloads except the one mpv has open. Unlinking an
    /// open file would not stop mpv, but a rewind into the credits after the
    /// 85% line should still find the file, so it waits for the stop.
    func flushWatchedDownloadRemovals() {
        guard !pendingWatchedDownloadRemovals.isEmpty else { return }
        let playing = activeStreamURL?.isFileURL == true ? activeStreamURL?.path : nil
        for download in libraryDownloads where pendingWatchedDownloadRemovals.contains(download.id) {
            if let path = DownloadsView.donePath(download.state), path == playing { continue }
            AppLog.write("[downloads] deleting watched \(download.title) ep \(download.episode)")
            removeDownload(download, deleteFile: true)
        }
    }

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
        #if os(iOS)
        Self.excludeDownloadsFromBackup()
        #endif
        // Files from before there was a table, and any a crash lost: the
        // engine walks the Downloads folder and indexes what it can identify
        // from the lists this side already has. Idempotent, so this runs at
        // every launch and costs a directory walk.
        let hints = Self.titleHints(
            from: watchingItems + libraryItems + mangaReading,
            knownTitles: knownTitles
        )
        if !hints.isEmpty {
            _ = try? engine.scanDownloadsFolder(hints: hints)
        }
        let rows = (try? engine.downloadedEpisodes()) ?? []
        // Rows for episodes the app is downloading right now win: they carry
        // live progress, and the stored row only knows about finished ones.
        var restored: [LibraryDownload] = []
        var unnamedAniList: [Int64] = []
        var unnamedCinema: [CinemaTitleKey] = []
        for row in rows {
            let catalog: MediaCard.CardCatalog = row.catalog == .tmdbMovie
                ? .tmdbMovie
                : (row.catalog == .tmdbTv ? .tmdbTv : .anilist)
            // Matched on the catalog too: episode 1 of a film and episode 1
            // of the anime sharing its number are two downloads, and without
            // this the one already in flight suppressed the other's row.
            let alreadyListed = libraryDownloads.contains {
                $0.catalog == catalog
                    && $0.catalogId == row.catalogId
                    && $0.episode == Int(row.episodeNumber)
            }
            guard !alreadyListed else { continue }
            // The engine's row has a title only when the download was
            // started by this build; a file the folder scan adopted, or one
            // from before the table, has none, and the page grouped it under
            // its number until a shelf happened to name it.
            let title = row.title ?? registryTitle(catalog: row.catalog, id: row.catalogId)
            if title == nil {
                switch catalog {
                case .anilist: unnamedAniList.append(row.catalogId)
                case .tmdbMovie, .tmdbTv: unnamedCinema.append(CinemaTitleKey(catalog: catalog, id: row.catalogId))
                }
            }
            restored.append(
                LibraryDownload(
                    catalogId: row.catalogId,
                    episode: Int(row.episodeNumber),
                    title: title ?? Self.placeholderTitle(row.catalogId),
                    // `knownCovers` is AniList's map alone; a film asked of it
                    // by bare id answers with whatever anime shares the number.
                    coverURL: registryCover(catalog: row.catalog, id: row.catalogId),
                    state: .done(path: row.path),
                    catalog: catalog
                )
            )
        }
        libraryDownloads.append(contentsOf: restored)
        resolveMissingTitles(unnamedAniList)
        if !unnamedCinema.isEmpty {
            Task { @MainActor [weak self] in
                guard let self else { return }
                for key in Set(unnamedCinema) {
                    guard self.cinemaKnownTitles[key] == nil,
                          let known = await self.cinemaTitle(catalog: key.catalog, id: key.id) else { continue }
                    self.cinemaKnownTitles[key] = known.title
                    if let cover = known.coverURL { self.cinemaKnownCovers[key] = cover }
                }
                self.applyResolvedDownloadTitles()
            }
        }
    }

    /// What a row draws until its title is known. One spelling, so the
    /// rewrite below can tell a placeholder from a title.
    nonisolated static func placeholderTitle(_ id: Int64) -> String { "Media \(id)" }

    /// Renames the rows still carrying a placeholder once a lookup has
    /// answered. Called from the title resolvers; a row's title is what the
    /// Downloads page groups on, so the map alone changing would leave the
    /// group heading on its number.
    func applyResolvedDownloadTitles() {
        var changed = false
        var rows = libraryDownloads
        for index in rows.indices where rows[index].title == Self.placeholderTitle(rows[index].catalogId) {
            let row = rows[index]
            let ffiCatalog: FfiCatalog = {
                switch row.catalog {
                case .tmdbMovie: return .tmdbMovie
                case .tmdbTv: return .tmdbTv
                case .anilist: return .anilist
                }
            }()
            guard let title = registryTitle(catalog: ffiCatalog, id: row.catalogId) else { continue }
            rows[index].title = title
            changed = true
        }
        if changed { libraryDownloads = rows }
    }

    /// What the app can tell the engine about its own titles, for matching a
    /// folder name back to a catalog id. Every name a title goes by, because
    /// the folder was named after whichever one the download started with.
    nonisolated static func titleHints(
        from items: [MediaCard.Item],
        knownTitles: [Int64: String]
    ) -> [FfiTitleHint] {
        var byId: [Int64: Set<String>] = [:]
        for item in items where !item.title.isEmpty {
            byId[item.id, default: []].insert(item.title)
        }
        for (id, title) in knownTitles where !title.isEmpty {
            byId[id, default: []].insert(title)
        }
        return byId.map { id, titles in
            FfiTitleHint(catalog: .anilist, catalogId: id, titles: Array(titles))
        }
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
        playerController.isLiveAction = download.catalog != .anilist
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
        playerController.aniSkipStatus = nil
        aniSkipAwaitingDuration = false
        playerController.videoDisplayWidth = nil
        playerController.videoDisplayHeight = nil
        playerController.decodedDisplayWidth = nil
        playerController.decodedDisplayHeight = nil

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

        publishPlaybackPresence()
    }
}
