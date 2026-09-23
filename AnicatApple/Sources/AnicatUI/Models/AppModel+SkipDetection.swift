// AppModel, skip detection: finding a show's opening and ending in its audio
// when neither the release's chapters nor AniSkip have them. The matching is
// `core/src/skip.rs`; this decides when to run it and on what.

import Foundation
import AnicatCoreKit

extension AppModel {
    /// Where an opening can plausibly be: the cold open before it runs a few
    /// minutes at most. Eight minutes of 11 kHz mono is 10 MB and matches in
    /// a third of a second.
    static let skipHeadSeconds: Double = 480
    /// An ending plus the next-episode preview after it.
    static let skipTailSeconds: Double = 300
    /// How far into the episode the bootstrap waits before it starts. The
    /// pre-buffer and mpv's first reads own the swarm until then, and a
    /// second file asking for pieces during them is what stalls playback.
    static let skipBootstrapAfterSeconds: Double = 15
    /// How far ahead of the playhead the playing file has to be on disk
    /// before a second episode may be pulled through the same swarm.
    static let skipBootstrapLookaheadSeconds: Double = 120
    /// The second opening window, searched only when the head missed: it
    /// overlaps the head by the longest segment the matcher accepts, so an
    /// opening straddling the 8-minute mark is whole in one of the two.
    static let skipLateOpeningStart: Double = 300
    static let skipLateOpeningLength: Double = 480

    /// Runs once the episode's other sources have answered. Only the opening
    /// is searched here, from a stored reference: the ending waits for the
    /// 75% preload (`nextEpisodePreloaded`). Decoding the tail at the start
    /// of an episode reads ~19 minutes ahead of the playhead, and on a slow
    /// swarm those pieces compete with the ones mpv is about to need.
    func startSkipDetection() {
        // Every return here was silent, and "it can't detect the opening"
        // then reads the same in the log as never having been called at all:
        // the same hole `requestAniSkipTimes` filled for AniSkip.
        guard currentPlaybackCatalog == .anilist else {
            print("[skipdetect] not started: catalog \(currentPlaybackCatalog) is not AniList")
            return
        }
        guard engine != nil,
              let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              activeStreamURL != nil else {
            print("[skipdetect] not started: engine/id/episode/stream URL missing (id=\(currentPlaybackCatalogId ?? -1) ep=\(currentPlaybackEpisode ?? -1) url=\(activeStreamURL?.absoluteString ?? "nil"))")
            playerController.skipDetectionStatus = "Waiting for the stream"
            return
        }
        let duration = playerController.duration
        guard duration > Self.skipHeadSeconds else {
            print("[skipdetect] not started for \(catalogId) ep \(episode): duration \(Int(duration))s is not past the \(Int(Self.skipHeadSeconds))s head window")
            playerController.skipDetectionStatus = "Waiting for the file's duration (\(Int(duration))s so far)"
            return
        }
        // A resume past the head window has nothing to gain from this search:
        // the opening it would find has already played, and the reference it
        // reads from is stored, so nothing is learned either. What it costs
        // is real -- 8 minutes of audio pulled from *behind* the playhead,
        // through the same swarm the player is reading forward from. The
        // owner's Chuunibyou Ren ep 1 resumed at 591s and did exactly that
        // against a release with no peers.
        guard playerController.currentTime < Self.skipHeadSeconds else {
            print("[skipdetect] op search for \(catalogId) ep \(episode) skipped: the playhead is at \(Int(playerController.currentTime))s, past the \(Int(Self.skipHeadSeconds))s head window")
            playerController.skipDetectionStatus = "Resumed past the opening; not searching for it"
            return
        }
        guard !hasSkipWindow(.opening) else {
            playerController.skipDetectionStatus = "Opening already known from chapters or AniSkip"
            return
        }
        // The search itself belongs to the position tick
        // (`bootstrapOpeningDetection`), which waits until the playing file is
        // on disk ahead of the playhead. Run from here it started the moment
        // AniSkip answered: Watari-kun ep 15 decoded its head for 118s while
        // the torrent was 1-10% down and the player was reading the same
        // pieces, then the tick ran the identical search again in 1s.
        // A late AniSkip answer must not overwrite a search already under way.
        guard !hasBootstrappedOpening else { return }
        playerController.skipDetectionStatus = "Waiting for the stream to get ahead before searching the audio"
    }

