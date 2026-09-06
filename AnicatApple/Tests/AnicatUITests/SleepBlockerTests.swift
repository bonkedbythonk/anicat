import Testing
import Foundation
@testable import AnicatUI

@Suite("SleepBlocker")
struct SleepBlockerTests {
    /// Stands in for IOKit: hands out increasing ids and records every
    /// release, so a leak or a double release shows up as a count.
    private final class FakeIOKit: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var created: [(id: UInt32, reason: String)] = []
        private(set) var released: [UInt32] = []
        var failNext = false

        func create(_ reason: String) -> UInt32? {
            lock.lock(); defer { lock.unlock() }
            if failNext { failNext = false; return nil }
            let id = UInt32(created.count + 1)
            created.append((id, reason))
            return id
        }

        func release(_ id: UInt32) {
            lock.lock(); defer { lock.unlock() }
            released.append(id)
        }

        var outstanding: Set<UInt32> {
            lock.lock(); defer { lock.unlock() }
            return Set(created.map(\.id)).subtracting(released)
        }
    }

    private func make() -> (SleepBlocker, FakeIOKit) {
        let io = FakeIOKit()
        let blocker = SleepBlocker(create: { io.create($0) }, release: { io.release($0) })
        return (blocker, io)
    }

    @Test("a repeated hold with the same reason creates one assertion")
    func holdIsIdempotent() {
        let (blocker, io) = make()
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        #expect(io.created.count == 1)
        #expect(io.created.first?.reason == "Anicat is playing Frieren, episode 3")
        #expect(blocker.isHolding)
        #expect(io.outstanding == [1])
    }

    @Test("a repeated release frees the assertion once and never hands back a freed id")
    func releaseIsIdempotent() {
        let (blocker, io) = make()
        blocker.release()
        #expect(io.released.isEmpty)
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        blocker.release()
        blocker.release()
        blocker.release()
        #expect(io.released == [1])
        #expect(!blocker.isHolding)
        #expect(io.outstanding.isEmpty)
    }

    @Test("a new episode under an unbroken hold swaps the assertion instead of stacking one")
    func reasonChangeSwaps() {
        let (blocker, io) = make()
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        blocker.hold(reason: "Anicat is playing Frieren, episode 4")
        #expect(io.created.count == 2)
        #expect(io.released == [1])
        #expect(io.outstanding == [2])
        #expect(blocker.currentReason == "Anicat is playing Frieren, episode 4")
    }

    @Test("a failed create leaves nothing held and a later release has nothing to free")
    func failedCreate() {
        let (blocker, io) = make()
        io.failNext = true
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        #expect(!blocker.isHolding)
        blocker.release()
        #expect(io.released.isEmpty)
        // The next play tries again rather than staying wedged.
        blocker.hold(reason: "Anicat is playing Frieren, episode 3")
        #expect(blocker.isHolding)
    }

    @Test("pause, play, pause leaves nothing outstanding")
    func pauseEdges() {
        let (blocker, io) = make()
        blocker.hold(reason: "r")
        blocker.release()
        blocker.hold(reason: "r")
        blocker.release()
        blocker.release()
        #expect(io.created.count == 2)
        #expect(io.released == [1, 2])
        #expect(io.outstanding.isEmpty)
    }
}
