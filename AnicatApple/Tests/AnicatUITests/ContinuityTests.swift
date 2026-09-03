import Testing
import Foundation
@testable import AnicatUI

@Suite("Apple Continuity & Ecosystem Synergy Tests")
struct ContinuityTests {
    @Test("Handoff Playback Activity Creation & Parsing")
    func testHandoffPlaybackPayload() throws {
        let activity = NSUserActivity(activityType: ContinuityManager.playbackActivityType)
        activity.userInfo = [
            "catalogId": Int64(154587),
            "title": "Frieren: Beyond Journey's End",
            "episode": 5,
            "timePosition": 742.5
        ]

        let payload = ContinuityManager.shared.parseIncomingActivity(activity)
        #expect(payload != nil)

        if case .playback(let catalogId, let title, let episode, let timePos) = payload {
            #expect(catalogId == 154587)
            #expect(title == "Frieren: Beyond Journey's End")
            #expect(episode == 5)
            #expect(timePos == 742.5)
        } else {
            Issue.record("Expected playback payload")
        }
    }

    @Test("Handoff Manga Reading Activity Creation & Parsing")
    func testHandoffReadingPayload() throws {
        let activity = NSUserActivity(activityType: ContinuityManager.readingActivityType)
        activity.userInfo = [
            "mangaId": "frieren-mangadex-uuid",
            "title": "Sousou no Frieren",
            "chapter": "42",
            "pageIndex": 18
        ]

        let payload = ContinuityManager.shared.parseIncomingActivity(activity)
        #expect(payload != nil)

        if case .reading(let mangaId, let title, let chapter, let pageIndex) = payload {
            #expect(mangaId == "frieren-mangadex-uuid")
            #expect(title == "Sousou no Frieren")
            #expect(chapter == "42")
            #expect(pageIndex == 18)
        } else {
            Issue.record("Expected reading payload")
        }
    }

    @Test("Bonjour Service Identity")
    func testBonjourServiceType() {
        #expect(BonjourDiscovery.serviceType == "_anicat-stream._tcp")
        #expect(BonjourDiscovery.serviceDomain == "local.")
    }
}