    /// The opening search, driven by the position tick. With a stored
    /// opening it searches this episode's head for it. Without one, or when
    /// the stored one is not in this episode, it resolves the next episode
    /// early, purely to learn the opening from, and skips this episode's too
    /// when the swarm is quick enough to answer before it ends. The first
    /// episode of a show used to wait for the 75% preload, by which point its
    /// own opening had played 20 minutes ago.
    func bootstrapOpeningDetection() {
        guard currentPlaybackCatalog == .anilist,
              let engine,
              let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let url = activeStreamURL?.absoluteString,
              !hasSkipWindow(.opening) else { return }
        guard playerController.duration > Self.skipHeadSeconds else { return }
        // Not while the swarm is only just keeping the playing episode fed:
        // a pair comparison over a live torrent measured 180s + 121s of
        // decode competing with the episode being watched, and a stored
        // search 118s. An empty list is a file already on disk, the one case
        // this cannot slow down. Returning here is safe only because the
        // tick calls again; `startSkipDetection` has no such retry.
        let buffered = playerController.torrentBufferedFractions
        if !buffered.isEmpty {
            let duration = playerController.duration
            let here = playerController.currentTime / duration
            let ahead = min((playerController.currentTime + Self.skipBootstrapLookaheadSeconds) / duration, 1)
            guard buffered.contains(where: { $0.start <= here && $0.end >= ahead }) else { return }
        }
        // The same pick as the 75% preload: the next episode that has aired.
        // An empty list is one `ensurePlaybackEpisodes` is still filling, and
        // the next tick tries again; a stored opening needs no next episode
        // unless it misses, so only a settled list is waited on.
        let sorted = playbackEpisodes
        guard !sorted.isEmpty else { return }
        hasBootstrappedOpening = true
        let neighbour = neighbourEpisode(of: episode)
        let resumedPastHead = playerController.currentTime >= Self.skipHeadSeconds
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let title = currentPlaybackTitle
        let previous = skipDetectionTask
        skipDetectionTask = Task { [weak self] in
            await previous?.value
            let hasOpening = await Task.detached(priority: .utility) {
                engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "op")
            }.value
            guard let self, !Task.isCancelled, !self.hasSkipWindow(.opening) else { return }
            var storedMissed = false
            if hasOpening {
                // A resume past the head window has nothing to gain from
                // this search: the opening it would find has already played
                // and nothing is learned. What it costs is 8 minutes of audio
                // pulled from *behind* the playhead: Chuunibyou Ren ep 1
                // resumed at 591s and did exactly that against a release
                // with no peers.
                guard !resumedPastHead else {
                    print("[skipdetect] op search for \(catalogId) ep \(episode) skipped: resumed past the \(Int(Self.skipHeadSeconds))s head window")
                    self.playerController.skipDetectionStatus = "Resumed past the opening; not searching for it"
                    return
                }
                var outcome = await self.findStored(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                                    start: 0, length: Self.skipHeadSeconds, preferDub: preferDub,
                                                    announceMiss: false)
                if outcome == .missed, !Task.isCancelled {
                    outcome = await self.findStoredLateOpening(catalogId: catalogId, episode: episode, url: url,
                                                               preferDub: preferDub, announceMiss: neighbour == nil)
                }
                switch outcome {
                case .found, .failed: return
                case .missed: storedMissed = true
                }
            }
            guard let neighbour else {
                if !hasOpening {
                    print("[skipdetect] no other aired episode to learn \(catalogId)'s opening from")
                }
                return
            }
            // A show whose opening changes (a second cour: Watari-kun's
            // stored cour-1 opening was "not found" in ep 15) never matched
            // again, because a stored reference was the only thing searched
            // for. The comparison below overwrites it (`set_skip_reference`
            // is an upsert), so a rewatch of cour 1 misses once and learns it
            // back: one extra comparison per switch, not a lost opening.
            if storedMissed {
                print("[skipdetect] stored op for \(catalogId) not in ep \(episode); learning it again from ep \(neighbour)")
            }
            guard await self.subtitlesLeaveRoom(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                                start: 0, length: Self.skipHeadSeconds, neighbour: neighbour),
                  !Task.isCancelled else { return }
            guard let otherURL = await self.resolveNeighbour(neighbour, catalogId: catalogId, episode: episode,
                                                            name: "opening", title: title, preferDub: preferDub)
            else { return }
            // The full head window, not a cheaper one: this show's own first
            // episode opens at 299s (the cold open before it runs that long),
            // and a 300s window would have read one second of the opening.
            await self.comparePair(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                   otherURL: otherURL, start: 0,
                                   length: Self.skipHeadSeconds, preferDub: preferDub)
        }
    }

    /// The episode a changed or unknown segment is learned from: the next
    /// aired one, else the one before. Next first, because the first episode
    /// of a new cour shares its songs with the one after it and not the one
    /// before. The one before is for the airing edge -- the newest episode of
    /// a weekly show has no next, which is every episode the owner watches
    /// as it airs, so next-only never learned a cour-2 song there at all.
    /// Compared with a cour-1 episode it shares nothing, stores nothing, and
    /// the week after learns it from this one.
    func neighbourEpisode(of episode: Int64) -> Int64? {
        let sorted = playbackEpisodes
        guard let index = sorted.firstIndex(where: { $0.number == Int(episode) }) else { return nil }
        if sorted.indices.contains(index + 1), sorted[index + 1].isAired {
            return Int64(sorted[index + 1].number)
        }
        if sorted.indices.contains(index - 1) {
            return Int64(sorted[index - 1].number)
        }
        return nil
    }

    /// Resolves `neighbour` purely to read its audio. The 75% preload's
    /// stream is reused when it is that episode, rather than resolved again.
    private func resolveNeighbour(_ neighbour: Int64, catalogId: Int64, episode: Int64, name: String,
                                  title: String?, preferDub: Bool) async -> String? {
        guard let engine else { return nil }
        if let preloaded = preloadedNextStream, preloaded.catalogId == catalogId, preloaded.episode == neighbour {
            playerController.skipDetectionStatus = "Comparing episodes \(episode) and \(neighbour)"
            return preloaded.url
        }
        playerController.skipDetectionStatus = "Fetching episode \(neighbour) to learn the \(name) from"
        let req = StreamRequest(
            catalog: .anilist,
            catalogId: catalogId,
            episode: neighbour,
            title: title,
            preferDub: preferDub,
            chosenName: nil,
            resumeFraction: nil,
            preload: true
        )
        let began = Date()
        let otherURL = await Task.detached(priority: .utility) { () -> String? in
            try? await engine.resolveStream(req: req).url
        }.value
        guard !Task.isCancelled, currentPlaybackEpisode == episode else { return nil }
        guard let otherURL else {
            print("[skipdetect] ep \(neighbour) of \(catalogId) did not resolve, no \(name) to learn")
            playerController.skipDetectionStatus = "Episode \(neighbour) did not resolve; nothing to compare with"
            return nil
        }
        print("[skipdetect] ep \(neighbour) of \(catalogId) resolved in \(Int(Date().timeIntervalSince(began)))s to learn the \(name) from")
        // `hasPreloadedNextEpisode` stays false on purpose. Setting it here
        // skipped the 75% preload, and with it `nextEpisodePreloaded` -- the
        // path that learns an *ending* from scratch when there is a next
        // episode, so this episode traded its outro for its opening. The
        // preload's own resolve is the cheap reuse path once this one has
        // added the torrent (measured 798-955ms).
        if neighbour > episode {
            preloadedNextStream = (catalogId, neighbour, otherURL)
        }
        playerController.skipDetectionStatus = "Comparing episodes \(episode) and \(neighbour)"
        return otherURL
    }

    /// The tail search, driven by the playhead reaching
    /// `nextEpisodePreloadPct` rather than by the next episode's preload.
    /// With a stored ending this needs nothing but this episode's own audio,
    /// and the playhead is already close enough to the tail that decoding it
    /// reads barely ahead of mpv.
    func startStoredEndingDetection() {
        guard currentPlaybackCatalog == .anilist,
              let engine,
              let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let url = activeStreamURL?.absoluteString else { return }
        let duration = playerController.duration
        guard duration > Self.skipTailSeconds, !hasSkipWindow(.ending) else { return }
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let tailStart = max(duration - Self.skipTailSeconds, 0)
        let previous = skipDetectionTask
        skipDetectionTask = Task { [weak self] in
            // Same rule as the preload path: an opening search still decoding
            // finishes rather than being cancelled out from under itself.
            await previous?.value
            let hasEnding = await Task.detached(priority: .utility) {
                engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "ed")
            }.value
            guard let self, !Task.isCancelled, !self.hasSkipWindow(.ending) else { return }
            let neighbour = self.neighbourEpisode(of: episode)
            if hasEnding {
                let result = await self.findStored(kind: "ed", catalogId: catalogId, episode: episode, url: url,
                                                   start: tailStart, length: Self.skipTailSeconds,
                                                   preferDub: preferDub, announceMiss: neighbour == nil)
                guard result == .missed, let neighbour else { return }
                // The ending changes with the cour just as the opening does,
                // and a stored cour-1 ending was then "not found" in every
                // later episode. Same cure: compare with a neighbour, which
                // overwrites the stored one.
                print("[skipdetect] stored ed for \(catalogId) not in ep \(episode); learning it again from ep \(neighbour)")
            } else if neighbour.map({ $0 > episode }) ?? false {
                // A next episode exists, so the 75% preload is on its way and
                // learns the ending in `nextEpisodePreloaded`.
                print("[skipdetect] no ed reference for \(catalogId) yet; waiting for the next episode's preload")
                return
            } else if neighbour == nil {
                print("[skipdetect] no other aired episode to learn \(catalogId)'s ending from")
                return
            }
            // Here with no stored ending and no next episode: the newest
            // episode of a weekly show, which the preload never serves.
            guard let neighbour,
                  await self.subtitlesLeaveRoom(kind: "ed", catalogId: catalogId, episode: episode, url: url,
                                                start: tailStart, length: Self.skipTailSeconds, neighbour: neighbour),
                  !Task.isCancelled,
                  let otherURL = await self.resolveNeighbour(neighbour, catalogId: catalogId, episode: episode,
                                                            name: "ending", title: self.currentPlaybackTitle,
                                                            preferDub: preferDub)
            else { return }
            // The neighbour's duration is not known before it plays; releases
            // of one show run within seconds of each other, and the tail
            // window is wide enough to absorb that.
            await self.comparePair(kind: "ed", catalogId: catalogId, episode: episode, url: url,
                                   otherURL: otherURL, start: tailStart,
                                   length: Self.skipTailSeconds, preferDub: preferDub)
        }
    }

    /// The preload landed. Without references, compare the playing episode
    /// with the next one: the opening found is too late for this episode,
    /// but the ending usually is not, and every episode after this one has
    /// both. A stored ending is not searched here; see the comment below.
    func nextEpisodePreloaded(catalogId: Int64, episode: Int64, url: String) {
        guard currentPlaybackCatalogId == catalogId else { return }
        preloadedNextStream = (catalogId, episode, url)
        guard currentPlaybackCatalog == .anilist,
              let engine,
              let playingEpisode = currentPlaybackEpisode,
              let playingURL = activeStreamURL?.absoluteString else {
            print("[skipdetect] preload of ep \(episode) landed but the playing episode's catalog/stream is not usable")
            return
        }
        let duration = playerController.duration
        guard duration > Self.skipHeadSeconds else {
            print("[skipdetect] preload of ep \(episode) landed but duration is \(Int(duration))s")
            return
        }
        let needsEnding = !hasSkipWindow(.ending)
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let previous = skipDetectionTask
        skipDetectionTask = Task { [weak self] in
            // Let an opening search still decoding finish rather than cancel it.
            await previous?.value
            let (hasOpening, hasEnding) = await Task.detached(priority: .utility) {
                (engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "op"),
                 engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "ed"))
            }.value
            guard let self, !Task.isCancelled else { return }
            let tailStart = max(duration - Self.skipTailSeconds, 0)
            // A stored ending is searched, and relearned on a miss, by
            // `startStoredEndingDetection` from the same 75% tick; searching
            // it here as well ran the identical search twice.
            if needsEnding, !hasEnding, !self.hasSkipWindow(.ending) {
                self.playerController.skipDetectionStatus = "Comparing episodes \(playingEpisode) and \(episode)"
                // The next episode's duration is not known before it plays;
                // releases of one show run within seconds of each other, and
                // the tail window is wide enough to absorb that.
                await self.comparePair(kind: "ed", catalogId: catalogId, episode: playingEpisode,
                                       url: playingURL, otherURL: url, start: tailStart,
                                       length: Self.skipTailSeconds, preferDub: preferDub)
            }
            guard !hasOpening, !Task.isCancelled else { return }
            self.playerController.skipDetectionStatus = "Comparing episodes \(playingEpisode) and \(episode)"
            await self.comparePair(kind: "op", catalogId: catalogId, episode: playingEpisode,
                                   url: playingURL, otherURL: url, start: 0,
                                   length: Self.skipHeadSeconds, preferDub: preferDub)
        }
    }

    private func hasSkipWindow(_ kind: SkipKind) -> Bool {
        playerController.skipWindows.contains { $0.kind == kind }
    }

    /// Whether the stretch a search needs can plausibly be read at all.
    /// A torrent with no peers serves nothing, and the extractor would spend
    /// its whole 180s timeout retrying reads the player is also waiting on:
    /// Chuunibyou Ren ep 1 sat paused at 3.27% with zero peers ever seen
    /// while mpv logged `Will reconnect at 8388608 ... Operation timed out`,
    /// and the only thing the viewer ever saw was an AniSkip miss.
    private func streamCanServe(start: Double, length: Double) async -> Bool {
        guard let engine else { return false }
        let duration = playerController.duration
        guard duration > 0 else { return true }
        let buffered = playerController.torrentBufferedFractions
        // Empty means the file is not pinned by the torrent session at all,
        // i.e. it is on disk: the one case this cannot be wrong about.
        guard !buffered.isEmpty else { return true }
        let from = max(start / duration, 0)
        let to = min((start + length) / duration, 1)
        if buffered.contains(where: { $0.start <= from && $0.end >= to }) { return true }
        // The verdict is computed inside the detached task, not the stats:
        // uniffi's types are not `Sendable` and cannot cross back out.
        return await Task.detached(priority: .utility) { () -> Bool in
            guard let stats = engine.playingTorrentStats() else { return true }
            if stats.finished { return true }
            return stats.state == "live" && (stats.peersLive > 0 || stats.peersConnecting > 0)
        }.value
    }

    private func comparePair(kind: String, catalogId: Int64, episode: Int64, url: String, otherURL: String,
                             start: Double, length: Double, preferDub: Bool) async {
        guard let engine else { return }
        let dir = Self.skipScratchDirectory()
        let mine = dir.appendingPathComponent("\(catalogId)-\(episode)-\(kind)-a.raw")
        let other = dir.appendingPathComponent("\(catalogId)-\(episode)-\(kind)-b.raw")
        defer {
            try? FileManager.default.removeItem(at: mine)
            try? FileManager.default.removeItem(at: other)
        }
        guard await streamCanServe(start: start, length: length) else {
            print("[skipdetect] \(kind) pair for \(catalogId) ep \(episode) skipped: the stream is not being served")
            playerController.skipDetectionStatus = "The stream has no peers; nothing to compare"
            noteAudioSearchFailed("No skip times: this release has no seeders")
            return
        }
        let began = Date()
        // One after the other: both read through the torrent session, and the
        // playing episode's stream is the one that must not starve.
        guard await AudioExtractor.extract(url: url, start: start, length: length, preferDub: preferDub, to: mine),
              !Task.isCancelled,
              await AudioExtractor.extract(url: otherURL, start: start, length: length, preferDub: preferDub, to: other),
              !Task.isCancelled else {
            print("[skipdetect] \(kind) audio for \(catalogId) ep \(episode) not extracted")
            playerController.skipDetectionStatus = "Could not read enough audio to compare"
            noteAudioSearchFailed("No skip times: could not read the audio")
            return
        }
        let mainPath = mine.path
        let otherPath = other.path
        let span = await Task.detached(priority: .utility) {
            engine.detectSkipSegment(catalog: .anilist, catalogId: catalogId, kind: kind,
                                     pcmPath: mainPath, offset: start, otherPcmPath: otherPath)
                .map { (start: $0.start, end: $0.end) }
        }.value
        print("[skipdetect] \(kind) pair for \(catalogId) ep \(episode): \(span.map { "\(Int($0.start))-\(Int($0.end))s" } ?? "nothing shared") in \(Int(Date().timeIntervalSince(began)))s")
        apply(span, kind: kind, catalogId: catalogId, episode: episode, source: "compared with another episode")
    }

    /// Asked before another episode is fetched to learn a segment from:
    /// false when this episode's subtitles show no pause long enough for
    /// one, which makes the fetch pointless (`SubtitleGaps`). Watari-kun
    /// ep 24 fetched ep 25 to compare with and found "nothing shared" in an
    /// episode that has neither an opening nor an ending. Anything short of
    /// that answer -- no ASS track, too little dialogue, a read that failed
    /// or timed out -- is true, and the fetch goes ahead as before.
    private func subtitlesLeaveRoom(kind: String, catalogId: Int64, episode: Int64, url: String,
                                    start: Double, length: Double, neighbour: Int64) async -> Bool {
        // A stream with no peers would hold the read to its timeout, and the
        // comparison after it gives up on the same check anyway.
        guard await streamCanServe(start: start, length: length) else { return true }
        let name = kind == "op" ? "opening" : "ending"
        playerController.skipDetectionStatus = "Reading this episode's subtitles for room for an \(name)"
        let began = Date()
        let tracks = await SubtitleExtractor.extract(url: url, start: start, length: length)
        let elapsed = String(format: "%.1f", Date().timeIntervalSince(began))
        let window = "\(Int(start))-\(Int(start + length))s"
        guard let tracks else {
            print("[skipdetect] \(kind) subtitle check for \(catalogId) ep \(episode) \(window): unreadable in \(elapsed)s")
            return true
        }
        guard let chosen = SubtitleExtractor.dialogueTrack(tracks) else {
            print("[skipdetect] \(kind) subtitle check for \(catalogId) ep \(episode): no ASS track")
            return true
        }
        let (verdict, gap) = SubtitleGaps.verdict(dialogue: chosen.dialogue, from: start, to: start + length)
        print("[skipdetect] \(kind) subtitle check for \(catalogId) ep \(episode) \(window): \(verdict), \(chosen.dialogue.count) dialogue lines, longest pause \(gap.map { "\(Int($0))s" } ?? "-") in \(elapsed)s")
        guard verdict == .absent else { return true }
        print("[skipdetect] no \(name) in \(catalogId) ep \(episode); not fetching ep \(neighbour) to compare")
        guard !Task.isCancelled,
              currentPlaybackCatalogId == catalogId, currentPlaybackEpisode == episode else { return false }
        let label = kind == "op" ? "Opening" : "Ending"
        playerController.skipDetectionStatus = "\(label): none in this episode (the dialogue never pauses for one)"
        noteAudioSearchFailed("No \(name) in this episode")
        return false
    }

    enum StoredSearch { case found, missed, failed }

    /// The stored opening searched for past the head window. Watari-kun
    /// ep 18 missed both the stored opening and the comparison with ep 19,
    /// both of which read only the first 8 minutes, in a show whose ep 16
    /// opening started at 5:39 [GUESS: a cold open past ~7:45]. Only a file
    /// already on disk over that stretch is read: at this point in playback
    /// it runs up to 13 minutes ahead of the playhead, and pulling that
    /// through a live swarm is what the lookahead gate exists to prevent.
    private func findStoredLateOpening(catalogId: Int64, episode: Int64, url: String,
                                       preferDub: Bool, announceMiss: Bool) async -> StoredSearch {
        let start = Self.skipLateOpeningStart
        let end = start + Self.skipLateOpeningLength
        let duration = playerController.duration
        let reason: String?
        if duration <= end {
            reason = "the episode is only \(Int(duration))s"
        } else if playerController.currentTime >= end - 15 {
            // 15s is `skip::MIN_SEGMENT_SECONDS`: less of the window than
            // that left ahead cannot hold a match worth skipping.
            reason = "the playhead is past \(Int(end))s"
        } else {
            let buffered = playerController.torrentBufferedFractions
            let covered = buffered.isEmpty
                || buffered.contains(where: { $0.start <= start / duration && $0.end >= end / duration })
            reason = covered ? nil : "\(Int(start))-\(Int(end))s is not on disk yet"
        }
        if let reason {
            print("[skipdetect] late op search for \(catalogId) ep \(episode) skipped: \(reason)")
            if announceMiss { apply(nil, kind: "op", catalogId: catalogId, episode: episode, source: "") }
            return .missed
        }
        print("[skipdetect] stored op not in ep \(episode)'s first \(Int(Self.skipHeadSeconds))s; searching \(Int(start))-\(Int(end))s")
        return await findStored(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                start: start, length: Self.skipLateOpeningLength, preferDub: preferDub,
                                announceMiss: announceMiss)
    }

    /// `announceMiss: false` when a caller falls back on a miss: "not found"
    /// followed minutes later by a skip window reads as a wrong answer.
    @discardableResult
    private func findStored(kind: String, catalogId: Int64, episode: Int64, url: String,
                            start: Double, length: Double, preferDub: Bool,
                            announceMiss: Bool = true) async -> StoredSearch {
        guard let engine else { return .failed }
        let file = Self.skipScratchDirectory().appendingPathComponent("\(catalogId)-\(episode)-\(kind).raw")
        defer { try? FileManager.default.removeItem(at: file) }
        let name = kind == "op" ? "opening" : "ending"
        guard await streamCanServe(start: start, length: length) else {
            print("[skipdetect] \(kind) audio for \(catalogId) ep \(episode) unreadable: the stream is not being served")
            playerController.skipDetectionStatus = "The stream has no peers; nothing to read the \(name) from"
            noteAudioSearchFailed("No skip times: this release has no seeders")
            return .failed
        }
        playerController.skipDetectionStatus = "Searching this episode's audio for the stored \(name)"
        let began = Date()
        guard await AudioExtractor.extract(url: url, start: start, length: length, preferDub: preferDub, to: file),
              !Task.isCancelled else {
            print("[skipdetect] \(kind) audio for \(catalogId) ep \(episode) not extracted")
            playerController.skipDetectionStatus = "Could not read enough of this episode's audio"
            noteAudioSearchFailed("No skip times: could not read the audio")
            return .failed
        }
        let path = file.path
        let span = await Task.detached(priority: .utility) {
            engine.findSkipSegment(catalog: .anilist, catalogId: catalogId, kind: kind, pcmPath: path, offset: start)
                .map { (start: $0.start, end: $0.end) }
        }.value
        print("[skipdetect] \(kind) reference in \(catalogId) ep \(episode): \(span.map { "\(Int($0.start))-\(Int($0.end))s" } ?? "not found") in \(Int(Date().timeIntervalSince(began)))s")
        guard span != nil || announceMiss else { return .missed }
        apply(span, kind: kind, catalogId: catalogId, episode: episode, source: "matched the stored fingerprint")
        return span == nil ? .missed : .found
    }

    private func apply(_ span: (start: Double, end: Double)?, kind: String, catalogId: Int64, episode: Int64, source: String) {
        guard !Task.isCancelled,
              currentPlaybackCatalogId == catalogId, currentPlaybackEpisode == episode else { return }
        let name = kind == "op" ? "Opening" : "Ending"
        guard let span else {
            playerController.skipDetectionStatus = "\(name): not found in the audio"
            noteAudioSearchFailed("No \(name.lowercased()) found in the audio")
            return
        }
        playerController.skipDetectionStatus = "\(name) \(PlayerController.formatTimestamp(span.start))-\(PlayerController.formatTimestamp(span.end)), \(source)"
        // Chapters or AniSkip may have answered while the audio decoded;
        // those are better sources and keep the window.
        if kind == "op" {
            guard !hasSkipWindow(.opening) else { return }
            playerController.setDetectedOpening(start: span.start, end: span.end)
        } else {
            guard !hasSkipWindow(.ending) else { return }
            playerController.setDetectedEnding(start: span.start, end: span.end)
        }
    }

    static func skipScratchDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("anicat-skip", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
