import Testing
import Foundation
import Network
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

        if case .playback(let catalogId, let catalog, let title, let episode, let timePos) = payload {
            #expect(catalogId == 154587)
            // No catalog key at all, as an activity from a build before
            // cinema mode carries: everything those could play was AniList's.
            #expect(catalog == "anilist")
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

        if case .reading(let mangaId, _, let title, let chapter, let pageIndex) = payload {
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

    /// The advertising listener binds its own port, so a peer that reads the
    /// port off the resolved endpoint fetches from a listener that serves
    /// nothing. The TXT record is the only place the stream port exists.
    @Test("Bonjour TXT record carries the stream port")
    func testBonjourStreamPortFromTXTRecord() {
        var txtRecord = NWTXTRecord()
        txtRecord[BonjourDiscovery.streamPortTXTKey] = "51413"
        #expect(BonjourDiscovery.streamPort(from: .bonjour(txtRecord)) == 51413)

        // No TXT record at all is an older peer, which advertised on the
        // stream port itself — the caller falls back to the endpoint's port
        // rather than refusing the peer.
        #expect(BonjourDiscovery.streamPort(from: .none) == nil)

        var empty = NWTXTRecord()
        empty["something-else"] = "51413"
        #expect(BonjourDiscovery.streamPort(from: .bonjour(empty)) == nil)

        // Port 0 means "pick one for me" when binding and is never a real
        // destination, so it must not be handed to a caller as one.
        var zero = NWTXTRecord()
        zero[BonjourDiscovery.streamPortTXTKey] = "0"
        #expect(BonjourDiscovery.streamPort(from: .bonjour(zero)) == nil)

        var garbage = NWTXTRecord()
        garbage[BonjourDiscovery.streamPortTXTKey] = "not-a-port"
        #expect(BonjourDiscovery.streamPort(from: .bonjour(garbage)) == nil)
    }
}
