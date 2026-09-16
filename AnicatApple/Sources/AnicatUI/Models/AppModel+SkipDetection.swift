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

    /// Runs once the episode's other sources have answered. Only the opening
    /// is searched here, from a stored reference: the ending waits for the
    /// 75% preload (`nextEpisodePreloaded`). Decoding the tail at the start
    /// of an episode reads ~19 minutes ahead of the playhead, and on a slow
    /// swarm those pieces compete with the ones mpv is about to need.
    func startSkipDetection() {
        guard currentPlaybackCatalog == .anilist,
              let engine,
              let catalogId = currentPlaybackCatalogId,
              let episode = currentPlaybackEpisode,
              let url = activeStreamURL?.absoluteString else { return }
        let duration = playerController.duration
        guard duration > Self.skipHeadSeconds, !hasSkipWindow(.opening) else { return }
        let preferDub = UserDefaults.standard.string(forKey: "anicat_sub_dub") == "Dubbed"
        skipDetectionTask?.cancel()
        skipDetectionTask = Task { [weak self] in
            // A SQLite read: off the main actor like every other registry call.
            let hasReference = await Task.detached(priority: .utility) {
                engine.hasSkipReference(catalog: .anilist, catalogId: catalogId, kind: "op")
            }.value
            guard let self, !Task.isCancelled else { return }
            guard hasReference else {
                self.playerController.skipDetectionStatus = "No reference yet; comparing with the next episode once it preloads"
                return
            }
            await self.findStored(kind: "op", catalogId: catalogId, episode: episode, url: url,
                                  start: 0, length: Self.skipHeadSeconds, preferDub: preferDub)
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
              let playingURL = activeStreamURL?.absoluteString else { return }
        let duration = playerController.duration
        guard duration > Self.skipHeadSeconds else { return }
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
