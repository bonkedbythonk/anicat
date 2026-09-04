import Testing
import Foundation
@testable import AnicatUI

@Suite("PickerSheet Heuristics & Recommendations")
struct PickerSheetTests {
    @Test("Continue mood pulls and merges candidates from watching and upNext")
    func testContinuePool() {
        let watchingItem = MediaCard.Item(
            id: 101,
            title: "Frieren: Beyond Journey's End",
            coverImageURL: nil,
            isManga: false,
            score: 95,
            progress: 26,
            totalEpisodesOrChapters: 28,
            hasNewEpisode: false
        )
        let queueItem = UpNextQueueView.QueueEntry(
            id: 102,
            title: "Dungeon Meshi",
            thumbnailURL: nil,
            nextEpisodeOrChapter: 12,
            totalCount: 24,
            progressPercent: 50.0,
            hasNewEpisode: true,
            unit: "EP"
        )

        let candidates = PickerSheet.scoreCandidates(
            watching: [watchingItem],
            upNext: [queueItem],
            planning: [],
            trending: [],
            mood: .continue,
            filterShort: false,
            filterComfy: false,
            filterIntense: false,
            currentHour: 14,
            jitterRange: nil
        )

        #expect(candidates.count == 2)
        let ids = Set(candidates.map(\.id))
        #expect(ids.contains(101))
        #expect(ids.contains(102))
    }

    @Test("Completed shows are excluded from Continue mood")
    func testCompletedShowsExcluded() {
        let completedItem = MediaCard.Item(
            id: 201,
            title: "Cowboy Bebop",
            coverImageURL: nil,
            progress: 26,
            totalEpisodesOrChapters: 26
        )

        let candidates = PickerSheet.scoreCandidates(
            watching: [completedItem],
            mood: .continue,
            filterShort: false,
            filterComfy: false,
            filterIntense: false,
            jitterRange: nil
        )

        #expect(candidates.isEmpty)
    }

    @Test("Scoring generates 'only N episodes left' and finishes-it boost")
    func testOnlyNEpisodesLeft() {
        let nearlyFinished = MediaCard.Item(
            id: 301,
            title: "Steins;Gate",
            coverImageURL: nil,
            progress: 22,
            totalEpisodesOrChapters: 24
        )

        let candidates = PickerSheet.scoreCandidates(
            watching: [nearlyFinished],
            mood: .continue,
            filterShort: false,
            filterComfy: false,
            filterIntense: false,
            currentHour: 14,
            jitterRange: nil
        )

        #expect(candidates.count == 1)
        let first = candidates[0]
        #expect(first.score >= 30)
        #expect(first.reasons.contains { $0.contains("only 2 episodes left") })
    }

    @Test("Scoring surfaces 'a new episode is out' for releasing shows")
    func testNewEpisodeOut() {
        let newEpItem = MediaCard.Item(
            id: 401,
            title: "Spy x Family",
            coverImageURL: nil,
            progress: 10,
            totalEpisodesOrChapters: 25,
            hasNewEpisode: true
        )

        let candidates = PickerSheet.scoreCandidates(
            watching: [newEpItem],
            mood: .continue,
            filterShort: false,
            filterComfy: false,
            filterIntense: false,
            currentHour: 14,
            jitterRange: nil
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].reasons.contains("a new episode is out"))
    }

    @Test("Late-night flavor text is included for short counts in evening hours")
    func testLateNightFlavorText() {
        let shortItem = MediaCard.Item(
            id: 501,
            title: "FLCL",
            coverImageURL: nil,
            progress: 2,
            totalEpisodesOrChapters: 6
        )

        let candidates = PickerSheet.scoreCandidates(
            watching: [shortItem],
            mood: .continue,
            filterShort: true,
            filterComfy: false,
            filterIntense: false,
            currentHour: 23,
            jitterRange: nil
        )

        #expect(candidates.count == 1)
        #expect(candidates[0].reasons.contains("short episodes suit a late night"))
    }

    @Test("Something New mood pulls planning and trending while filtering watching")
    func testSomethingNewPool() {
        let watchingItem = MediaCard.Item(id: 601, title: "Watching", coverImageURL: nil)
        let planningItem = MediaCard.Item(id: 602, title: "Planning", coverImageURL: nil, score: 88, totalEpisodesOrChapters: 12)
        let trendingItem = MediaCard.Item(id: 603, title: "Trending", coverImageURL: nil, score: 82, totalEpisodesOrChapters: 24)

        let candidates = PickerSheet.scoreCandidates(
            watching: [watchingItem],
            planning: [planningItem],
            trending: [trendingItem, watchingItem],
            mood: .somethingNew,
            filterShort: false,
            filterComfy: false,
            filterIntense: false,
            currentHour: 14,
            jitterRange: nil
        )

        #expect(candidates.count == 2)
        let ids = candidates.map(\.id)
        #expect(ids.contains(602))
        #expect(ids.contains(603))
        #expect(!ids.contains(601))

        let planningCandidate = candidates.first { $0.id == 602 }
        #expect(planningCandidate?.reasons.contains("from your planning list") == true)
        #expect(planningCandidate?.reasons.contains("rated 88% on AniList") == true)
    }

    @Test("Filter chips filter by episode count bands")
    func testFilterChips() {
        let shortShow = MediaCard.Item(id: 701, title: "Short", coverImageURL: nil, totalEpisodesOrChapters: 12)
        let longShow = MediaCard.Item(id: 702, title: "Long", coverImageURL: nil, totalEpisodesOrChapters: 75)

        let shortFiltered = PickerSheet.scoreCandidates(
            planning: [shortShow, longShow],
            mood: .somethingNew,
            filterShort: true,
            filterComfy: false,
            filterIntense: false,
            jitterRange: nil
        )
        #expect(shortFiltered.map(\.id) == [701])

        let intenseFiltered = PickerSheet.scoreCandidates(
            planning: [shortShow, longShow],
            mood: .somethingNew,
            filterShort: false,
            filterComfy: false,
            filterIntense: true,
            jitterRange: nil
        )
        #expect(intenseFiltered.map(\.id) == [702])
    }
}
