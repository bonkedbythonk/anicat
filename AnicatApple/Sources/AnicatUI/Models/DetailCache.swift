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
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Anicat", isDirectory: true).appendingPathComponent("detail-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static func fileURL(id: Int64, isManga: Bool) -> URL {
        directory.appendingPathComponent("\(isManga ? "manga" : "anime")-\(id).json")
    }

    /// Never throws — a missing, corrupt, or unreadable cache file just
    /// means "nothing to show yet", not a load failure. The real fetch runs
    /// regardless of what this returns.
    static func load(id: Int64, isManga: Bool) -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL(id: id, isManga: isManga)) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    static func save(_ snapshot: Snapshot, id: Int64, isManga: Bool) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL(id: id, isManga: isManga), options: .atomic)
    }
}
