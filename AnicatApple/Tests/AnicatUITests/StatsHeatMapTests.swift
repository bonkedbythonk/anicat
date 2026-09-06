import Testing
import Foundation
@testable import AnicatUI

@Suite("Stats: heat map bucketing and layout")
struct StatsHeatMapTests {
    /// Fixed rather than `.current` for the same reason the calendar tests
    /// use one: a Monday-first row order must not depend on the runner's
    /// region, and UTC keeps the day boundaries stable.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test("An untouched day is the empty bucket whatever the scale")
    func zeroEpisodes() {
        #expect(StatsView.heatBucket(episodes: 0, max: 0) == 0)
        #expect(StatsView.heatBucket(episodes: 0, max: 40) == 0)
    }

    @Test("A year with no watching at all does not divide by its zero maximum")
    func zeroMaximum() {
        #expect(StatsView.heatBucket(episodes: 5, max: 0) == 0)
    }

    @Test("Buckets split the range against the busiest day, quarter by quarter")
    func quarters() {
        #expect(StatsView.heatBucket(episodes: 1, max: 8) == 1)
        #expect(StatsView.heatBucket(episodes: 2, max: 8) == 1)
        #expect(StatsView.heatBucket(episodes: 3, max: 8) == 2)
        #expect(StatsView.heatBucket(episodes: 4, max: 8) == 2)
        #expect(StatsView.heatBucket(episodes: 5, max: 8) == 3)
        #expect(StatsView.heatBucket(episodes: 6, max: 8) == 3)
        #expect(StatsView.heatBucket(episodes: 7, max: 8) == 4)
        #expect(StatsView.heatBucket(episodes: 8, max: 8) == 4)
    }

    @Test("The busiest day is always the darkest step, however light the year")
    func busiestDayIsFull() {
        #expect(StatsView.heatBucket(episodes: 1, max: 1) == 4)
        #expect(StatsView.heatBucket(episodes: 300, max: 300) == 4)
    }

    /// One tally per day from `start`, all one episode, so the assertions are
    /// about placement rather than colour.
    private func run(from start: Date, days: Int) -> [StatsView.DayTally] {
        (0..<days).map { offset in
            StatsView.DayTally(
                date: calendar.date(byAdding: .day, value: offset, to: start)!,
                episodes: 1,
                seconds: 1400
            )
        }
    }

    @Test("Columns are always seven tall")
    func columnsAreWeeks() {
        for length in [1, 6, 7, 8, 364, 365, 366] {
            let columns = StatsView.heatColumns(run(from: date(2026, 1, 1), days: length), calendar: calendar)
            #expect(columns.allSatisfy { $0.count == 7 })
            #expect(columns.flatMap { $0 }.compactMap { $0 }.count == length)
        }
    }

    @Test("The first tally lands on its own weekday row, Monday first")
    func leadingPad() {
        // 1 January 2026 is a Thursday, so three blank cells above it.
        let columns = StatsView.heatColumns(run(from: date(2026, 1, 1), days: 30), calendar: calendar)
        #expect(columns[0][0] == nil)
        #expect(columns[0][1] == nil)
        #expect(columns[0][2] == nil)
        #expect(columns[0][3]?.date == date(2026, 1, 1))
    }

    @Test("A run starting on a Monday has no leading pad")
    func mondayStart() {
        // 5 January 2026 is a Monday.
        let columns = StatsView.heatColumns(run(from: date(2026, 1, 5), days: 14), calendar: calendar)
        #expect(columns.count == 2)
        #expect(columns[0][0]?.date == date(2026, 1, 5))
        #expect(columns.flatMap { $0 }.allSatisfy { $0 != nil })
    }

    @Test("An empty year produces no columns rather than one of blanks")
    func emptyRun() {
        #expect(StatsView.heatColumns([], calendar: calendar).isEmpty)
    }

    @Test("Only the first column of a month is labelled")
    func monthLabelsAreOncePerMonth() {
        let columns = StatsView.heatColumns(run(from: date(2026, 1, 1), days: 120), calendar: calendar)
        let labels = StatsView.monthLabels(for: columns, calendar: calendar)
        #expect(labels.values.sorted() == ["Apr", "Feb", "Jan", "Mar"])
    }

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
