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
        // Not left to `resolveAndPlay`'s own exit: the FFI call it waits on
        // cannot be cancelled (uniffi's Swift bridge polls the Rust future to
        // completion), so that exit comes whenever the engine returns, and
        // until then the poller wrote the line straight back under a spinner
        // the viewer had just dismissed.
        activeResolvePoller?.cancel()
        activeResolvePoller = nil
        resolveStartedAt = nil
        isLoading = false
        playerController.resolveStatus = nil
        playerController.resolveElapsedSeconds = nil
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
        playbackSessionStartedAt = Date()
        // Fifth flag, same rule: the countdown card's "cancelled" is scoped
        // to one episode, and a cancel that survived into the next one would
        // silently disable auto-next for the rest of the binge.
        playerController.nextEpisodeCountdown.reset()
    }

    /// Puts back the episode identity `resolveAndPlay` wrote on its way in,
    /// after a resolve that never produced a stream.
    ///
    /// The per-episode dedup flags are *claimed*, not reset: the episode
    /// still on screen is the one that was already advanced on AniList,
    /// already preloaded from, and already auto-advanced out of. Left clear,
    /// the next position tick (a second later, still past the auto-next mark
    /// because the file never changed) fired auto-next again, and again, for
    /// as long as the episode ran.
    func restorePlaybackIdentity(
        _ previous: (
            catalog: FfiCatalog,
            catalogId: Int64?,
            episode: Int64?,
            title: String?,
            playerTitle: String,
            episodeNumber: Int,
            episodeTitle: String,
            releaseName: String?,
            wasPlaying: Bool
        )
    ) {
        guard previous.wasPlaying else { return }
        currentPlaybackCatalog = previous.catalog
        currentPlaybackCatalogId = previous.catalogId
        currentPlaybackEpisode = previous.episode
        currentPlaybackTitle = previous.title
        playerController.title = previous.playerTitle
        playerController.episodeNumber = previous.episodeNumber
        playerController.episodeTitle = previous.episodeTitle
        playerController.currentReleaseName = previous.releaseName
        hasAdvancedAniListForCurrentEpisode = true
        hasAutoAdvancedEpisode = true
        hasPreloadedNextEpisode = true
        updateEpisodeNavigationState()
        syncPlaybackSession()
    }

    /// The catalog name Handoff carries. A bare id names three different
    /// titles across the catalogs, so the receiving device needs this to know
    /// which one was playing.
    nonisolated static func handoffCatalog(_ catalog: FfiCatalog) -> String {
        switch catalog {
        case .tmdbMovie: return "tmdb_movie"
        case .tmdbTv: return "tmdb_tv"
        default: return "anilist"
        }
    }

    func playFeedback(_ sound: AppSounds) {
        sound.play()
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
        playerController.onRecordTrackMemory = { [weak self] memory in
            Task { @MainActor in self?.recordTrackMemory(memory) }
        }
        playerController.onReloadForAudioLanguage = { [weak self] preferDub in
            self?.reloadCurrentEpisodeForAudioLanguage(preferDub: preferDub)
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
        // Read once here, beside the list it tags, and only if the episode
        // is still the one the list was asked for: the search above is a
        // live wave across three indexers, and Next can land mid-flight.
        if currentPlaybackCatalogId == catalogId, currentPlaybackEpisode == episode {
            playerController.rememberedReleaseName = engine.rememberedReleaseName(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: episode,
                preferDub: UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
            )
        }
        return choices.map {
            MediaDetailView.ReleaseCandidateItem(name: $0.name, seeders: Int($0.seeders), isDub: $0.isDub)
        }
    }

    /// Replays the current episode from a different release, where the
    /// viewer had got to.
    public func switchRelease(to releaseName: String) async {
        await swapPlayingFile(chosenName: releaseName, forceNewFile: false)
    }

    /// Puts a different file behind the player without closing it.
    ///
    /// Shared by the release picker and by the Sub/Dub row's "find a dub of
    /// this episode": both are the same move -- resolve this episode again
    /// under different terms and hand mpv the new URL. The player view stays
    /// mounted throughout (`activeStreamURL` never goes nil), so this is a
    /// file swap, not a close and reopen.
    private func swapPlayingFile(chosenName: String?, forceNewFile: Bool) async {
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
                chosenName: chosenName,
                forceNewFile: forceNewFile
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
            // No "Failed to switch release:" lead: `resolveAndPlay` throws a
            // `PlaybackFailure` whose description is already the sentence
            // to show, and a second lead in front of it read as two errors.
            errorMessage = error.localizedDescription
            playFeedback(.error)
        }
    }

    /// Re-fetches the playing episode in the other language.
    ///
    /// Pressing Dub during an episode whose release carries only Japanese
    /// audio could previously do nothing but change what the *next* episode
    /// searched for -- the switch read as broken. The Sub/Dub row offers this
    /// when, and only when, `onSelectAudioLanguage` reports that the file has
    /// no track in the language asked for.
    ///
    /// `anicat_sub_dub` is already written by the row itself and
    /// `resolveAndPlay` reads it, so the search asks for the new language.
    /// The engine's remembered release and its resolved-stream cache are both
    /// keyed on `prefer_dub`, so neither hands back the file that was just
    /// rejected.
    public func reloadCurrentEpisodeForAudioLanguage(preferDub: Bool) {
        guard currentPlaybackCatalogId != nil, currentPlaybackEpisode != nil else { return }
        activeResolveTask?.cancel()
        activeResolveTask = Task { [weak self] in
            guard let self else { return }
            await self.swapPlayingFile(chosenName: nil, forceNewFile: true)
            // `swapPlayingFile` reports its own failures as "Failed to switch
            // release", which says nothing about what was asked for here.
            if self.errorMessage != nil {
                self.errorMessage = "No \(preferDub ? "dub" : "sub") found for this episode."
            }
        }
    }

    /// Points `playbackEpisodes` at the right list for `catalogId`: the open
    /// page's list when it is the same title, otherwise a fetch (served from
    /// the engine's hour-long detail cache on any title opened recently).
    /// The fetch runs alongside the resolve rather than ahead of it, and
    /// the navigation state is recomputed when it lands.
    func ensurePlaybackEpisodes(
        for catalogId: Int64,
        engine: AnicatEngine,
        catalog: FfiCatalog = .anilist
    ) {
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
            // A film or an episode of a series has no AniList entry to ask
            // for, and `mediaDetail` would answer for whatever anime happens
            // to carry the same number.
            let fetched: MediaDetail? = catalog == .anilist
                ? try? await engine.mediaDetail(catalogId: catalogId, isManga: false)
                : try? await engine.cinemaDetail(catalog: catalog, catalogId: catalogId)
            guard let detail = fetched else { return }
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
        // The first call lands before mpv has been handed the URL, when
        // `duration` is 0 or still the previous file's. AniSkip picks the
        // submission whose episode length is nearest the one sent, so a 0
        // (or a 1440 s value for a 1420 s encode) returned windows a few
        // seconds off the intro actually in this file. Ask again from the
        // first duration tick instead of guessing.
        guard episodeLength > 1, !playerController.awaitingNewFile else {
            aniSkipAwaitingDuration = true
            return
        }
        aniSkipAwaitingDuration = false
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
        // Same rule as everywhere else: the copy on disk, if there is one.
        if let download = finishedDownload(
            catalog: currentDetailCatalog, catalogId: catalogId, episode: number
        ) {
            await playDownloadedFile(download)
            return
        }
        do {
            _ = try await resolveAndPlay(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: Int64(number)
            )
        } catch {
            errorMessage = error.localizedDescription
            playFeedback(.error)
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
        // Belt to `updateEpisodeNavigationState`'s braces: the phone's remote
        // and the player's own Next both land here, and an episode that has
        // not aired has nothing to resolve.
        guard target.isAired else {
            errorMessage = "Episode \(target.number) has not aired yet."
            playFeedback(.error)
            return
        }
        // Leaving an episode forwards is the viewer saying they are done
        // with it. Nothing else ever said so: the 85% rule fires only from a
        // playback tick, so pressing Next part-way through left the episode
        // unmarked both locally and on AniList, while auto-play-next -- which
        // fires seconds from the end, long past the line -- always marked it.
        // The same button behaved differently depending on who pressed it.
        //
        // Backwards is not a claim about anything, so Previous marks nothing.
        if offset > 0 {
            markEpisodeFinished(catalogId: catalogId, episode: episode)
        }
        // Next out of a downloaded episode into another downloaded one used
        // to resolve the swarm for a file already on disk; the Downloads
        // page's own Play opens it from there, so this does too.
        let playingCatalog: MediaCard.CardCatalog = {
            switch currentPlaybackCatalog {
            case .tmdbMovie: return .tmdbMovie
            case .tmdbTv: return .tmdbTv
            case .anilist, .mangaDex: return .anilist
            }
        }()
        if let download = finishedDownload(
            catalog: playingCatalog, catalogId: catalogId, episode: target.number
        ) {
            await playDownloadedFile(download)
            return
        }
        do {
            _ = try await resolveAndPlay(
                catalog: currentPlaybackCatalog,
                catalogId: catalogId,
                episode: Int64(target.number)
            )
        } catch {
            errorMessage = error.localizedDescription
            playFeedback(.error)
        }
    }

    /// Records an episode as finished when the viewer leaves it forwards.
    ///
    /// Two writes, deliberately: the local flag is what `Stats` counts and
    /// what survives with no token, and the AniList progress is what the
    /// episode list's checkbox reads on every other device. Marking only
    /// AniList left the episode ticked in the list but absent from the
    /// statistics, which is the seam this closes.
    public func markEpisodeFinished(catalogId: Int64, episode: Int64) {
        guard let engine else { return }
        let catalog = currentPlaybackCatalog
        engineIOQueue.async {
            try? engine.markEpisodeCompleted(
                catalog: catalog, catalogId: catalogId, episodeNumber: episode
            )
        }
        guard catalog == .anilist else { return }
        Task {
            await self.advanceAniListProgress(
                catalogId: catalogId, episode: Int(episode), contiguousOnly: true
            )
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
        // An unaired episode is not somewhere to go. AniList lists a whole
        // announced run the moment it is known, so a show ten episodes into a
        // twelve-episode order offered Next after the tenth, auto-next took
        // it, and the only possible answer was "No HD torrent found for
        // episode 11".
        playerController.hasNextEpisode = sorted.indices.contains(index + 1)
            && sorted[index + 1].isAired
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
            coverURL: pageCover ?? playbackCoverURL
                ?? registryCover(catalog: currentPlaybackCatalog, id: catalogId)
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
                catalog: playbackCatalogForOpenDetail,
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
        // `.failed` passes: that row's button reads "click to retry", and a
        // guard that admitted only nil and `.notStarted` made the retry a
        // silent no-op. The engine dedupes the same way.
        switch downloadStates[episode] {
        case .downloading?, .done?: return
        case nil, .notStarted?, .failed?: break
        }
        downloadStates[episode] = .downloading(percent: 0)
        setLibraryDownload(
            catalogId: details.id, episode: episode, title: details.title,
            coverURL: details.coverURL, state: .downloading(percent: 0),
            catalog: currentDetailCatalog
        )
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        do {
            try await engine.startEpisodeDownload(
                // The open page's catalog, not AniList's: a film downloaded
                // under `.anilist` searches for whatever anime carries the
                // same number.
                catalog: playbackCatalogForOpenDetail,
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
        // Same reason: the poll must ask about the catalog this download was
        // started for, not whichever page is open a minute later.
        let catalog = playbackCatalogForOpenDetail
        while true {
            // A cancelled task returns from `sleep` at once; with the error
            // swallowed this became a hot FFI poll until the download ended.
            do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
            let status = await engine.episodeDownloadStatus(
                catalog: catalog,
                catalogId: catalogId,
                episode: Int64(episode)
            )
            let mirrorToDetailPage = selectedMediaDetails?.id == catalogId
            switch status {
            case .notStarted:
                if mirrorToDetailPage { downloadStates[episode] = .notStarted }
                setLibraryDownload(catalogId: catalogId, episode: episode, title: title, coverURL: coverURL, state: .notStarted)
            case .downloading(let percent):
                // Whole percents, and only written on change: Observation
                // invalidates on every set, and a tick that wrote the same
                // value still re-ran the episode list once a second.
                let next = MediaDetailView.EpisodeDownloadState.downloading(percent: percent.rounded())
                if mirrorToDetailPage, downloadStates[episode] != next { downloadStates[episode] = next }
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

    func setLibraryDownload(
        catalogId: Int64,
        episode: Int,
        title: String,
        coverURL: URL?,
        state: MediaDetailView.EpisodeDownloadState,
        catalog: MediaCard.CardCatalog = .anilist
    ) {
        if let idx = libraryDownloads.firstIndex(where: {
            $0.catalog == catalog && $0.catalogId == catalogId && $0.episode == episode
        }) {
            libraryDownloads[idx].state = state
        } else {
            libraryDownloads.append(
                LibraryDownload(
                    catalogId: catalogId,
                    episode: episode,
                    title: title,
                    coverURL: coverURL,
                    state: state,
                    catalog: catalog
                )
            )
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

        if aniSkipAwaitingDuration, duration > 1, !playerController.awaitingNewFile {
            requestAniSkipTimes(catalogId: catalogId, episode: episode)
        }

        let rawStop = Int64(currentTime)
        let dur = Int64(duration)
        let stopTime = dur > 0 ? min(rawStop, dur) : rawStop
        guard stopTime >= 0 else { return }

        // Whether anything here is allowed to call this episode finished.
        // A stream that never really opened reports a sliver of a duration
        // and an instant end, and without this every rule below fires on it
        // at once -- marking the episode watched and auto-advancing into the
        // next one, which fails identically. A season went by in seconds.
        let playedFor = playbackSessionStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let completionRulesApply = duration >= Self.minimumCredibleDurationSeconds
            && playedFor >= Self.minimumPlaybackBeforeCompletionSeconds

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
        if currentPlaybackCatalog == .anilist, !hasAdvancedAniListForCurrentEpisode,
           completionRulesApply {
            let percent = Double(stopTime) / Double(dur) * 100
            if percent >= Self.watchedThresholdPct {
                hasAdvancedAniListForCurrentEpisode = true
                // The one moment in an episode where something is recorded
                // that the viewer cannot see happening. The flag above makes
                // it once per episode, not once per tick past the line.
                playFeedback(.watchedTick)
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
        if currentPlaybackCatalog != .tmdbMovie, !hasPreloadedNextEpisode, completionRulesApply,
           playerController.hasNextEpisode,
           Double(stopTime) / Double(dur) * 100 >= Self.nextEpisodePreloadPct {
            hasPreloadedNextEpisode = true
            let sorted = playbackEpisodes
            if let index = sorted.firstIndex(where: { $0.number == Int(episode) }),
               sorted.indices.contains(index + 1),
               sorted[index + 1].isAired {
                let next = Int64(sorted[index + 1].number)
                let req = StreamRequest(
                    catalog: currentPlaybackCatalog,
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
        // `isResolved` is anything but `.idle`: the card either advanced the
        // episode itself, or the viewer cancelled it. Both are decisions
        // already taken for this episode, and this check firing on top of
        // either would advance an episode the viewer had just said no to.
        // An idle countdown means no card ever came up (minimized player,
        // card turned off) and this behaves exactly as it always did.
        // "Stop after this episode" lands on the same near-the-end mark
        // auto-next uses, and is checked first: let auto-next go and the next
        // episode is already loading, so the timer never gets its moment.
        // Claiming `hasAutoAdvancedEpisode` is what stops it below. Not
        // gated on `autoPlayNextEnabled` -- the episode ends either way, and
        // this is about the machine going to sleep, not about advancing.
        if sleepTimer == .afterEpisode, !hasAutoAdvancedEpisode, completionRulesApply,
           Double(dur) - currentTime <= Self.autoAdvanceRemainingSeconds {
            hasAutoAdvancedEpisode = true
            sleepTimer = .off
            stopPlayback()
            return
        }

        if !hasAutoAdvancedEpisode, !playerController.nextEpisodeCountdown.isResolved,
           completionRulesApply, Double(dur) - currentTime <= Self.autoAdvanceRemainingSeconds,
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

        let title = currentPlaybackTitle ?? (currentPlaybackCatalog == .anilist ? "Anime" : "Film")
        let episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title
            ?? (currentPlaybackCatalog == .tmdbMovie ? title : "")
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
                catalog: Self.handoffCatalog(currentPlaybackCatalog),
                title: title,
                episode: Int(episode),
                timePositionSeconds: currentTime
            )
        }
    }

    /// Persists an explicit track pick against the playing title. `nil`
    /// forgets it.
    ///
    /// On `engineIOQueue` like every other registry write: this is a
    /// synchronous SQLite call, and the queue's own comment records what one
    /// of those costs when it runs on the main actor mid-playback.
    func recordTrackMemory(_ memory: PlayerController.TrackMemory?) {
        guard let engine, let catalogId = currentPlaybackCatalogId else { return }
        let catalog = currentPlaybackCatalog
        engineIOQueue.async {
            try? engine.recordTitleTrackPreference(
                catalog: catalog,
                catalogId: catalogId,
                audioLang: memory?.audioLang,
                subtitleLang: memory?.subtitleLang,
                subtitleTitle: memory?.subtitleTitle
            )
        }
    }

    /// This title's remembered tracks, or `nil` when it has none.
    ///
    /// Awaited rather than fired off, and by the caller *before* the stream
    /// URL reaches mpv: `MpvSurface` applies the memory on
    /// `MPV_EVENT_FILE_LOADED`, and a read started alongside the load lands
    /// after that event as often as not, which would silently drop the
    /// remembered pick for that episode. Still on `engineIOQueue`, so the
    /// main actor waits on the continuation rather than on SQLite.
    /// `catalog` is not optional: `title_track_prefs` is keyed
    /// `(catalog, catalog_id)` like every other registry table, but the two
    /// FFI methods used to hardcode AniList — so picking a subtitle track on
    /// a film with TMDB id 550 wrote it against the anime with AniList id 550,
    /// and that anime's next episode opened with the film's choice.
    func loadTrackMemory(
        catalog: FfiCatalog,
        catalogId: Int64,
        engine: AnicatEngine
    ) async -> PlayerController.TrackMemory? {
        await withCheckedContinuation { continuation in
            engineIOQueue.async {
                let stored = (try? engine.titleTrackPreference(
                    catalog: catalog, catalogId: catalogId
                )) ?? nil
                continuation.resume(returning: stored.map {
                    PlayerController.TrackMemory(
                        audioLang: $0.audioLang,
                        subtitleLang: $0.subtitleLang,
                        subtitleTitle: $0.subtitleTitle
                    )
                })
            }
        }
    }

    /// Stops playback, records final progress into SQLite, and clears the Apple Handoff broadcast.
    public func stopPlayback() {
        // Read before the clear below, and gated on it: this method also
        // runs on paths where no player was open (engine teardown, a
        // stop for a play that never resolved), and an unconditional
        // sound is a close blip from an idle app.
        let wasPlaying = activeStreamURL != nil
        #if os(iOS)
        // Hands the grant back before anything else: the Mac keeps the file
        // pinned out of its own cache eviction for as long as the token is
        // live, and a phone that closed the player should not be holding
        // that.
        releaseRemoteStream()
        #endif
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
        } else if let engine {
            engineIOQueue.async { engine.discordClearPresence() }
        }
        // Release the playing-file pin and pause the session's torrents.
        // Without it a closed player kept downloading the rest of the
        // episode, and the preloaded next one, at full speed.
        if let engine {
            Task.detached(priority: .utility) { await engine.playbackStopped() }
        }
        // mpv only stops in `dismantleNSView`, which SwiftUI runs after the
        // close fade has finished, so the episode kept talking for about a
        // second over the page it closed to. Mute, not pause: pause flips
        // the observed `pause` property and runs the play-state handlers
        // for a player that is already gone. The flag dies with the core,
        // and a new surface applies `isMuted` at setup.
        playerController.onSetMuted?(true)
        self.activeStreamURL = nil
        if wasPlaying {
            playFeedback(.playerClose)
        }
        self.isPlayerMinimized = false
        // Leaving the key set would keep the row it names tagged as a
        // `matchedGeometryEffect` source for the rest of the session, so the
        // *next* play — one started from somewhere with no row at all — would
        // fly its placeholder out of a stale episode still.
        self.openingPlayerSourceKey = nil
        self.openingPlayerThumbnailURL = nil
        self.currentPlaybackCatalogId = nil
        self.currentPlaybackEpisode = nil
        self.currentPlaybackTitle = nil
        resetPerEpisodeDedupState(discordPaused: nil)
        playerController.hasNextEpisode = false
        playerController.hasPreviousEpisode = false
        playerController.episodeList = []
        playerController.rememberedReleaseName = nil
        playerController.resolveStatus = nil
        playerController.resolveElapsedSeconds = nil
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
        //
        // Tracked as the page's own task: untracked, `openDetail` could not
        // cancel it, and stopping then immediately opening another title
        // had the old title's fetch land on the new page.
        activeDetailTask?.cancel()
        let refresh = Task { @MainActor [engineIOQueue] in
            // Waits out the final `recordProgress` queued above. Read before
            // it landed, the engine's resume position was the previous tick's.
            await withCheckedContinuation { continuation in
                engineIOQueue.async { continuation.resume() }
            }
            await loadHistory()
            // Up Next is otherwise rebuilt only by a list edit or a full
            // refresh, and closing mid-episode is neither.
            if !watchingSummaries.isEmpty {
                rebuildUpNext()
                persistHomeCache()
            }
            guard let currentDetails = selectedMediaDetails else { return }
            // Refreshed through the catalog the page belongs to. `loadDetail`
            // is AniList's, and a cinema page's id is TMDB's: closing the
            // player over a film re-fetched that number *from AniList* and
            // replaced the page with whatever anime happened to carry it --
            // which is what "leaving a stream lands on a random title" was.
            if currentDetailCatalog == .anilist {
                // Forced: the page was usually opened or refreshed within
                // `detailFreshnessWindow` of pressing play, so the snapshot
                // was served and Resume kept the time from before this watch.
                await loadDetail(id: currentDetails.id, isManga: Self.isMangaFormat(currentDetails.format), forceRefresh: true)
            } else {
                await refreshCinemaDetailAfterPlayback(id: currentDetails.id)
            }
        }
        activeDetailTask = refresh
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
        fromStart: Bool = false,
        forceNewFile: Bool = false
    ) async throws -> URL {
        // A reader open over the player is a reader over the picture. Both
        // sit above it by design -- opening a chapter while an episode plays
        // is a deliberate thing to do -- but a *stream* arriving under an
        // open reader is not: locally there is no way to ask for one from
        // inside the reader, and remotely there is, so a play sent from the
        // phone started behind whatever was being read and showed nothing at
        // all.
        closeReader()
        closeSyosetuReader()

        let effectiveTitle = title ?? self.selectedMediaDetails?.title
            ?? self.registryTitle(catalog: catalog, id: catalogId)
            ?? (catalog == .anilist ? "Anime" : "Film")
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.isLiveAction = catalog != .anilist
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
            // A language switch is the second exception, for the same reason
            // a named release is: same episode, different file. Left out, the
            // gate stayed open and the outgoing file's ticks were handled as
            // the new one's.
            && !forceNewFile
        // What is playing right now, kept so a resolve that fails can put it
        // back. Everything below is written before the engine is asked for a
        // stream -- the resolve card needs a title and a number to show -- so
        // a failure used to leave the chrome describing an episode that never
        // loaded while the previous one carried on playing underneath it.
        // "It autoplays 10 again but under the name episode 11" was that.
        let previous = (
            catalog: self.currentPlaybackCatalog,
            catalogId: self.currentPlaybackCatalogId,
            episode: self.currentPlaybackEpisode,
            title: self.currentPlaybackTitle,
            playerTitle: self.playerController.title,
            episodeNumber: self.playerController.episodeNumber,
            episodeTitle: self.playerController.episodeTitle,
            releaseName: self.playerController.currentReleaseName,
            wasPlaying: self.activeStreamURL != nil
        )
        self.currentPlaybackCatalog = catalog
        self.currentPlaybackCatalogId = catalogId
        self.currentPlaybackEpisode = episode
        self.playerController.awaitingNewFile = !replayingCurrent
        // Only a release asked for by name is a release the player can tick
        // in its list; an ordinary play is whatever the engine's own race
        // landed on, which it does not report back.
        self.playerController.currentReleaseName = chosenName
        // Belongs to the episode whose list it was read with; the next
        // list read refills it.
        self.playerController.rememberedReleaseName = nil
        ensurePlaybackEpisodes(for: catalogId, engine: engine, catalog: catalog)
        self.currentPlaybackTitle = effectiveTitle
        // A fresh play always opens full-screen, not stuck minimized from
        // whatever the last session left it as.
        self.isPlayerMinimized = false
        resetPerEpisodeDedupState(discordPaused: false)
        // Cleared up front rather than left showing the previous episode's
        // skip window for however long the fetch below takes.
        self.playerController.setAniSkipTimes(nil)
        aniSkipAwaitingDuration = false
        // Same reasoning: a new episode's overlay shouldn't briefly letterbox
        // itself against the last episode's aspect ratio before mpv reports
        // the new one.
        self.playerController.videoDisplayWidth = nil
        self.playerController.videoDisplayHeight = nil
        self.playerController.decodedDisplayWidth = nil
        self.playerController.decodedDisplayHeight = nil

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
            // An episode already watched through (past the 85% mark that
            // records it as watched) replays from the start: resuming at
            // 23:40 of 24:00 put the viewer into the credits of a rewatch
            // and then straight into auto-next.
            if initialDuration > 0, initialTime / initialDuration >= 0.85 {
                initialTime = 0
            }
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
        let startedAt = Date()
        resolveStartedAt = startedAt
        // Only this resolve's own mark. A cancelled resolve's FFI call keeps
        // running and returns whenever the engine does; an unconditional
        // clear then took the card away from the play started after it.
        defer { if resolveStartedAt == startedAt { resolveStartedAt = nil } }
        // The engine publishes what each resolve is doing (`resolveProgress`,
        // a cheap synchronous read keyed by episode, so the N+1 preload and
        // the launch preresolve cannot speak for this play) and this turns it
        // into the line under the spinner, four times a second. Held on the
        // model so Cancel can stop it; see `cancelResolve`.
        activeResolvePoller?.cancel()
        let progressPoller = Task { @MainActor [weak self] in
            defer {
                // A newer resolve owns the line once it has started; clearing
                // it from here blanked that one's first reading.
                if let self, self.resolveStartedAt == nil || self.resolveStartedAt == startedAt {
                    self.playerController.resolveStatus = nil
                    self.playerController.resolveElapsedSeconds = nil
                }
            }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled, let self, self.resolveStartedAt == startedAt else { return }
                let line = engine.resolveProgress(catalog: catalog, catalogId: catalogId, episode: episode)
                    .map { Self.resolveStatusLine($0) }
                // Written only on a change: the same value four times a second
                // is four invalidations of every view reading the controller,
                // the full player's body among them.
                if self.playerController.resolveStatus != line {
                    self.playerController.resolveStatus = line
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt))
                let shown = elapsed > 2 ? elapsed : nil
                if self.playerController.resolveElapsedSeconds != shown {
                    self.playerController.resolveElapsedSeconds = shown
                }
            }
        }
        activeResolvePoller = progressPoller
        defer {
            progressPoller.cancel()
            if activeResolvePoller == progressPoller { activeResolvePoller = nil }
        }
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
            // The launch preresolve of this very episode may still be
            // searching; pressing Play on the first Up Next entry straight
            // after launch is the likeliest first click. A second resolve
            // beside it ran the indexer wave again and raced it for the same
            // swarm. Waiting hands this one the reuse path instead, and the
            // card shows the preresolve's own progress meanwhile, since that
            // is keyed to this episode.
            if chosenName == nil, catalog == .anilist, let inFlight = preresolveInFlight,
               inFlight.catalogId == catalogId, inFlight.episode == episode {
                await inFlight.task.value
                guard !Task.isCancelled else { throw CancellationError() }
            }
            #if os(iOS)
            // A Mac on the same Wi-Fi resolves and serves this instead,
            // when there is one and it has approved this phone. The phone
            // then joins no swarm, uploads nothing, and writes nothing to
            // its own cache -- which is the whole point on a device with
            // 128 GB and a battery. `remoteStreamURL` returns nil for every
            // failure, so the local engine below stays the answer whenever
            // the Mac is not there or says no.
            if let remote = await remoteStreamURL(for: req) {
                handleURL = remote.absoluteString
            } else {
                releaseRemoteStream()
                handleURL = try await Self.resolveWithTimeout(engine: engine, req: req, timeoutSeconds: 120)
            }
            #else
            handleURL = try await Self.resolveWithTimeout(engine: engine, req: req, timeoutSeconds: 120)
            #endif
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
            restorePlaybackIdentity(previous)
            // A cancel is the viewer's own doing and every caller matches
            // it by type; wrapping it would turn Cancel into an error toast.
            if error is CancellationError { throw error }
            throw PlaybackFailure(error, catalog: catalog, episode: episode)
        }
        guard let streamURL = URL(string: handleURL) else {
            self.playerController.awaitingNewFile = false
            restorePlaybackIdentity(previous)
            throw PlaybackFailure(
                NSError(domain: "Anicat", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid stream URL: \(handleURL)"]),
                catalog: catalog,
                episode: episode
            )
        }

        // Re-read after every resolve rather than left nil for the release
        // menu to refill: that menu caches its list per title and episode,
        // and a release switch changes neither, so after a switch no row
        // carried the tag for the rest of the episode.
        self.playerController.rememberedReleaseName = engine.rememberedReleaseName(
            catalog: catalog,
            catalogId: catalogId,
            episode: episode,
            preferDub: preferDub
        )

        // Read here, above the assignment that hands mpv the URL — see
        // `loadTrackMemory` for why the ordering is the whole point.
        self.playerController.titleTrackMemory = await loadTrackMemory(catalog: catalog, catalogId: catalogId, engine: engine)

        // Before returning streamURL, configure playerController with actual title, episode number, and duration
        self.playerController.title = effectiveTitle
        self.playerController.episodeNumber = Int(episode)
        self.playerController.episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
        self.playerController.isPlaying = true
        if self.playerController.duration <= 0 && initialDuration > 0 {
            self.playerController.duration = initialDuration
        }

        // One explicit curve here, the same length as the detail page's own
        // open/close (`closeDetail`, `loadDetail`), rather than a bare
        // `.animation(value:)` modifier at the view side — relying on that
        // alone left the player's entrance timed by whatever SwiftUI's
        // default "smooth" spring happens to be, uncoordinated with
        // everything else that's mounting at the same instant (the chrome
        // bars' own appear animation, the mini-player fading out if it was
        // showing), which is what read as jittery rather than one clean
        // transition.
        withAnimation(.smooth(duration: 0.42)) {
            self.activeStreamURL = streamURL
        }
        playFeedback(.playerOpen)
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
            catalog: Self.handoffCatalog(catalog),
            title: effectiveTitle,
            episode: Int(episode),
            timePositionSeconds: playerController.currentTime
        )

        if Self.isDiscordPresenceEnabled {
            // On `engineIOQueue` like the clear in `stopPlayback`: issued
            // inline, this set could run while a queued clear was still
            // waiting behind a stalled write, and the clear then landed
            // after it and wiped the new episode's presence.
            let episodeTitle = playbackEpisodes.first(where: { $0.number == Int(episode) })?.title ?? ""
            let totalEpisodes = Int64(selectedMediaDetails?.episodeCount ?? 0)
            let pos = Int64(playerController.currentTime)
            let duration = Int64(playerController.duration)
            engineIOQueue.async {
                engine.discordSetPresence(
                    title: effectiveTitle,
                    episode: episode,
                    episodeTitle: episodeTitle,
                    totalEpisodes: totalEpisodes,
                    pos: pos,
                    duration: duration,
                    paused: false
                )
            }
        }

        return streamURL
    }

    /// The engine's resolve progress as the line under the spinner.
    nonisolated static func resolveStatusLine(_ progress: ResolveProgress) -> String {
        switch progress.phase {
        case .remembered:
            return "Checking last release"
        case .searching:
            return progress.candidates > 0
                ? "Found \(progress.candidates) release\(progress.candidates == 1 ? "" : "s")"
                : "Searching indexers"
        case .connecting:
            guard let release = progress.release, !release.isEmpty else { return "Connecting" }
            return "Connecting to \(abbreviateReleaseName(release))"
        case .buffering:
            let rate = progress.bytesPerSecond
            if rate == 0 { return "Waiting for peers" }
            if rate >= 1_048_576 {
                return String(format: "Buffering at %.1f MB/s", Double(rate) / 1_048_576)
            }
            return "Buffering at \(rate / 1024) KB/s"
        }
    }

    /// Release names run to 80-odd characters and the discriminating part
    /// (group at the front, resolution and codec at the back) sits at both
    /// ends, so the middle is what goes.
    nonisolated static func abbreviateReleaseName(_ name: String, limit: Int = 40) -> String {
        guard name.count > limit else { return name }
        let head = name.prefix(limit - 16)
        let tail = name.suffix(15)
        return "\(head)…\(tail)"
    }
}

/// What a failed play says to the viewer.
///
/// The engine's errors are written for the person reading stderr ("All
/// torrent candidates failed (last error: swarm too slow: 532 KB/s, needs
/// 568 KB/s to plausibly keep up)"), and shown as-is they told a viewer
/// what broke but never what to do about it. `localizedDescription` is the
/// sentence to show, with one implied action; the engine's own text is kept
/// on `rawEngineText` and printed once, so nothing leaves the log.
public struct PlaybackFailure: LocalizedError, CustomDebugStringConvertible {
    public enum Kind: Equatable, Sendable {
        case nothingFound
        case swarmTooSlow
        case aniListDown
        case other
    }

    public let kind: Kind
    public let catalog: FfiCatalog
    public let episode: Int64
    public let rawEngineText: String

    public init(_ error: Error, catalog: FfiCatalog, episode: Int64) {
        let raw = Self.engineText(of: error)
        self.rawEngineText = raw
        self.catalog = catalog
        self.episode = episode
        self.kind = Self.classify(raw)
        print("[play] \(catalog) episode \(episode) failed: \(raw)")
    }

    /// A film is played as its catalog's episode 1, so the anime wording
    /// told a viewer who pressed Play on Dune "Nothing found for episode 1
    /// yet. Releases usually appear within a day of airing."
    private var subject: String {
        catalog == .tmdbMovie ? "this film" : "episode \(episode)"
    }

    public var errorDescription: String? {
        switch kind {
        case .nothingFound:
            if catalog == .tmdbMovie {
                return "No release of this film was found. Recent films can take a while to appear."
            }
            return "Nothing found for episode \(episode) yet. Releases usually appear within a day of airing."
        case .swarmTooSlow:
            return "Every release is too slow right now. Try again in a minute, or pick a release from the player menu."
        case .aniListDown:
            return "AniList is having an outage. Playback still works from the episode list once it is back."
        case .other:
            return "Could not start \(subject). \(rawEngineText)"
        }
    }

    public var debugDescription: String {
        "PlaybackFailure(\(kind), \(catalog) episode \(episode)): \(rawEngineText)"
    }

    /// The message the engine wrote, without the `AnicatError.NotFound(msg:
    /// ...)` wrapper `String(reflecting:)` puts around it -- that wrapper
    /// is what the generated `localizedDescription` returns, and it was
    /// the first thing on screen in every error toast.
    static func engineText(of error: Error) -> String {
        if let engineError = error as? AnicatError {
            switch engineError {
            case let .Network(msg), let .NotFound(msg), let .Storage(msg), let .Internal(msg):
                return msg
            }
        }
        return error.localizedDescription
    }

    static func classify(_ raw: String) -> Kind {
        let text = raw.lowercased()
        if text.contains("anilist_down:") { return .aniListDown }
        if text.hasPrefix("no torrent found") || text.hasPrefix("no hd torrent found")
            || text.hasPrefix("no title to search") {
            return .nothingFound
        }
        // "All torrent candidates failed (last error: ...)" wraps whichever
        // per-candidate reason came last; every one of them is a swarm that
        // did not deliver, so the wrapper alone is enough to classify.
        if text.contains("all torrent candidates failed") || text.contains("no seeders")
            || text.contains("swarm too slow") || text.contains("pre-buffer timed out") {
            return .swarmTooSlow
        }
        return .other
    }
}

extension AppModel {
    /// Test hook: plays a local file straight into the player, no resolve.
    /// Only reachable through the ANICAT_DEBUG_PLAY_FILE environment
    /// variable, read once at launch; it exists so a driven test copy can
    /// exercise the player without a torrent and without taking focus.
    public func debugPlayLocalFile(_ path: String) {
        playerController.title = (path as NSString).lastPathComponent
        playerController.episodeNumber = 1
        playerController.awaitingNewFile = true
        playerController.isPlaying = true
        activeStreamURL = URL(fileURLWithPath: path)
    }
}
