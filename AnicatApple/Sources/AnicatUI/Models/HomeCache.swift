import Foundation

/// Same stale-while-revalidate idea as `DetailCache`, applied to the home
/// screen's own shelves instead of one detail page: everything `refreshAll`
/// fills (Up Next, Watching, Trending, Schedule, Library, Manga/Novels,
/// Planning/Smart Picks/Newly Releasing/Seasonal) gets written here after
/// every successful refresh, and read back at launch before the engine has
/// even finished constructing. `AppModel.initialize` paints from this
/// immediately and skips the launch spinner entirely when a snapshot exists
/// — `refreshAll` still runs underneath and replaces it with live data, so a
/// relaunch shows last-known state instantly instead of a blank screen
/// staring at ~5 AniList round trips.
///
/// `viewer`/`activity` aren't part of this: `ViewerProfile`/`ActivityRow`
/// are uniffi-generated types with no `Codable` conformance, and neither
/// backs a screen a cold launch shows first.
enum HomeCache {
    struct Snapshot: Codable {
        var trending: [MediaCard.Item]
        var watching: [MediaCard.Item]
        var upNext: [UpNextQueueView.QueueEntry]
        var schedule: [ScheduleView.ScheduleItem]
        var library: [MediaCard.Item]
        var mangaTrending: [MediaCard.Item]
        var novelTrending: [MediaCard.Item]
        var mangaReading: [MediaCard.Item]
        var novelReading: [MediaCard.Item]
        var planning: [MediaCard.Item]
        var smartPicks: [MediaCard.Item]
        var newlyReleasing: [MediaCard.Item]
        var seasonal: [MediaCard.Item]
    }

    private static let fileURL: URL = {
        // See `DetailCache`'s note: this is a disposable revalidate-in-background
        // snapshot, not durable state, so it belongs in `.cachesDirectory` and
        // out of the iCloud/Time Machine backup that Application Support rides in.
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Anicat", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("home-cache.json")
    }()

    /// Never throws — a missing, corrupt, or unreadable cache just means
    /// "nothing to show yet"; the real fetch runs regardless.
    static func load() -> Snapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }

    /// Seconds since this snapshot was last saved, or `nil` if there isn't
    /// one. Cheap: reads the file's mtime rather than decoding it.
    static func ageInSeconds() -> TimeInterval? {
        guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
              let modDate = values.contentModificationDate else { return nil }
        return Date().timeIntervalSince(modDate)
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
