import Testing
@testable import AnicatUI

@Suite("Release list sorting")
struct ReleaseSortTests {
    typealias Item = MediaDetailView.ReleaseCandidateItem

    let items: [Item] = [
        Item(name: "subsplease", seeders: 50, isDub: false, seedersKnown: false, sizeBytes: nil),
        Item(name: "small", seeders: 12, isDub: false, sizeBytes: 350_000_000),
        Item(name: "big", seeders: 80, isDub: true, sizeBytes: 1_400_000_000),
        Item(name: "tie", seeders: 12, isDub: false, sizeBytes: nil),
    ]

    @Test("Best match keeps the engine's order")
    func best() {
        #expect(ReleaseSort.best.apply(items).map(\.name) == ["subsplease", "small", "big", "tie"])
    }

    @Test("Seeders: most first, ties in engine order, a stand-in count last")
    func seeders() {
        #expect(ReleaseSort.seeders.apply(items).map(\.name) == ["big", "small", "tie", "subsplease"])
    }

    @Test("Size: smallest first, unknown sizes after every known one")
    func size() {
        #expect(ReleaseSort.size.apply(items).map(\.name) == ["small", "big", "subsplease", "tie"])
    }

    @Test("Health bands, and a stand-in count reads as unknown")
    func health() {
        #expect(items[0].health == .unknown)
        #expect(items[0].seedersText == "seeders unknown")
        #expect(items[1].health == .fair)
        #expect(items[2].health == .good)
        #expect(Item(name: "x", seeders: 1, isDub: false).seedersText == "1 seeder")
        #expect(Item(name: "x", seeders: 3, isDub: false).health == .weak)
        #expect(items[3].sizeText == nil)
        #expect(items[1].sizeText != nil)
    }
}
