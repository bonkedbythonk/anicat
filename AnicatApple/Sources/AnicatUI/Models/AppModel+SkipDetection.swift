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
        guard let engine,
              let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let url = activeStreamURL?.absoluteString else {
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
        guard !hasSkipWindow(.opening) else {
            playerController.skipDetectionStatus = "Opening already known from chapters or AniSkip"
            return
        }
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        // Chained, not cancelled: this is called again from every AniSkip
        // answer, and cancelling here tore down a bootstrap comparison that
        // was already resolving the next episode. A new episode's task is
        // cancelled where it should be, in `resolveAndPlay`.
        let previous = skipDetectionTask
        skipDetectionTask = Task { [weak self] in
            await previous?.value
            // A SQLite read: off the main actor like every other registry call.
            let hasReference = await Task.detached(priority: .utility) {
                engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "op")
            }.value
            guard let self, !Task.isCancelled, !self.hasSkipWindow(.opening) else { return }
            guard hasReference else {
                print("[skipdetect] no op reference for \(catalogId) yet; waiting for the next episode's preload")
                self.playerController.skipDetectionStatus = "No reference yet; comparing with the next episode once it preloads"
                return
            }
            await self.findStored(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                  start: 0, length: Self.skipHeadSeconds, preferDub: preferDub)
        }
    }

    /// The first episode of a show watched has no stored opening to search
    /// for, and the pair comparison used to wait for the 75% preload — by
    /// which point its own opening had played 20 minutes ago. This resolves
    /// the next episode early, purely to learn the opening from, and skips
    /// this episode's too when the swarm is quick enough to answer before it
    /// ends. Whatever it learns is stored either way, so episode two onward
    /// never waits again.
    func bootstrapOpeningDetection() {
        guard currentPlaybackCatalog == .anilist,
              let engine,
              let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let url = activeStreamURL?.absoluteString,
              !hasSkipWindow(.opening) else { return }
        guard playerController.duration > Self.skipHeadSeconds else { return }
        // The same pick as the 75% preload: the next episode that has aired.
        let sorted = playbackEpisodes
        guard let index = sorted.firstIndex(where: { $0.number == Int(episode) }),
              sorted.indices.contains(index + 1),
              sorted[index + 1].isAired else {
            // An empty list is one `ensurePlaybackEpisodes` is still filling,
            // so the next tick tries again; anything else is a settled "there
            // is no later episode" and must not print once a second for the
            // rest of the episode.
            if !sorted.isEmpty {
                hasBootstrappedOpening = true
                print("[skipdetect] nothing later than ep \(episode) to learn \(catalogId)'s opening from")
            }
            return
        }
        // Not while the swarm is only just keeping the playing episode fed:
        // a pair comparison over a live torrent measured 180s + 121s of
        // decode competing with the episode being watched. An empty list is
        // a file already on disk, the one case this cannot slow down.
        let buffered = playerController.torrentBufferedFractions
        if !buffered.isEmpty {
            let duration = playerController.duration
            let here = playerController.currentTime / duration
            let ahead = min((playerController.currentTime + Self.skipBootstrapLookaheadSeconds) / duration, 1)
            guard buffered.contains(where: { $0.start <= here && $0.end >= ahead }) else { return }
        }
        hasBootstrappedOpening = true
        let next = Int64(sorted[index + 1].number)
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        let title = currentPlaybackTitle
        let previous = skipDetectionTask
        skipDetectionTask = Task { [weak self] in
            await previous?.value
            let hasOpening = await Task.detached(priority: .utility) {
                engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "op")
            }.value
            // A reference can have landed while this waited — the preload
            // path runs the same comparison — and then the cheap search of
            // this episode alone is the right one.
            guard let self, !Task.isCancelled, !self.hasSkipWindow(.opening) else { return }
            guard !hasOpening else {
                await self.findStored(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                      start: 0, length: Self.skipHeadSeconds, preferDub: preferDub)
                return
            }
            self.playerController.skipDetectionStatus = "Fetching episode \(next) to learn the opening from"
            let req = StreamRequest(
                catalog: .anilist,
                catalogId: catalogId,
                episode: next,
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
            guard !Task.isCancelled, self.currentPlaybackEpisode == episode else { return }
            guard let otherURL else {
                print("[skipdetect] ep \(next) of \(catalogId) did not resolve, no opening to learn")
                self.playerController.skipDetectionStatus = "Episode \(next) did not resolve; nothing to compare with"
                return
            }
            print("[skipdetect] ep \(next) of \(catalogId) resolved in \(Int(Date().timeIntervalSince(began)))s to learn the opening from")
            // `hasPreloadedNextEpisode` stays false on purpose. Setting it
            // here skipped the 75% preload, and with it `nextEpisodePreloaded`
            // — the only path that learns an *ending* from scratch, so this
            // episode traded its outro for its opening. The preload's own
            // resolve is the cheap reuse path once this one has added the
            // torrent (measured 798-955ms).
            self.preloadedNextStream = (catalogId, next, otherURL)
            self.playerController.skipDetectionStatus = "Comparing episodes \(episode) and \(next)"
            // The full head window, not a cheaper one: this show's own first
            // episode opens at 299s (the cold open before it runs that long),
            // and a 300s window would have read one second of the opening.
            await self.comparePair(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                   otherURL: otherURL, start: 0,
                                   length: Self.skipHeadSeconds, preferDub: preferDub)
        }
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
            guard hasEnding else {
                print("[skipdetect] no ed reference for \(catalogId) yet; waiting for the next episode's preload")
                return
            }
            await self.findStored(kind: "ed", catalogId: catalogId, episode: episode, url: url,
                                  start: tailStart, length: Self.skipTailSeconds, preferDub: preferDub)
        }
    }

    /// The preload landed. With a stored ending, search this episode's tail
    /// for it (the playhead is now close to it). Without references, compare
    /// the playing episode with the next one: the opening found is too late
    /// for this episode, but the ending usually is not, and every episode
    /// after this one has both.
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
            if needsEnding, !self.hasSkipWindow(.ending) {
                if hasEnding {
                    await self.findStored(kind: "ed", catalogId: catalogId, episode: playingEpisode, url: playingURL,
                                          start: tailStart, length: Self.skipTailSeconds, preferDub: preferDub)
                } else {
                    self.playerController.skipDetectionStatus = "Comparing episodes \(playingEpisode) and \(episode)"
                    // The next episode's duration is not known before it
                    // plays; releases of one show run within seconds of each
                    // other, and the tail window is wide enough to absorb that.
                    await self.comparePair(kind: "ed", catalogId: catalogId, episode: playingEpisode,
                                           url: playingURL, otherURL: url, start: tailStart,
                                           length: Self.skipTailSeconds, preferDub: preferDub)
                }
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
        let began = Date()
        // One after the other: both read through the torrent session, and the
        // playing episode's stream is the one that must not starve.
        guard await AudioExtractor.extract(url: url, start: start, length: length, preferDub: preferDub, to: mine),
              !Task.isCancelled,
              await AudioExtractor.extract(url: otherURL, start: start, length: length, preferDub: preferDub, to: other),
              !Task.isCancelled else {
            print("[skipdetect] \(kind) audio for \(catalogId) ep \(episode) not extracted")
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
        apply(span, kind: kind, catalogId: catalogId, episode: episode, source: "compared with the next episode")
    }

    private func findStored(kind: String, catalogId: Int64, episode: Int64, url: String,
                            start: Double, length: Double, preferDub: Bool) async {
        guard let engine else { return }
        let file = Self.skipScratchDirectory().appendingPathComponent("\(catalogId)-\(episode)-\(kind).raw")
        defer { try? FileManager.default.removeItem(at: file) }
        playerController.skipDetectionStatus = "Searching this episode's audio for the stored \(kind == "op" ? "opening" : "ending")"
        let began = Date()
        guard await AudioExtractor.extract(url: url, start: start, length: length, preferDub: preferDub, to: file),
              !Task.isCancelled else {
            print("[skipdetect] \(kind) audio for \(catalogId) ep \(episode) not extracted")
            return
        }
        let path = file.path
        let span = await Task.detached(priority: .utility) {
            engine.findSkipSegment(catalog: .anilist, catalogId: catalogId, kind: kind, pcmPath: path, offset: start)
                .map { (start: $0.start, end: $0.end) }
        }.value
        print("[skipdetect] \(kind) reference in \(catalogId) ep \(episode): \(span.map { "\(Int($0.start))-\(Int($0.end))s" } ?? "not found") in \(Int(Date().timeIntervalSince(began)))s")
        apply(span, kind: kind, catalogId: catalogId, episode: episode, source: "matched the stored fingerprint")
    }

    private func apply(_ span: (start: Double, end: Double)?, kind: String, catalogId: Int64, episode: Int64, source: String) {
        guard !Task.isCancelled,
              currentPlaybackCatalogId == catalogId, currentPlaybackEpisode == episode else { return }
        let name = kind == "op" ? "Opening" : "Ending"
        guard let span else {
            playerController.skipDetectionStatus = "\(name): not found in the audio"
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
