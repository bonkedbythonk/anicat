import Testing
import Foundation
@testable import AnicatUI

@Suite("Schedule calendar: the month grid")
struct CalendarLayoutTests {
    /// A fixed calendar rather than `.current`: `firstWeekday` is 1 in the
    /// US and 2 across most of Europe, and a Monday-first grid that read it
    /// would pass or fail on the runner's region rather than on the code.
    /// UTC keeps the day boundaries the assertions talk about stable too.
    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        cal.firstWeekday = 1
        return cal
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func grid(_ year: Int, _ month: Int) -> [CalendarView.DayCell] {
        CalendarView.monthGrid(for: date(year, month, 1), calendar: calendar)
    }

    @Test("The grid is always whole Monday-to-Sunday weeks")
    func wholeWeeks() {
        for month in 1...12 {
            let cells = grid(2026, month)
            #expect(cells.count % 7 == 0)
            #expect(calendar.component(.weekday, from: cells[0].date) == 2)
            #expect(calendar.component(.weekday, from: cells[cells.count - 1].date) == 1)
        }
    }

    @Test("A month starting mid-week is padded back to the preceding Monday")
    func leadingPadding() {
        // 1 September 2026 is a Tuesday, so exactly one pad day (31 August).
        let cells = grid(2026, 9)
        #expect(cells.count == 35)
        #expect(!cells[0].inMonth)
        #expect(calendar.component(.day, from: cells[0].date) == 31)
        #expect(cells[1].inMonth)
        #expect(calendar.component(.day, from: cells[1].date) == 1)
    }

    @Test("A month starting on a Monday gets no leading padding")
    func noLeadingPadding() {
        // 1 June 2026 is a Monday.
        let cells = grid(2026, 6)
        #expect(cells[0].inMonth)
        #expect(calendar.component(.day, from: cells[0].date) == 1)
    }

    @Test("A leap February carries all 29 days")
    func leapFebruary() {
        let cells = grid(2024, 2)
        #expect(cells.filter(\.inMonth).count == 29)
        // 1 February 2024 is a Thursday: three pad days back to 29 January.
        #expect(cells.prefix(3).allSatisfy { !$0.inMonth })
        #expect(calendar.component(.day, from: cells[3].date) == 1)
        #expect(calendar.component(.day, from: cells.last!.date) == 3)
    }

    @Test("A common February carries 28")
    func commonFebruary() {
        #expect(grid(2023, 2).filter(\.inMonth).count == 28)
        #expect(grid(2100, 2).filter(\.inMonth).count == 28)
    }

    @Test("A 28-day February starting on a Monday is exactly four weeks, no padding")
    func exactFebruary() {
        // The only shape that fills whole weeks with nothing padded at either
        // end, so it is where a week count that rounded up unconditionally
        // would draw a phantom fifth row of March.
        let cells = grid(2021, 2)
        #expect(cells.count == 28)
        #expect(cells.allSatisfy { $0.inMonth })
    }

    @Test("Pad cells belong to the neighbouring months, not this one")
    func padCellsAreOutOfMonth() {
        let cells = grid(2026, 9)
        for cell in cells {
            let sameMonth = calendar.component(.month, from: cell.date) == 9
            #expect(cell.inMonth == sameMonth)
        }
    }
}
