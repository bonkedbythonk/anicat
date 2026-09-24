import Testing
import Foundation
@testable import AnicatUI

@Suite("Stats: year in review")
struct StatsHeatMapTests {
    @Test("Year in review says nothing has happened rather than reporting zeroes")
    func emptyReview() {
        let text = StatsView.yearInReview(
            hours: 0, episodes: 0, titles: 0, longestStreak: 0, busiestHour: 0, topTitle: nil
        )
        #expect(text.contains("Nothing has been recorded"))
        #expect(!text.contains("0 episodes"))
    }

    @Test("Year in review singularises a one-episode, one-title, one-day year")
    func singulars() {
        let text = StatsView.yearInReview(
            hours: 0.4, episodes: 1, titles: 1, longestStreak: 1, busiestHour: 9, topTitle: "Frieren"
        )
        #expect(text.contains("1 episode across 1 title"))
        #expect(text.contains("1 day in a row"))
        #expect(text.contains("09:00"))
        #expect(text.contains("Frieren"))
    }
}
