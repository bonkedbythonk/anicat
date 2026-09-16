import Testing
import Foundation
@testable import AnicatUI

@Suite("Watch Order")
struct WatchOrderTests {
    private func entry(
        _ id: Int64,
        _ relationType: String?,
        title: String = "Title",
        year: Int? = nil,
        season: String? = nil,
        isCurrent: Bool = false
    ) -> WatchOrder.Entry {
        WatchOrder.Entry(
            id: id,
            title: title,
            relationType: relationType,
            year: year,
            season: season,
            isCurrent: isCurrent
        )
    }

    @Test("Prequel before the current title before the sequel")
    func mainLineOrder() {
        let current = entry(2, nil, title: "Season 2", year: 2015, isCurrent: true)
        let sorted = WatchOrder.sort(
            relations: [
                entry(3, "SEQUEL", title: "Season 3", year: 2019),
                entry(1, "PREQUEL", title: "Season 1", year: 2013)
            ],
            current: current
        )
        #expect(sorted.map(\.id) == [1, 2, 3])
    }

    /// The runtime case: `FfiRelation` carries no start date, so the
    /// prequel and sequel arrive undated while the open title knows its own
    /// year. Ordering the main line by date alone puts the undated prequel
    /// last, which is the wrong end of the timeline.
    @Test("Main line holds its order when only the current title is dated")
    func mainLineOrderWithoutDates() {
        let current = entry(2, nil, title: "Season 2", year: 2015, isCurrent: true)
        let sorted = WatchOrder.sort(
            relations: [
                entry(3, "SEQUEL", title: "Season 3"),
                entry(1, "PREQUEL", title: "Season 1")
            ],
            current: current
        )
        #expect(sorted.map(\.id) == [1, 2, 3])
    }

    @Test("Same year sorts by season")
    func sameYearBySeason() {
        let current = entry(1, nil, title: "Original", year: 2010, isCurrent: true)
        let sorted = WatchOrder.sort(
            relations: [
                entry(4, "SIDE_STORY", title: "Fall Story", year: 2016, season: "FALL"),
                entry(2, "SIDE_STORY", title: "Winter Story", year: 2016, season: "WINTER"),
                entry(3, "SIDE_STORY", title: "Summer Story", year: 2016, season: "SUMMER")
            ],
            current: current
        )
        #expect(sorted.map(\.id) == [1, 2, 3, 4])
    }

    @Test("Unknown dates sort last within their tier")
    func unknownDatesLast() {
        let current = entry(1, nil, title: "Original", year: 2010, isCurrent: true)
        let sorted = WatchOrder.sort(
            relations: [
                entry(3, "SIDE_STORY", title: "Undated Story"),
                entry(2, "SIDE_STORY", title: "Dated Story", year: 2012)
            ],
            current: current
        )
        #expect(sorted.map(\.id) == [1, 2, 3])
    }

    /// Characters and "other" share the last tier, so their order relative
    /// to each other is only the title tiebreaker — the band boundaries are
    /// what this pins down.
    @Test("Side stories follow the main line, characters and other last")
    func tierOrder() {
        let current = entry(1, nil, title: "Original", year: 2010, isCurrent: true)
        let sorted = WatchOrder.sort(
            relations: [
                entry(5, "OTHER", title: "Other"),
                entry(4, "CHARACTER", title: "Shared Character"),
                entry(3, "SPIN_OFF", title: "Spin-off"),
                entry(2, "SEQUEL", title: "Sequel")
            ],
            current: current
        )
        #expect(sorted.prefix(3).map(\.id) == [1, 2, 3])
        #expect(Set(sorted.suffix(2).map(\.id)) == [4, 5])
    }

    /// An unrecognised relation type must not silently join the main line
    /// and push a real sequel down the page.
    @Test("Unknown relation types fall to the last tier")
    func unknownTypeIsTangent() {
        let current = entry(1, nil, isCurrent: true)
        #expect(WatchOrder.tier(for: entry(9, "SOMETHING_NEW")) == .tangent)
        #expect(WatchOrder.tier(for: current) == .mainLine)
    }

    @Test("Grouping keeps the sorted order and never repeats a group id")
    func groupingIsStable() {
        let current = entry(1, nil, title: "Original", year: 2013, isCurrent: true)
        let sorted = WatchOrder.sort(
            relations: [
                entry(3, "SIDE_STORY", title: "Side", year: 2013),
                entry(2, "SEQUEL", title: "Sequel", year: 2014)
            ],
            current: current
        )
        let groups = WatchOrder.grouped(sorted)
        #expect(groups.map(\.year) == [2013, 2014, 2013])
        #expect(Set(groups.map(\.id)).count == groups.count)
        #expect(groups.flatMap { $0.entries }.map(\.id) == sorted.map(\.id))
    }

    @Test("Undated entries group under one trailing label")
    func undatedGroupLabel() {
        let current = entry(1, nil, title: "Original", isCurrent: true)
        let groups = WatchOrder.grouped(WatchOrder.sort(relations: [], current: current))
        #expect(groups.count == 1)
        #expect(groups[0].label == "Undated")
    }

    @Test("The current title is always present in the result")
    func currentAlwaysIncluded() {
        let current = entry(42, nil, title: "Only", isCurrent: true)
        let sorted = WatchOrder.sort(relations: [], current: current)
        #expect(sorted.count == 1)
        #expect(sorted[0].isCurrent)
    }
}
