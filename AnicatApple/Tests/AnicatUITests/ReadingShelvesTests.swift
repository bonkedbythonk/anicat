import Testing
import Foundation
import AnicatCoreKit
@testable import AnicatUI

@Suite("Reading shelves: the manga/novel split")
struct ReadingShelvesTests {
    private func summary(_ id: Int64, _ title: String, format: String?) -> MediaSummary {
        MediaSummary(
            catalog: .anilist,
            catalogId: id,
            title: title,
            coverImage: "",
            format: format,
            episodes: nil,
            chapters: nil,
            averageScore: nil,
            progress: nil,
            listStatus: "PLANNING",
            userScore: nil,
            updatedAt: nil,
            nextAiringAt: nil,
            nextEpisode: nil
        )
    }

    @Test("A NOVEL row goes to the novel shelf and every other format to the manga shelf")
    @MainActor
    func splitsOnFormat() {
        let rows = [
            summary(1, "Manga A", format: "MANGA"),
            summary(2, "Novel A", format: "NOVEL"),
            summary(3, "One Shot", format: "ONE_SHOT"),
            // AniList omits `format` on some older entries; that is a manga
            // shelf entry, not a novel one, so it must not be dropped or
            // filed under Light Novels.
            summary(4, "Unformatted", format: nil)
        ]
        let split = AppModel.splitByFormat(rows)
        #expect(split.manga.map(\.id) == [1, 3, 4])
        #expect(split.novel.map(\.id) == [2])
    }

    @Test("The split keeps AniList's own list order rather than re-sorting")
    func preservesOrder() {
        let rows = [
            summary(30, "Third", format: "MANGA"),
            summary(10, "First", format: "MANGA"),
            summary(20, "Second", format: "MANGA")
        ]
        #expect(AppModel.splitByFormat(rows).manga.map(\.title) == ["Third", "First", "Second"])
    }

    @Test("An empty list yields two empty shelves, so neither renders")
    @MainActor
    func emptyList() {
        let split = AppModel.splitByFormat([])
        #expect(split.manga.isEmpty)
        #expect(split.novel.isEmpty)
    }
}
