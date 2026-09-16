import Testing
import Foundation
@testable import AnicatUI

@Suite("KeyboardDimSchedule")
struct KeyboardDimScheduleTests {
    @Test("an evening window that does not cross midnight covers only its own hours")
    func sameDayWindow() {
        // 13:00 to 17:00: half-open, so 13 is in and 17 is out.
        #expect(!KeyboardDimSchedule.isNight(hour: 12, from: 13, until: 17))
        #expect(KeyboardDimSchedule.isNight(hour: 13, from: 13, until: 17))
        #expect(KeyboardDimSchedule.isNight(hour: 16, from: 13, until: 17))
        #expect(!KeyboardDimSchedule.isNight(hour: 17, from: 13, until: 17))
        #expect(!KeyboardDimSchedule.isNight(hour: 23, from: 13, until: 17))
    }

    @Test("the default 20:00-07:00 window wraps across midnight")
    func wrapsMidnight() {
        let from = KeyboardDimSchedule.defaultFromHour
        let until = KeyboardDimSchedule.defaultUntilHour
        #expect(!KeyboardDimSchedule.isNight(hour: 19, from: from, until: until))
        #expect(KeyboardDimSchedule.isNight(hour: 20, from: from, until: until))
        #expect(KeyboardDimSchedule.isNight(hour: 23, from: from, until: until))
        // The hours past midnight are the half a naive `from <= h && h < until`
        // gets wrong: it is false for every hour of the night.
        #expect(KeyboardDimSchedule.isNight(hour: 0, from: from, until: until))
        #expect(KeyboardDimSchedule.isNight(hour: 6, from: from, until: until))
        #expect(!KeyboardDimSchedule.isNight(hour: 7, from: from, until: until))
        #expect(!KeyboardDimSchedule.isNight(hour: 13, from: from, until: until))
    }

    @Test("from == until is an empty window, not a whole day")
    func emptyWindow() {
        for hour in 0...23 {
            #expect(!KeyboardDimSchedule.isNight(hour: hour, from: 20, until: 20))
            #expect(!KeyboardDimSchedule.isNight(hour: hour, from: 0, until: 0))
        }
    }

    @Test("a one-hour window covers exactly one hour at each end of the clock")
    func singleHourWindow() {
        #expect(KeyboardDimSchedule.isNight(hour: 23, from: 23, until: 0))
        #expect(!KeyboardDimSchedule.isNight(hour: 0, from: 23, until: 0))
        #expect(KeyboardDimSchedule.isNight(hour: 0, from: 0, until: 1))
        #expect(!KeyboardDimSchedule.isNight(hour: 1, from: 0, until: 1))
    }

    // MARK: - shouldDim over UserDefaults

    private func defaults() -> UserDefaults {
        let suite = UserDefaults(suiteName: "KeyboardDimScheduleTests-\(UUID().uuidString)")!
        return suite
    }

    private func date(hour: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 7
        components.hour = hour
        return Calendar.current.date(from: components)!
    }

    @Test("the feature is off until the toggle is on, whatever the hour")
    func offByDefault() {
        let store = defaults()
        #expect(!KeyboardDimSchedule.shouldDim(now: date(hour: 22), defaults: store))
        store.set(true, forKey: KeyboardDimSchedule.enabledKey)
        #expect(KeyboardDimSchedule.shouldDim(now: date(hour: 22), defaults: store))
    }

    @Test("with the hour keys never written, the default 20:00-07:00 window applies")
    func unsetHoursFallBackToTheDefaultWindow() {
        // Regression: `integer(forKey:)` returns 0 for an unset key, so
        // reading the pair that way gave the empty window [0, 0) and the
        // feature was a no-op with the toggle visibly on.
        let store = defaults()
        store.set(true, forKey: KeyboardDimSchedule.enabledKey)
        #expect(store.object(forKey: KeyboardDimSchedule.fromHourKey) == nil)
        #expect(KeyboardDimSchedule.shouldDim(now: date(hour: 22), defaults: store))
        #expect(!KeyboardDimSchedule.shouldDim(now: date(hour: 14), defaults: store))
    }

    @Test("Always mode ignores the window entirely")
    func alwaysMode() {
        let store = defaults()
        store.set(true, forKey: KeyboardDimSchedule.enabledKey)
        store.set(KeyboardDimSchedule.alwaysMode, forKey: KeyboardDimSchedule.modeKey)
        store.set(20, forKey: KeyboardDimSchedule.fromHourKey)
        store.set(21, forKey: KeyboardDimSchedule.untilHourKey)
        #expect(KeyboardDimSchedule.shouldDim(now: date(hour: 9), defaults: store))
    }

    @Test("Night mode reads the stored hours, including a stored zero")
    func nightModeReadsStoredHours() {
        let store = defaults()
        store.set(true, forKey: KeyboardDimSchedule.enabledKey)
        store.set(KeyboardDimSchedule.nightMode, forKey: KeyboardDimSchedule.modeKey)
        store.set(0, forKey: KeyboardDimSchedule.fromHourKey)
        store.set(6, forKey: KeyboardDimSchedule.untilHourKey)
        #expect(KeyboardDimSchedule.shouldDim(now: date(hour: 3), defaults: store))
        #expect(!KeyboardDimSchedule.shouldDim(now: date(hour: 22), defaults: store))
    }
}
