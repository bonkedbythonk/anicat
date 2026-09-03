import Foundation
import SwiftUI

public final class ContinuityManager: @unchecked Sendable {
    public static let shared = ContinuityManager()

    public static let playbackActivityType = "com.anicat.playback"
    public static let readingActivityType = "com.anicat.reading"

    private var currentActivity: NSUserActivity?

    private init() {}

    /// Broadcasts current playback state for Apple Handoff (desk-to-bed continuity).
    public func advertisePlayback(
        catalogId: Int64,
        title: String,
        episode: Int,
        timePositionSeconds: Double
    ) {
        let activity = NSUserActivity(activityType: Self.playbackActivityType)
        activity.title = "Watching \(title) - Episode \(episode)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true
        activity.isEligibleForPublicIndexing = false

        activity.userInfo = [
            "catalogId": catalogId,
            "title": title,
            "episode": episode,
            "timePosition": timePositionSeconds,
            "timestamp": Date().timeIntervalSince1970
        ]

        activity.requiredUserInfoKeys = ["catalogId", "episode", "timePosition"]
        activity.becomeCurrent()
        self.currentActivity = activity
    }

    /// Broadcasts current manga reading state for Apple Handoff.
    public func advertiseReading(
        mangaId: String,
        title: String,
        chapter: String,
        pageIndex: Int
    ) {
        let activity = NSUserActivity(activityType: Self.readingActivityType)
        activity.title = "Reading \(title) - Chapter \(chapter)"
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = true

        activity.userInfo = [
            "mangaId": mangaId,
            "title": title,
            "chapter": chapter,
            "pageIndex": pageIndex,
            "timestamp": Date().timeIntervalSince1970
        ]

        activity.requiredUserInfoKeys = ["mangaId", "chapter", "pageIndex"]
        activity.becomeCurrent()
        self.currentActivity = activity
    }

    /// Invalidates current Handoff activity when playback or reading stops.
    public func stopAdvertising() {
        currentActivity?.invalidate()
        currentActivity = nil
    }

    /// Parses an incoming Handoff activity from another Apple device.
    public func parseIncomingActivity(_ activity: NSUserActivity) -> HandoffPayload? {
        guard let userInfo = activity.userInfo else { return nil }

        if activity.activityType == Self.playbackActivityType,
           let catalogId = userInfo["catalogId"] as? Int64,
           let episode = userInfo["episode"] as? Int,
           let timePos = userInfo["timePosition"] as? Double {
            let title = userInfo["title"] as? String ?? "Episode \(episode)"
            return .playback(catalogId: catalogId, title: title, episode: episode, timePosition: timePos)
        }

        if activity.activityType == Self.readingActivityType,
           let mangaId = userInfo["mangaId"] as? String,
           let chapter = userInfo["chapter"] as? String,
           let pageIndex = userInfo["pageIndex"] as? Int {
            let title = userInfo["title"] as? String ?? "Manga"
            return .reading(mangaId: mangaId, title: title, chapter: chapter, pageIndex: pageIndex)
        }

        return nil
    }

    public enum HandoffPayload: Sendable {
        case playback(catalogId: Int64, title: String, episode: Int, timePosition: Double)
        case reading(mangaId: String, title: String, chapter: String, pageIndex: Int)
    }
}
