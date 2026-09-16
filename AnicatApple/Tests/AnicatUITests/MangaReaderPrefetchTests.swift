import Testing
import Foundation
@testable import AnicatUI

@Suite("Manga reader prefetch window and page fit")
struct MangaReaderPrefetchTests {
    typealias Reader = MangaReaderView

    @Test("Single page warms the next two turns first, then one back")
    func singlePageWindow() {
        let indices = Reader.prefetchIndices(current: 10, pageCount: 40, mode: .single)
        #expect(indices == [11, 12, 9])
    }

    @Test("Webtoon warms the two pages beyond the last visible one, then one back")
    func webtoonWindow() {
        let indices = Reader.prefetchIndices(current: 10, pageCount: 40, mode: .webtoon)
        #expect(indices == [11, 12, 9])
    }

    @Test("Double page warms the next spread and the previous spread, never the shown pair")
    func doublePageWindow() {
        let indices = Reader.prefetchIndices(current: 10, pageCount: 40, mode: .double)
        #expect(indices == [12, 13, 8, 9])
        #expect(!indices.contains(10))
        #expect(!indices.contains(11))
    }

    @Test("The window is clipped at both ends of the chapter")
    func windowClipping() {
        #expect(Reader.prefetchIndices(current: 0, pageCount: 40, mode: .single) == [1, 2])
        #expect(Reader.prefetchIndices(current: 39, pageCount: 40, mode: .single) == [38])
        #expect(Reader.prefetchIndices(current: 0, pageCount: 40, mode: .double) == [2, 3])
        #expect(Reader.prefetchIndices(current: 38, pageCount: 40, mode: .double) == [36, 37])
        #expect(Reader.prefetchIndices(current: 0, pageCount: 1, mode: .single).isEmpty)
        #expect(Reader.prefetchIndices(current: 0, pageCount: 0, mode: .webtoon).isEmpty)
    }

    @Test("Single-page fit is the whole container at the backing scale, rounded up to 64px")
    func singlePageFit() {
        let fit = Reader.pageFit(mode: .single, container: CGSize(width: 1512, height: 982), displayScale: 2)
        // 3024px rounds up to 3072; 1964px rounds up to 1984.
        #expect(fit == .box(width: 3072, height: 1984))
    }

    @Test("Double-page fit halves the width minus the spread gap")
    func doublePageFit() {
        let fit = Reader.pageFit(mode: .double, container: CGSize(width: 1512, height: 982), displayScale: 2)
        // (1512 - 4) / 2 = 754pt = 1508px, rounded up to 1536.
        #expect(fit == .box(width: 1536, height: 1984))
    }

    @Test("Webtoon fit is bounded by the column width only, so a tall strip keeps its width")
    func webtoonFit() {
        let fit = Reader.pageFit(mode: .webtoon, container: CGSize(width: 1512, height: 982), displayScale: 2)
        #expect(fit == .box(width: 1600, height: nil))

        // A narrower window than the column cap uses the window.
        let narrow = Reader.pageFit(mode: .webtoon, container: CGSize(width: 600, height: 982), displayScale: 2)
        #expect(narrow == .box(width: 1216, height: nil))
    }

    @Test("Pinch zoom grows the fit so a zoomed page is not an upscaled decode")
    func zoomGrowsFit() {
        let plain = Reader.pageFit(mode: .single, container: CGSize(width: 1000, height: 800), displayScale: 2)
        let zoomed = Reader.pageFit(mode: .single, container: CGSize(width: 1000, height: 800), displayScale: 2, zoom: 2)
        // 2000px rounds up to 2048, 4000px to 4032; 1600 and 3200 are whole steps.
        #expect(plain == .box(width: 2048, height: 1600))
        #expect(zoomed == .box(width: 4032, height: 3200))
    }

    @Test("A webtoon strip fitted by width keeps the full column width")
    func tallStripLargestSide() {
        // 800x6000 strip into a 1600px-wide column: the width would be
        // upscaled, so the cap stays at the native largest side (6000),
        // not at 1600, which would have drawn the strip 213px wide.
        let cap = ImageDecodeCache.thumbnailMaxPixelSize(
            source: CGSize(width: 800, height: 6000), boxWidth: 1600, boxHeight: nil)
        #expect(cap == 6000)

        // 1200x9000 into the same column: half scale, largest side 4500.
        let halved = ImageDecodeCache.thumbnailMaxPixelSize(
            source: CGSize(width: 1200, height: 9000), boxWidth: 600, boxHeight: nil)
        #expect(halved == 4500)
    }

    @Test("A portrait page in a landscape box is height-limited")
    func portraitPageInLandscapeBox() {
        // 1400x4000 page into 3072x2000: the width would allow 2.19x, the
        // height limits it to 0.5x, cap 2000.
        let cap = ImageDecodeCache.thumbnailMaxPixelSize(
            source: CGSize(width: 1400, height: 4000), boxWidth: 3072, boxHeight: 2000)
        #expect(cap == 2000)

        // A source smaller than the box is never asked to grow.
        let small = ImageDecodeCache.thumbnailMaxPixelSize(
            source: CGSize(width: 700, height: 1000), boxWidth: 3072, boxHeight: 2000)
        #expect(small == 1000)
    }

    @Test("Only the paged modes take tap zones and arrow keys; webtoon leaves both to the scroll view")
    func inputModePerReadingMode() {
        #expect(Reader.inputMode(for: .single) == .pageTurn)
        #expect(Reader.inputMode(for: .double) == .pageTurn)
        #expect(Reader.inputMode(for: .webtoon) == .scroll)
        // Every mode is covered, so adding one cannot silently fall into the
        // scroll branch and lose its page turns.
        #expect(Reader.ReadingMode.allCases.filter { Reader.inputMode(for: $0) == .scroll } == [.webtoon])
    }

    @Test("Cache keys tell fits apart and spell the unconstrained axis without infinity")
    func cacheKeys() {
        #expect(ImageFit.maxPixelSize(400).cacheKeySuffix == "#400")
        #expect(ImageFit.box(width: 1600, height: nil).cacheKeySuffix == "#box:1600xany")
        #expect(ImageFit.box(width: 1600, height: 1984).cacheKeySuffix == "#box:1600x1984")
        #expect(ImageFit.box(width: 1600, height: nil).cacheKeySuffix != ImageFit.maxPixelSize(1600).cacheKeySuffix)
    }
}
