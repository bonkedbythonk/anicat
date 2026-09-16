import Testing
import CoreGraphics
@testable import AnicatUI

@Suite("Shelf content width")
struct ContentWidthTests {
    @Test("A laptop keeps the width it always had")
    func laptopIsUnchanged() {
        // 1512pt window less the 200pt rail. The share lands under the
        // floor here, which is the point: nothing about small screens moves.
        #expect(SumiContentWidth.forAvailable(1312) == 1280)
    }

    @Test("Never wider than the space given")
    func neverOverflows() {
        // The window minimum is 1080pt. A floor applied unconditionally
        // would clip; the old `maxWidth` shrank to fit and so must this.
        #expect(SumiContentWidth.forAvailable(880) == 880)
        #expect(SumiContentWidth.forAvailable(1000) == 1000)
        for w in stride(from: CGFloat(400), through: 4000, by: 37) {
            #expect(SumiContentWidth.forAvailable(w) <= w)
        }
    }

    @Test("An ultrawide actually uses its width")
    func ultrawideGrows() {
        // 3440pt display less the rail. The whole reason for the change:
        // this was a flat 1280, leaving ~400pt empty on each side.
        let available: CGFloat = 3240
        let width = SumiContentWidth.forAvailable(available)
        #expect(width > 1280)
        #expect(width == SumiContentWidth.ceiling)
    }

    @Test("Growth is bounded, so a shelf stays scannable")
    func ceilingHolds() {
        #expect(SumiContentWidth.forAvailable(10_000) == SumiContentWidth.ceiling)
    }

    @Test("Width never decreases as the window grows")
    func monotonic() {
        var last: CGFloat = 0
        for w in stride(from: CGFloat(300), through: 5000, by: 23) {
            let width = SumiContentWidth.forAvailable(w)
            #expect(width >= last)
            last = width
        }
    }
}
