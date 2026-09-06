// AppModel, playback domain: starting and stopping an episode, the player's
// callbacks, the once-a-second position tick and everything it drives
// (progress recording, AniList advance, auto-next, the N+1 preload), the
// Now Playing tile and the sleep assertion, downloads.

import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

extension AppModel {
    public func cancelResolve() {
        activeResolveTask?.cancel()
        activeResolveTask = nil
        resolveStartedAt = nil
        isLoading = false
    }

    // These four dedup flags only mean anything scoped to "the episode
    // currently loaded" — `resolveAndPlay` resets them for the episode
    // starting, `stopPlayback` for the one ending. They used to be reset by
    // hand at each site, and `stopPlayback` had dropped
    // `hasAdvancedAniListForCurrentEpisode` from its half (masked in
    // practice only because the next `resolveAndPlay` always resets it
    // before it's read again). One call at each site makes "new episode
    // session = all four reset" structural instead of something to remember
    // per flag.
    func resetPerEpisodeDedupState(discordPaused: Bool?) {
        lastRecordedSecond = -1
        lastDiscordPaused = discordPaused
        hasAdvancedAniListForCurrentEpisode = false
        hasAutoAdvancedEpisode = false
        hasPreloadedNextEpisode = false
    }

    func setupPlayerCallbacks() {
        playerController.onPositionChange = { [weak self] currentTime, duration in
            self?.handlePlaybackPositionChange(currentTime: currentTime, duration: duration)
        }
        playerController.onPlayingStateChange = { [weak self] _ in
            self?.syncPlaybackSession()
        }
        nowPlaying.attach(to: playerController)
        playerController.onPlaybackStopped = { [weak self] in
            self?.stopPlayback()
        }
        playerController.onNextEpisode = { [weak self] in
            Task { await self?.playAdjacentEpisode(offset: 1) }
        }
        playerController.onPreviousEpisode = { [weak self] in
            Task { await self?.playAdjacentEpisode(offset: -1) }
        }
        playerController.onSelectEpisode = { [weak self] number in
            Task { await self?.playSelectedEpisode(number) }
        }
        playerController.onListReleases = { [weak self] completion in
            Task { @MainActor in
                guard let self else { return completion([], nil) }
                do {
                    completion(try await self.playbackReleaseCandidates(), nil)
                } catch {
                    completion([], error.localizedDescription)
                }
            }
        }
        playerController.onSelectRelease = { [weak self] name in
            // Through `activeResolveTask`, like the detail page's own play
            // path: the "Finding a stream" overlay this raises has a Cancel
            // button, and that button cancels whatever task is parked
            // there. Left unset it would have cancelled the previous play's
            // task, hidden the overlay, and let this resolve land anyway.
            self?.activeResolveTask = Task { [weak self] in
                await self?.switchRelease(to: name)
            }
        }
    }

    /// The same "Stream Servers" list the detail page offers, for the
    /// episode that is *playing*. Keyed on `currentPlayback*` rather than
    /// `selectedMediaDetails`, which is the open page: a play from the Up
    /// Next shelf opens no page at all, and the mini-player lets another
    /// title's page be opened mid-episode. Throws rather than answering
    /// with an empty list, because "the indexers returned nothing" and
    /// "the search failed" are not the same thing to show.
    public func playbackReleaseCandidates() async throws -> [MediaDetailView.ReleaseCandidateItem] {
        guard let engine, let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode else { return [] }
        let choices = try await engine.listReleaseCandidates(
            catalog: currentPlaybackCatalog,
            catalogId: catalogId,
            episode: episode,
            title: currentPlaybackTitle
        )
        return choices.map {
            MediaDetailView.ReleaseCandidateItem(name: $0.name, seeders: Int($0.seeders), isDub: $0.isDub)
        }
    }

