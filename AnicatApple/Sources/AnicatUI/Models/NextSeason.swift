import Foundation

/// The sequel offered once a season's last episode has been watched: on the
/// player's end card while it is still up, and on the home screen after.
public struct NextSeasonOffer: Codable, Equatable, Identifiable, Sendable {
    public let sequelId: Int64
    public let title: String
    public let coverImage: String
    /// The season just finished, named on the home row so "Season 2" does
    /// not read as an unrelated recommendation.
    public let sourceId: Int64
    public let sourceTitle: String
    /// False for a sequel AniList lists as NOT_YET_RELEASED: it can go on the
    /// list but there is no episode 1 to play.
    public let isReleased: Bool

    public var id: Int64 { sequelId }
}

enum NextSeason {
    /// Only a finished season counts. A caught-up weekly show also has no
    /// next episode, and a film has no total; the same total/progress rule as
    /// the COMPLETED clamp in `AppModel.listEntryUpdate`.
    static func isFinale(episode: Int, total: Int?) -> Bool {
        guard let total, total > 0 else { return false }
        return episode >= total
    }

    /// A sequel already started, finished, dropped or paused is the viewer's
    /// own decision; only an untouched or planned one is worth offering.
    static func isOfferable(listStatus: String?) -> Bool {
        listStatus == nil || listStatus == "PLANNING"
    }

    /// The status "Add to watching" writes, or nil when the entry needs no
    /// write. An unreleased sequel is planned, not watching: CURRENT with no
    /// episode to play would sit on Up Next as "awaiting" forever.
    static func statusToWrite(listStatus: String?, isReleased: Bool) -> String? {
        guard isOfferable(listStatus: listStatus) else { return nil }
        if isReleased { return "CURRENT" }
        return listStatus == "PLANNING" ? nil : "PLANNING"
    }

    static let pendingKey = "anicat_pending_next_seasons"
    static let dismissedKey = "anicat_dismissed_next_seasons"

    static func loadPending() -> [NextSeasonOffer] {
        guard let data = UserDefaults.standard.data(forKey: pendingKey),
              let offers = try? JSONDecoder().decode([NextSeasonOffer].self, from: data) else { return [] }
        return offers
    }

    static func savePending(_ offers: [NextSeasonOffer]) {
        UserDefaults.standard.set(try? JSONEncoder().encode(offers), forKey: pendingKey)
    }

    static func dismissedIds() -> Set<Int64> {
        let raw = UserDefaults.standard.array(forKey: dismissedKey) as? [Int64] ?? []
        return Set(raw)
    }

    static func rememberDismissed(_ id: Int64) {
        var ids = dismissedIds()
        ids.insert(id)
        UserDefaults.standard.set(Array(ids), forKey: dismissedKey)
    }
}
