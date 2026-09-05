import Foundation

/// A stale-while-revalidate disk cache for the detail page, keyed by
/// catalog id + media kind.
///
/// AniList's own detail cache in `core/` is in-memory only and gone on every
/// relaunch, and even within a session, opening a title after a burst of
/// other AniList calls (home shelves, search, list sync) can queue behind
/// AniList's real rate limit — the client throttles itself proactively once
/// its remaining budget gets low, and that backoff stacks across requests.
/// The fix here isn't to make the network faster; it's to stop the UI from
/// staring at a blank spinner while it waits at all. A title opened before
/// renders instantly from the last snapshot saved to disk, while a fresh
/// fetch runs underneath and silently replaces it when it lands — so a slow
/// or rate-limited AniList round trip is invisible for anything already
/// seen this install, and only a genuinely first-ever open pays for it.
enum DetailCache {
    struct Snapshot: Codable {
        var details: HeroBanner.Details
        var episodes: [MediaDetailView.EpisodeItem]
        var mangaChapters: [MediaDetailView.MangaChapterItem]
        var relations: [MediaDetailView.RelationItem]
        var recommendations: [MediaDetailView.RecommendationItem]
        var characters: [MediaDetailView.CharacterItem]
        var discussions: [MediaDetailView.DiscussionItem]
    }

    private static let directory: URL = {
        // `.cachesDirectory`, not Application Support: this snapshot is a
        // disposable revalidate-in-background copy, and Application Support
        // is what iCloud/Time Machine back up — every title ever opened was
        // riding along in every backup for a file that regenerates itself on
        // the next fetch.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Anicat", isDirectory: true).appendingPathComponent("detail-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Maximum number of detail snapshots retained in local storage cache.
    static let maxEntries = 150
    /// Maximum age (14 days) before a cached detail snapshot is automatically evicted.
    static let maxAge: TimeInterval = 14 * 24 * 60 * 60

    static func fileURL(id: Int64, isManga: Bool) -> URL {
        directory.appendingPathComponent("\(isManga ? "manga" : "anime")-\(id).json")
    }

    /// Never throws — a missing, corrupt, or unreadable cache file just
    /// means "nothing to show yet", not a load failure. The real fetch runs
    /// regardless of what this returns.
    static func load(id: Int64, isManga: Bool) -> Snapshot? {
        let url = fileURL(id: id, isManga: isManga)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // Touch modification date on access to keep recently-viewed items fresh for LRU
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Seconds since this snapshot was written, read *before* `load()` touches
    /// the mtime for LRU purposes — call this first if both are needed.
    static func ageInSeconds(id: Int64, isManga: Bool) -> TimeInterval? {
        let url = fileURL(id: id, isManga: isManga)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modDate = values.contentModificationDate else { return nil }
        return Date().timeIntervalSince(modDate)
    }

    static func save(_ snapshot: Snapshot, id: Int64, isManga: Bool) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL(id: id, isManga: isManga), options: .atomic)
        Task.detached(priority: .background) {
            pruneCacheIfNeeded()
        }
    }

    /// Prunes files older than `maxTime` and keeps at most `maxCount` entries (LRU).
    /// Defaults to `directory`, `maxEntries`, and `maxAge`.
    static func pruneCacheIfNeeded(
        targetDirectory: URL = directory,
        maxCount: Int = maxEntries,
        maxTime: TimeInterval = maxAge
    ) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: targetDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let now = Date()
        var validFiles: [(url: URL, date: Date)] = []

        for url in urls where url.pathExtension == "json" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
                  let modDate = values.contentModificationDate else {
                try? fm.removeItem(at: url)
                continue
            }

            if now.timeIntervalSince(modDate) > maxTime {
                try? fm.removeItem(at: url)
            } else {
                validFiles.append((url: url, date: modDate))
            }
        }

        if validFiles.count > maxCount {
            validFiles.sort(by: { $0.date > $1.date }) // newest first
            for file in validFiles.dropFirst(maxCount) {
                try? fm.removeItem(at: file.url)
            }
        }
    }
}