    /// Replays the current episode from a different release, where the
    /// viewer had got to.
    public func switchRelease(to releaseName: String) async {
        guard let engine, let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode else { return }
        let previousURL = activeStreamURL
        let resumeAt = Int64(playerController.currentTime)
        let duration = Int64(playerController.duration)
        let catalog = currentPlaybackCatalog
        // `resolveAndPlay` takes the position to open at from the registry,
        // not from the player, and the once-a-second tick that writes it
        // runs on `engineIOQueue`. Writing this one on that queue and
        // waiting for it puts it behind any tick already in flight and in
        // front of the read; written inline on this actor instead, a tick
        // queued a moment ago could land after it and rewind the switch to
        // wherever that tick had been.
        if resumeAt > 0 {
            await withCheckedContinuation { continuation in
                engineIOQueue.async {
                    try? engine.recordProgress(
                        catalog: catalog,
                        catalogId: catalogId,
                        episodeNumber: episode,
                        stopTime: resumeAt,
                        duration: duration
                    )
                    continuation.resume()
                }
            }
        }
        do {
            _ = try await resolveAndPlay(
                catalog: catalog,
                catalogId: catalogId,
                episode: episode,
                title: currentPlaybackTitle,
                chosenName: releaseName
            )
            // A chosen release that resolves back to the stream already
            // playing hands `MpvSurface.loadFile` a URL it has, so it opens
            // no file and no MPV_EVENT_FILE_LOADED arrives to lower the
            // gate `resolveAndPlay` raised — every position tick from here
            // on would be dropped as the outgoing file's.
            if activeStreamURL == previousURL {
                playerController.awaitingNewFile = false
            }
        } catch is CancellationError {
            // Cancel on the resolve overlay, not a failure.
        } catch {
            errorMessage = "Failed to switch release: \(error.localizedDescription)"
        }
    }

    /// Points `playbackEpisodes` at the right list for `catalogId`: the open
    /// page's list when it is the same title, otherwise a fetch (served from
    /// the engine's hour-long detail cache on any title opened recently).
    /// The fetch runs alongside the resolve rather than ahead of it, and
    /// the navigation state is recomputed when it lands.
    func ensurePlaybackEpisodes(for catalogId: Int64, engine: AnicatEngine) {
        if selectedMediaDetails?.id == catalogId, !selectedEpisodes.isEmpty {
            playbackEpisodes = selectedEpisodes
            playbackEpisodesCatalogId = catalogId
            playbackMalId = selectedMediaDetails?.malId
            return
        }
        guard playbackEpisodesCatalogId != catalogId || playbackEpisodes.isEmpty else { return }
        playbackEpisodes = []
        playbackEpisodesCatalogId = catalogId
        playbackCoverURL = nil
        // Cleared with the rest of the playing title's metadata, or the
        // previous title's id would be handed to AniSkip for this one until
        // the fetch below lands — the same wrong-title bug `playbackMalId`
        // exists to fix.
        playbackMalId = nil
        Task { [weak self] in
            guard let detail = try? await engine.mediaDetail(catalogId: catalogId, isManga: false) else { return }
            guard let self, self.currentPlaybackCatalogId == catalogId else { return }
            self.playbackEpisodes = Self.episodeItems(from: detail)
            self.playbackCoverURL = URL(string: detail.coverImage)
            self.playbackMalId = detail.malId
            self.updateEpisodeNavigationState()
            // This fetch runs alongside the resolve, so it usually lands
            // after `resolveAndPlay` has already asked once and found no id.
            // Asking again here is what makes AniSkip work for a play with
            // no page open at all.
            if let episode = self.currentPlaybackEpisode {
                self.requestAniSkipTimes(catalogId: catalogId, episode: episode)
            }
        }
    }

    /// Fetches and applies the intro/outro windows for one episode, if the
    /// playing title has a MyAnimeList id to key them by. Called twice per
    /// episode at most — once when the resolve returns and once when the
    /// detail fetch above lands — because whichever of the two knows the
    /// MAL id first should be the one that starts the request.
    func requestAniSkipTimes(catalogId: Int64, episode: Int64) {
        guard currentPlaybackCatalog == .anilist else { return }
        // The open page counts only when it *is* this title; otherwise its
        // MAL id belongs to whatever the viewer navigated to since.
        let pageMalId = selectedMediaDetails?.id == catalogId ? selectedMediaDetails?.malId : nil
        guard let malId = playbackMalId ?? pageMalId else {
            // Was silent — "AniSkip doesn't work" with nothing to say why is
            // exactly this case: no MAL cross-reference means there was
            // never going to be a request, not that one failed. It is not
            // yet the final answer for a play with no page open: the detail
            // fetch may still be in flight, and it asks again when it lands.
            print("[AniSkip] no MAL id known for AniList id \(catalogId) — no skip times requested")
            return
        }
        let episodeNumber = Int(episode)
        let episodeLength = playerController.duration
        Task { [weak self] in
            let times = await AniSkipClient.skipTimes(malId: malId, episode: episodeNumber, episodeLengthSeconds: episodeLength)
            guard let self else { return }
            // The viewer may have already moved on (next/prev, closed the
            // player) by the time this lands — a stale result applied to
            // whatever's playing now would show the wrong episode's skip
            // window.
            guard self.currentPlaybackCatalogId == catalogId, self.currentPlaybackEpisode == episode else { return }
            self.playerController.setAniSkipTimes(times)
        }
    }

