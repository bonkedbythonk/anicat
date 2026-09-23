import Testing
@testable import AnicatUI

@Suite("Dub alerts")
struct DubAlertTests {
    @Test("The first look records without announcing")
    func firstLook() {
        #expect(AppModel.dubTransition(previous: nil, result: .dub) == ("out", false))
        #expect(AppModel.dubTransition(previous: nil, result: .noDub) == ("waiting", false))
    }

    @Test("A dub appearing after a look without one is announced, once")
    func arrival() {
        #expect(AppModel.dubTransition(previous: "waiting", result: .dub) == ("out", true))
        #expect(AppModel.dubTransition(previous: "out", result: .dub) == ("out", false))
    }

    @Test("A failed search records nothing")
    func unknown() {
        #expect(AppModel.dubTransition(previous: nil, result: .unknown) == (nil, false))
        #expect(AppModel.dubTransition(previous: "waiting", result: .unknown) == ("waiting", false))
        #expect(AppModel.dubTransition(previous: "out", result: .unknown) == ("out", false))
    }

    @Test("A dub once seen is not taken back by a search that misses it")
    func outStaysOut() {
        #expect(AppModel.dubTransition(previous: "out", result: .noDub) == ("out", false))
    }

    @Test("Pruning drops titles off the list and episodes already passed")
    func prune() {
        let watch = ["1:5": "waiting", "1:4": "out", "2:3": "waiting", "junk": "out"]
        let kept = AppModel.pruneDubWatch(watch, nextEpisodes: [1: 5], limit: 10)
        #expect(kept == ["1:5": "waiting"])
    }

    @Test("Pruning caps the history")
    func cap() {
        let watch = Dictionary(uniqueKeysWithValues: (1...10).map { ("\($0):1", "waiting") })
        let next = Dictionary(uniqueKeysWithValues: (1...10).map { (Int64($0), 1) })
        #expect(AppModel.pruneDubWatch(watch, nextEpisodes: next, limit: 4).count == 4)
    }
}