    public func playSelectedEpisode(_ number: Int) async {
        guard let catalogId = currentPlaybackCatalogId else { return }
        guard playbackEpisodes.contains(where: { $0.number == number }) else { return }
        do {
            _ = try await resolveAndPlay(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: Int64(number)
            )
        } catch {
            errorMessage = "Failed to load episode \(number): \(error.localizedDescription)"
        }
    }

    /// Advances or rewinds one entry in `playbackEpisodes` from whatever is
    /// currently playing.
    public func playAdjacentEpisode(offset: Int) async {
        guard let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode else { return }
        let sorted = playbackEpisodes
        guard let index = sorted.firstIndex(where: { $0.number == Int(episode) }) else { return }
        let targetIndex = index + offset
        guard sorted.indices.contains(targetIndex) else { return }
        let target = sorted[targetIndex]
        do {
            _ = try await resolveAndPlay(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: Int64(target.number)
            )
        } catch {
            errorMessage = "Failed to load episode \(target.number): \(error.localizedDescription)"
        }
    }

    /// Recomputes whether the player's next/prev buttons have anywhere to
    /// go, against `playbackEpisodes` — called after every episode change
    /// and whenever that list arrives, since it (and the current position
    /// within it) is the only thing that decides it.
    func updateEpisodeNavigationState() {
        let sorted = playbackEpisodes
        playerController.episodeList = sorted
        guard let episode = currentPlaybackEpisode else {
            playerController.hasNextEpisode = false
            playerController.hasPreviousEpisode = false
            return
        }
        guard let index = sorted.firstIndex(where: { $0.number == Int(episode) }) else {
            playerController.hasNextEpisode = false
            playerController.hasPreviousEpisode = false
            return
        }
        playerController.hasNextEpisode = sorted.indices.contains(index + 1)
        playerController.hasPreviousEpisode = sorted.indices.contains(index - 1)
        refreshNowPlayingMetadata()
    }

    /// Republishes the Now Playing tile from what is known right now. Runs
    /// with every navigation-state recompute because the two late arrivals
    /// (the episode title from `playbackEpisodes`, the cover from the
    /// detail fetch) both land through `updateEpisodeNavigationState`;
    /// publishing once at play time showed a bare episode number and no
    /// artwork for anything started from the Up Next shelf.
    func refreshNowPlayingMetadata() {
        guard activeStreamURL != nil, let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode else { return }
        let track = NowPlayingBridge.Track(
            title: currentPlaybackTitle ?? playerController.title,
            episodeNumber: Int(episode),
            episodeTitle: playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        )
        let pageCover = selectedMediaDetails?.id == catalogId ? selectedMediaDetails?.coverURL : nil
        nowPlaying.setTrack(
            track,
            elapsed: playerController.currentTime,
            duration: playerController.duration,
            rate: playerController.isPlaying ? playerController.playbackRate : 0,
            coverURL: pageCover ?? playbackCoverURL ?? knownCovers[catalogId]
        )
        nowPlaying.setNavigation(
            hasNext: playerController.hasNextEpisode,
            hasPrevious: playerController.hasPreviousEpisode
        )
    }

    /// The one place that follows "is an episode playing right now": every
    /// `isPlaying` edge (`PlayerController.onPlayingStateChange`), each new
    /// stream in `resolveAndPlay`, and `stopPlayback`. Anything whose
    /// lifetime is "while video is on" hangs off this so a pause, a
    /// transition and a close cannot each forget one of them.
    func syncPlaybackSession() {
        guard activeStreamURL != nil else {
            sleepBlocker.release()
            nowPlaying.clear()
            return
        }
        if playerController.isPlaying, let episode = currentPlaybackEpisode {
            let title = currentPlaybackTitle ?? playerController.title
            sleepBlocker.hold(reason: "Anicat is playing \(title), episode \(episode)")
        } else {
            // Paused is idle as far as the viewer is concerned: a laptop
            // left on a paused frame should sleep like any other.
            sleepBlocker.release()
        }
        nowPlaying.updateProgress(
            elapsed: playerController.currentTime,
            duration: playerController.duration,
            rate: playerController.isPlaying ? playerController.playbackRate : 0
        )
    }

    /// "Stream Servers": every release the indexers found for this episode.
    public func loadReleaseCandidates(episode: Int) async -> [MediaDetailView.ReleaseCandidateItem] {
        guard let engine, let details = selectedMediaDetails else { return [] }
        do {
            let choices = try await engine.listReleaseCandidates(
                catalog: .anilist,
                catalogId: details.id,
                episode: Int64(episode),
                title: details.title
            )
            return choices.map {
                MediaDetailView.ReleaseCandidateItem(name: $0.name, seeders: Int($0.seeders), isDub: $0.isDub)
            }
        } catch {
            return []
        }
    }

    /// Starts a "Download Episode" and polls its progress into
    /// `downloadStates` until it finishes, one way or the other. The poll
    /// loop is the only client of `episodeDownloadStatus` — the row itself
    /// just reads `downloadStates[episode]`, same as every other piece of
    /// reactive state this model exposes.
    public func startDownload(episode: Int) async {
        guard let engine, let details = selectedMediaDetails else { return }
        guard downloadStates[episode] == nil || downloadStates[episode] == .notStarted else { return }
        downloadStates[episode] = .downloading(percent: 0)
        setLibraryDownload(catalogId: details.id, episode: episode, title: details.title, coverURL: details.coverURL, state: .downloading(percent: 0))
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        do {
            try await engine.startEpisodeDownload(
                catalog: .anilist,
                catalogId: details.id,
                episode: Int64(episode),
                title: details.title,
                preferDub: preferDub
            )
        } catch {
            downloadStates[episode] = .failed(message: error.localizedDescription)
            setLibraryDownload(catalogId: details.id, episode: episode, title: details.title, coverURL: details.coverURL, state: .failed(message: error.localizedDescription))
            return
        }

        // Captured up front rather than re-read from `selectedMediaDetails`
        // each tick — the detail page can move to a different title mid-poll
        // and this loop must keep tracking the episode it started for, not
        // whatever happens to be open.
        let catalogId = details.id
        let title = details.title
        let coverURL = details.coverURL
        while true {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            let status = await engine.episodeDownloadStatus(
                catalog: .anilist,
                catalogId: catalogId,
                episode: Int64(episode)
            )
            let mirrorToDetailPage = selectedMediaDetails?.id == catalogId
            switch status {
            case .notStarted:
                if mirrorToDetailPage { downloadStates[episode] = .notStarted }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .notStarted)
            case .downloading(let percent):
                if mirrorToDetailPage { downloadStates[episode] = .downloading(percent: percent) }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .downloading(percent: percent))
                continue
            case .done(let path):
                if mirrorToDetailPage { downloadStates[episode] = .done(path: path) }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .done(path: path))
            case .failed(let message):
                if mirrorToDetailPage { downloadStates[episode] = .failed(message: message) }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .failed(message: message))
            }
            return
        }
    }

    func setLibraryDownload(catalogId: Int64, episode: Int, title: String, coverURL: URL?, state: MediaDetailView.EpisodeDownloadState) {
        if let idx = libraryDownloads.firstIndex(where: { $0.catalogId == catalogId && $0.episode == episode }) {
            libraryDownloads[idx].state = state
        } else {
            libraryDownloads.append(LibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: state))
        }
    }

    /// Handles real-time playback position changes from the player and records to SQLite.
    ///
    /// The Discord Rich Presence write and the SQLite progress write are both
    /// blocking calls into the Rust core — `discord_rich_presence`'s IPC
    /// write can stall for as long as Discord's own read side does, and this
    /// used to run synchronously on the main thread on every pause/resume
    /// and once a second during playback. A single slow Discord write froze
    /// the whole player: mpv had already paused internally, but the redraw
    /// mpv's update callback queues onto the main thread (see
    /// `MpvSurface`'s render callback) couldn't run until the blocked
    /// call returned, so the screen and the play/pause button both sat
    /// frozen for however long that took. Both calls are dispatched off the
    /// main thread below; only the cheap bookkeeping (dedup flags,
    /// `ContinuityManager`) stays synchronous.
    public func handlePlaybackPositionChange(currentTime: Double, duration: Double) {
        guard let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let engine else { return }

        let rawStop = Int64(currentTime)
        let dur = Int64(duration)
        let stopTime = dur > 0 ? min(rawStop, dur) : rawStop
        guard stopTime >= 0 else { return }

        let isPaused = !playerController.isPlaying
        let pauseEdgeChanged = isPaused != lastDiscordPaused
        if pauseEdgeChanged {
            lastDiscordPaused = isPaused
        }

        // Auto-advance AniList progress past the same 85% line that counts
        // an episode "watched" elsewhere, so bingeing through the built-in
        // player keeps the AniList list in sync the way ticking the episode
        // list's checkbox by hand already does — without this, only that
        // manual checkbox ever moved AniList's progress, while the local
        // watch-history registry (and so the resume offer) advanced on every
        // episode played. The two tracked different things and the resume
        // offer could point well past whatever AniList actually showed.
        if currentPlaybackCatalog == .anilist, !hasAdvancedAniListForCurrentEpisode, dur > 0 {
            let percent = Double(stopTime) / Double(dur) * 100
            if percent >= Self.watchedThresholdPct {
                hasAdvancedAniListForCurrentEpisode = true
                // Reuses the episode list's own mark-watched path (status
                // transitions, COMPLETED-on-last-episode clamp) when the
                // detail page is open, and sends the same mutation itself
                // when it isn't — see `advanceAniListProgress`.
                Task { await self.advanceAniListProgress(catalogId: catalogId, episode: Int(episode)) }
            }
        }

        // Resolve the next episode into the second selected-file slot before
        // it is needed. Without this every auto-next was a cold resolve, a
        // black gap between episodes for as long as search plus pre-buffer
        // took. The result is not read here; the real play hits the reuse
        // path in `TorrentManager::resolve`. `preload: true` keeps it from
        // taking the playing-file pin off the episode mpv is reading.
        if currentPlaybackCatalog == .anilist, !hasPreloadedNextEpisode, dur > 0,
           playerController.hasNextEpisode,
           Double(stopTime) / Double(dur) * 100 >= Self.nextEpisodePreloadPct {
            hasPreloadedNextEpisode = true
            let sorted = playbackEpisodes
            if let index = sorted.firstIndex(where: { $0.number == Int(episode) }),
               sorted.indices.contains(index + 1) {
                let next = Int64(sorted[index + 1].number)
                let req = StreamRequest(
                    catalog: .anilist,
                    catalogId: catalogId,
                    episode: next,
                    title: currentPlaybackTitle,
                    preferDub: UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed",
                    chosenName: nil,
                    resumeFraction: nil,
                    preload: true
                )
                Task.detached(priority: .utility) {
                    do {
                        _ = try await engine.resolveStream(req: req)
                    } catch {
                        // A failed preload costs nothing visible: the real
                        // play resolves cold exactly as it did before.
                        print("[preload] episode \(next) not preloaded: \(error)")
                    }
                }
            }
        }

        // Auto-play-next: same near-end-of-duration check as the watched
        // threshold above, gated on the setting and on there being a next
        // episode at all. `playAdjacentEpisode` reuses the ordinary
        // next-episode path (episode list refresh, resume state, everything
        // `nextEpisode()`'s manual button already does) rather than
        // duplicating it here.
        if !hasAutoAdvancedEpisode, dur > 0, Double(dur) - currentTime <= Self.autoAdvanceRemainingSeconds,
           playerController.autoPlayNextEnabled, playerController.hasNextEpisode {
            hasAutoAdvancedEpisode = true
            Task { await self.playAdjacentEpisode(offset: 1) }
        }

        // Only record if whole second changed and valid
        let secondChanged = stopTime != lastRecordedSecond
        guard pauseEdgeChanged || secondChanged else { return }
        if secondChanged {
            lastRecordedSecond = stopTime
            // Pause edges reach the tile through `syncPlaybackSession`;
            // this is only the once-a-second elapsed time, three keys on a
            // dictionary already built.
            nowPlaying.updateProgress(
                elapsed: currentTime,
                duration: duration,
                rate: isPaused ? 0 : playerController.playbackRate
            )
        }

        let title = currentPlaybackTitle ?? "Anime"
        let episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        let totalEpisodes = Int64(selectedMediaDetails?.episodeCount ?? 0)
        let catalog = currentPlaybackCatalog
        // Read here rather than inside the closure: the queue runs behind
        // whatever a stalled Discord write is doing, so a value read there
        // is the setting as of whenever that unblocks, not as of this tick.
        let discordEnabled = Self.isDiscordPresenceEnabled

        engineIOQueue.async {
            if pauseEdgeChanged, discordEnabled {
                engine.discordSetPresence(
                    title: title,
                    episode: episode,
                    episodeTitle: episodeTitle,
                    totalEpisodes: totalEpisodes,
                    pos: stopTime,
                    duration: dur,
                    paused: isPaused
                )
            }
            if secondChanged {
                try? engine.recordProgress(
                    catalog: catalog,
                    catalogId: catalogId,
                    episodeNumber: episode,
                    stopTime: stopTime,
                    duration: dur
                )
                if !isPaused, discordEnabled {
                    engine.discordSetPresence(
                        title: title,
                        episode: episode,
                        episodeTitle: episodeTitle,
                        totalEpisodes: totalEpisodes,
                        pos: stopTime,
                        duration: dur,
                        paused: false
                    )
                }
            }
        }

        if secondChanged {
            ContinuityManager.shared.advertisePlayback(
                catalogId: catalogId,
                title: title,
                episode: Int(episode),
                timePositionSeconds: currentTime
            )
        }
    }

    /// Stops playback, records final progress into SQLite, and clears the Apple Handoff broadcast.
    public func stopPlayback() {
        // Both calls are IPC writes into the Rust engine — `recordProgress`
        // hits SQLite, `discordClearPresence` hits Discord's socket, and the
        // comment on `handlePlaybackPositionChange` already documents that a
        // slow Discord read side can stall a call like this for as long as
        // Discord takes to answer. Closing the player is the one action a
        // viewer expects to be instant; running these inline on the main
        // actor reintroduces the exact freeze that method was detached to fix.
        if let engine, let catalogId = currentPlaybackCatalogId, let episode = currentPlaybackEpisode {
            let dur = Int64(playerController.duration)
            let rawStop = Int64(playerController.currentTime)
            let stopTime = dur > 0 ? min(rawStop, dur) : rawStop
            let catalog = currentPlaybackCatalog
            engineIOQueue.async {
                try? engine.recordProgress(
                    catalog: catalog,
                    catalogId: catalogId,
                    episodeNumber: episode,
                    stopTime: stopTime,
                    duration: dur
                )
                engine.discordClearPresence()
            }
        } else {
            engine?.discordClearPresence()
        }
        // Release the playing-file pin and pause the session's torrents.
        // Without it a closed player kept downloading the rest of the
        // episode, and the preloaded next one, at full speed.
        if let engine {
            Task.detached(priority: .utility) { await engine.playbackStopped() }
        }
        self.activeStreamURL = nil
        self.isPlayerMinimized = false
        self.currentPlaybackCatalogId = nil
        self.currentPlaybackEpisode = nil
        self.currentPlaybackTitle = nil
        resetPerEpisodeDedupState(discordPaused: nil)
        playerController.hasNextEpisode = false
        playerController.hasPreviousEpisode = false
        playerController.episodeList = []
        playbackEpisodes = []
        playbackEpisodesCatalogId = nil
        playbackCoverURL = nil
        playbackMalId = nil
        ContinuityManager.shared.stopAdvertising()
        syncPlaybackSession()

        // Pinned to the main actor rather than inheriting the caller's
        // context: from the app this is always main, but a test calling
        // stopPlayback from a nonisolated context ran this on a cooperative
        // thread, and reading selectedMediaDetails there while the main
        // thread replaced it was a SIGBUS on a freed HeroBanner.Details.
        Task { @MainActor in
            await loadHistory()
            if let currentDetails = selectedMediaDetails {
                await loadDetail(id: currentDetails.id, isManga: Self.isMangaFormat(currentDetails.format))
            }
        }
    }

    /// Races `resolveStream` against a plain timer so a stalled search or a
    /// dead swarm fails fast with a clear message instead of hanging with no
    /// ceiling at all. Returns just the stream URL string — `StreamHandle`
    /// itself isn't `Sendable` (a plain uniffi-generated struct), and the
    /// URL is the only field any caller reads.
    static func resolveWithTimeout(
        engine: AnicatEngine,
        req: StreamRequest,
        timeoutSeconds: Double
    ) async throws -> String {
        // `StreamRequest` is a plain uniffi-generated value struct — no
        // shared mutable state — but isn't marked `Sendable`, so the strict
        // concurrency checker won't let it cross into `addTask`'s closure
        // without this box making the "trust me" explicit.
        final class UncheckedBox<T>: @unchecked Sendable { let value: T; init(_ value: T) { self.value = value } }
        let boxedReq = UncheckedBox(req)
        return try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await engine.resolveStream(req: boxedReq.value).url }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                throw NSError(
                    domain: "Anicat",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "No stream found after \(Int(timeoutSeconds))s. The search or download may be stalled — try again, or try a different episode."]
                )
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Resolves a torrent release and prepares the stream URL for playback.
    ///
    /// `fromStart` plays the episode from 0 regardless of what the registry
    /// has recorded for it — the detail page's "Start over" next to
    /// "Resume". Progress recording is untouched: the tick overwrites the
    /// stored position from wherever this play actually reaches.
    public func resolveAndPlay(
        catalog: FfiCatalog = .anilist,
        catalogId: Int64,
        episode: Int64,
        title: String? = nil,
        chosenName: String? = nil,
        fromStart: Bool = false
    ) async throws -> URL {
        let effectiveTitle = title ?? self.selectedMediaDetails?.title ?? self.knownTitles[catalogId] ?? "Anime"
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.isPlaying = true

        guard let engine else {
            throw NSError(domain: "Anicat", code: 1, userInfo: [NSLocalizedDescriptionKey: "Engine not initialized"])
        }

        isLoading = true
        defer { isLoading = false }

        // From here on, anything mpv reports belongs to the outgoing file,
        // unless this is the same episode being asked for again: then no
        // new file will load, no FILE_LOADED will clear the gate, and the
        // numbers mpv is emitting are the right file's already. A named
        // release is the exception — same episode, different file — and
        // without that term the outgoing file's last ticks arrived against
        // the dedup flags this call had just reset, re-firing the AniList
        // advance and the N+1 preload, and auto-advancing outright when the
        // switch happened near the end of an episode.
        let replayingCurrent = activeStreamURL != nil
            && currentPlaybackCatalogId == catalogId
            && currentPlaybackEpisode == episode
            && chosenName == nil
        self.currentPlaybackCatalog = catalog
        self.currentPlaybackCatalogId = catalogId
        self.currentPlaybackEpisode = episode
        self.playerController.awaitingNewFile = !replayingCurrent
        // Only a release asked for by name is a release the player can tick
        // in its list; an ordinary play is whatever the engine's own race
        // landed on, which it does not report back.
        self.playerController.currentReleaseName = chosenName
        ensurePlaybackEpisodes(for: catalogId, engine: engine)
        self.currentPlaybackTitle = effectiveTitle
        // A fresh play always opens full-screen, not stuck minimized from
        // whatever the last session left it as.
        self.isPlayerMinimized = false
        resetPerEpisodeDedupState(discordPaused: false)
        // Cleared up front rather than left showing the previous episode's
        // skip window for however long the fetch below takes.
        self.playerController.setAniSkipTimes(nil)
        // Same reasoning: a new episode's overlay shouldn't briefly letterbox
        // itself against the last episode's aspect ratio before mpv reports
        // the new one.
        self.playerController.videoDisplayWidth = nil
        self.playerController.videoDisplayHeight = nil

        // Restore any existing progress from SQLite or media metadata
        var initialDuration: Double = 0.0
        var initialTime: Double = 0.0
        // Only from the recorded (real) duration, never the AniList runtime
        // estimate below — that's a flat ~24min for every episode, and an
        // estimate-of-an-estimate byte offset would tell the Rust pre-buffer
        // gate to warm the wrong part of the file.
        var resumeFraction: Double?
        // Skipped wholesale for "Start over" rather than zeroed afterwards:
        // `resumeFraction` has to stay nil so the Rust pre-buffer gate warms
        // the head of the file, and `initialTime` has to stay 0 so
        // `MpvSurface` omits `--start` (it only passes one for
        // `currentTime > 0`). The recorded duration below is still worth
        // reading for the progress bar, so the fallback that fills it from
        // the AniList runtime keeps working either way.
        if !fromStart,
           let progress = try? engine.getProgress(catalog: catalog, catalogId: catalogId, episodeNumber: episode) {
            initialTime = Double(progress.stopTime)
            initialDuration = Double(progress.duration)
            if initialTime > 0, initialDuration > 0 {
                resumeFraction = initialTime / initialDuration
            }
        }
        if initialDuration <= 0 {
            if let ep = playbackEpisodes.first(where: { $0.number == Int(episode) }),
               let runtime = ep.runtimeMinutes, runtime > 0 {
                initialDuration = Double(runtime * 60)
            }
        }
        self.playerController.currentTime = initialTime
        self.playerController.duration = initialDuration

        // Tells the torrent resolve's pre-buffer gate where mpv's `--start`
        // will actually land, so it warms that region of the swarm instead of
        // only proving byte 0 is healthy and handing off to a resume seek
        // that stalls forever on an unprioritized piece.
        // Settings' Sub/Dub picker was write-only until now — nothing read
        // `anicat_sub_dub` back, so choosing "Dubbed" changed nothing about
        // which release got picked.
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let req = StreamRequest(
            catalog: catalog,
            catalogId: catalogId,
            episode: episode,
            title: effectiveTitle,
            preferDub: preferDub,
            chosenName: chosenName,
            resumeFraction: resumeFraction,
            preload: false
        )

        // Real feedback instead of a bare spinner: resolve is a single
        // opaque FFI call with no intermediate progress at all (unlike
        // `torrent/search.rs`'s own internal racing/grace-period logic,
        // which the timeout below mirrors), so the UI has nothing to show
        // except how long it's been waiting. And with no ceiling at all, a
        // stalled search or a dead swarm hung here indefinitely — three
        // minutes staring at a spinner with no way out, not a fast failure.
        resolveStartedAt = Date()
        defer { resolveStartedAt = nil }
        // 120s, not the original 45: `torrent/mod.rs`'s own `PREBUFFER_TIMEOUT`
        // is 40s *per candidate*, and a legitimate resolve can burn through
        // several tiers of fallback (the raced pair, the sequential rest of
        // the shortlist, then an extended pool of 6 more) before landing on
        // one that actually works — a real measured case in that file's own
        // comments describes 17 candidates, all four shortlisted ones dead,
        // before it succeeded further down the pool. 45s was cutting that
        // process off mid-fallback, not just catching genuinely stuck
        // resolves — likely exactly what happened resuming episode 9 here:
        // picking a specific release manually skips the fallback chain
        // entirely and went straight to a release that worked, instantly.
        let handleURL: String
        do {
            handleURL = try await Self.resolveWithTimeout(engine: engine, req: req, timeoutSeconds: 120)
            // The Cancel button (`cancelResolve`) only cancels *waiting* on
            // this Task, not the FFI call itself mid-flight — check here so
            // a resolve that finishes after the viewer already gave up
            // doesn't start playback anyway.
            guard !Task.isCancelled else {
                throw CancellationError()
            }
        } catch {
            // No new file is coming; whatever is still playing owns the
            // position again.
            self.playerController.awaitingNewFile = false
            throw error
        }
        guard let streamURL = URL(string: handleURL) else {
            self.playerController.awaitingNewFile = false
            throw NSError(domain: "Anicat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL: \(handleURL)"])
        }

        // Before returning streamURL, configure playerController with actual title, episode number, and duration
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        self.playerController.isPlaying = true
        if self.playerController.duration <= 0 && initialDuration > 0 {
            self.playerController.duration = initialDuration
        }

        // Same explicit curve/duration the detail page's own open/close uses
        // (`closeDetail`, `loadDetail`) rather than leaning on a bare
        // `.animation(value:)` modifier at the view side — relying on that
        // alone left the player's entrance timed by whatever SwiftUI's
        // default "smooth" spring happens to be, uncoordinated with
        // everything else that's mounting at the same instant (the chrome
        // bars' own appear animation, the mini-player fading out if it was
        // showing), which is what read as jittery rather than one clean
        // transition.
        withAnimation(.easeInOut(duration: 0.32)) {
            self.activeStreamURL = streamURL
        }
        // Replaying the episode already loaded produces the same stream URL,
        // so `MpvSurface` sees no change and never reopens the file — the
        // `--start` argument that normally carries `fromStart` is only read
        // when a file is opened. Without an explicit seek, "Start over" on
        // the loaded episode set `currentTime` to 0 and the next position
        // tick put it straight back.
        if fromStart, replayingCurrent {
            self.playerController.seek(to: 0)
        }
        // Publishes the Now Playing tile as a side effect, here and not on
        // the first position tick: media keys route to the app only once
        // the tile is up with `playbackState == .playing`, and mpv has not
        // yet been handed the URL, so this is before the first frame.
        updateEpisodeNavigationState()
        syncPlaybackSession()

        // AniSkip is keyed by MAL id, so only anime (not the other catalogs
        // `resolveAndPlay` might grow) and only titles AniList actually has a
        // MAL mapping for. Fire-and-forget: skip times are a nicety, not
        // worth delaying the return of `streamURL` over.
        requestAniSkipTimes(catalogId: catalogId, episode: episode)

        // Apple Handoff: broadcast current playback activity to iPhone / iPad / Mac
        ContinuityManager.shared.advertisePlayback(
            catalogId: catalogId,
            title: effectiveTitle,
            episode: Int(episode),
            timePositionSeconds: playerController.currentTime
        )

        if Self.isDiscordPresenceEnabled {
            engine.discordSetPresence(
                title: effectiveTitle,
                episode: episode,
                episodeTitle: playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? "",
                totalEpisodes: Int64(selectedMediaDetails?.episodeCount ?? 0),
                pos: Int64(playerController.currentTime),
                duration: Int64(playerController.duration),
                paused: false
            )
        }

        return streamURL
    }
}
