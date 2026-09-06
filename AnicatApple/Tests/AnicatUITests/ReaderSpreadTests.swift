import Testing
import Foundation
@testable import AnicatUI

@Suite("Manga spread pairing")
struct MangaReaderSpreadTests {
    typealias Reader = MangaReaderView

    @Test("Plain pages pair from the first one")
    func evenPairing() {
        #expect(Reader.spreads(pageCount: 6, wideIndices: [], offsetCover: false) == [[0, 1], [2, 3], [4, 5]])
    }

    @Test("An odd page count leaves the last page alone")
    func oddPageCount() {
        #expect(Reader.spreads(pageCount: 5, wideIndices: [], offsetCover: false) == [[0, 1], [2, 3], [4]])
        #expect(Reader.spreads(pageCount: 1, wideIndices: [], offsetCover: false) == [[0]])
        #expect(Reader.spreads(pageCount: 0, wideIndices: [], offsetCover: false).isEmpty)
    }

    @Test("A wide page stands alone, and so does the page before it")
    func widePageAlone() {
        // 3 is wide, so 2 cannot be paired forward and falls alone too; the
        // pages after 3 resume pairing from the new offset.
        #expect(Reader.spreads(pageCount: 7, wideIndices: [3], offsetCover: false) == [[0, 1], [2], [3], [4, 5], [6]])
        // A wide first page is alone without needing the cover offset.
        #expect(Reader.spreads(pageCount: 4, wideIndices: [0], offsetCover: false) == [[0], [1, 2], [3]])
        // Two wide pages in a row are two spreads, not one pair.
        #expect(Reader.spreads(pageCount: 4, wideIndices: [1, 2], offsetCover: false) == [[0], [1], [2], [3]])
    }

    @Test("The cover offset shifts every later pair by one")
    func coverOffset() {
        #expect(Reader.spreads(pageCount: 6, wideIndices: [], offsetCover: true) == [[0], [1, 2], [3, 4], [5]])
        #expect(Reader.spreads(pageCount: 5, wideIndices: [], offsetCover: true) == [[0], [1, 2], [3, 4]])
        // The offset and a wide page compose: the offset moves the pairing,
        // the wide page breaks it again where it sits.
        #expect(Reader.spreads(pageCount: 6, wideIndices: [4], offsetCover: true) == [[0], [1, 2], [3], [4], [5]])
    }

    @Test("Every page appears exactly once, in order")
    func partitionIsComplete() {
        for count in 0...12 {
            for wide in [Set<Int>(), [0], [1], [count / 2], [1, 4]] as [Set<Int>] {
                for offset in [false, true] {
                    let flattened = Reader.spreads(pageCount: count, wideIndices: wide, offsetCover: offset)
                        .flatMap { $0 }
                    #expect(flattened == Array(0..<count))
                }
            }
        }
    }

    @Test("A page's spread is found by membership, not by arithmetic")
    func spreadLookup() {
        let spreads = Reader.spreads(pageCount: 7, wideIndices: [3], offsetCover: false)
        #expect(Reader.spreadIndex(containing: 0, spreads: spreads) == 0)
        #expect(Reader.spreadIndex(containing: 1, spreads: spreads) == 0)
        #expect(Reader.spreadIndex(containing: 2, spreads: spreads) == 1)
        #expect(Reader.spreadIndex(containing: 3, spreads: spreads) == 2)
        #expect(Reader.spreadIndex(containing: 5, spreads: spreads) == 3)
    }

    @Test("The prefetch window follows the spreads a wide page reshuffles")
    func prefetchFollowsSpreads() {
        // Page 11 being wide leaves 10 unpaired, so the spread after [8, 9] is
        // [10] alone. Arithmetic on the page number would have warmed 10 and
        // 11 — a pair that is never drawn together.
        let indices = Reader.prefetchIndices(
            current: 9, pageCount: 20, mode: .double, wideIndices: [11], offsetCover: false)
        #expect(indices == [10, 6, 7])

        // The cover offset shifts the whole window with it.
        let offset = Reader.prefetchIndices(
            current: 3, pageCount: 20, mode: .double, wideIndices: [], offsetCover: true)
        #expect(offset == [5, 6, 1, 2])
    }
}

@Suite("Reader preferences and novel positions")
struct ReaderPreferencesTests {
    /// A named suite per test, emptied first: `UserDefaults.standard` is the
    /// app's own, and a test that wrote to it would change what the reader
    /// opens on next launch. Named rather than UUID-suffixed so a run leaves
    /// one file per test behind instead of one per run.
    private func defaults(_ name: String) -> UserDefaults {
        let suiteName = "anicat.tests.reader.\(name)"
        let store = UserDefaults(suiteName: suiteName)!
        store.removePersistentDomain(forName: suiteName)
        return store
    }

    @Test("A per-title setting wins over the global one, which wins over the default")
    func perTitleFallback() {
        let store = defaults("mode")
        #expect(ReaderPreferences.mode(catalogId: 42, defaults: store) == .webtoon)

        ReaderPreferences.setMode(.double, catalogId: 42, defaults: store)
        #expect(ReaderPreferences.mode(catalogId: 42, defaults: store) == .double)
        // Writing a title also moves the global default, so the next title
        // opened starts from what was last chosen.
        #expect(ReaderPreferences.mode(catalogId: 99, defaults: store) == .double)

        ReaderPreferences.setMode(.single, catalogId: 99, defaults: store)
        #expect(ReaderPreferences.mode(catalogId: 42, defaults: store) == .double)
        #expect(ReaderPreferences.mode(catalogId: 99, defaults: store) == .single)
    }

    @Test("A title with no AniList id shares the global keys instead of resetting")
    func nilCatalogIdUsesGlobal() {
        let store = defaults("nilid")
        ReaderPreferences.setRightToLeft(false, catalogId: nil, defaults: store)
        #expect(ReaderPreferences.isRightToLeft(catalogId: nil, defaults: store) == false)
        #expect(ReaderPreferences.isRightToLeft(catalogId: 7, defaults: store) == false)
    }

    @Test("A false stored flag is told apart from an absent one")
    func falseIsNotAbsent() {
        let store = defaults("rtl")
        // The default is true; a stored false has to survive the read.
        #expect(ReaderPreferences.isRightToLeft(catalogId: 1, defaults: store) == true)
        ReaderPreferences.setRightToLeft(false, catalogId: 1, defaults: store)
        #expect(ReaderPreferences.isRightToLeft(catalogId: 1, defaults: store) == false)
    }

    @Test("The synced-chapter mark only ever moves forward")
    func syncedChapterMonotonic() {
        let store = defaults("synced")
        #expect(ReaderPreferences.syncedChapter(catalogId: 5, defaults: store) == 0)
        ReaderPreferences.setSyncedChapter(12, catalogId: 5, defaults: store)
        ReaderPreferences.setSyncedChapter(4, catalogId: 5, defaults: store)
        #expect(ReaderPreferences.syncedChapter(catalogId: 5, defaults: store) == 12)
    }

    @Test("A split chapter label floors to the whole chapter behind it")
    func chapterProgressFromLabel() {
        #expect(ReaderPreferences.chapterProgress(from: "12") == 12)
        #expect(ReaderPreferences.chapterProgress(from: " 12 ") == 12)
        #expect(ReaderPreferences.chapterProgress(from: "12.5") == 12)
        #expect(ReaderPreferences.chapterProgress(from: "104.1") == 104)
        // Below chapter one there is no progress to report, and a provider
        // that labels a oneshot "Oneshot" is not a number at all.
        #expect(ReaderPreferences.chapterProgress(from: "0.5") == nil)
        #expect(ReaderPreferences.chapterProgress(from: "") == nil)
        #expect(ReaderPreferences.chapterProgress(from: "Oneshot") == nil)
    }

    @Test("The ncode is the same whether the novel or a chapter link was pasted")
    func ncodeExtraction() {
        #expect(NovelPreferences.ncode(from: "https://ncode.syosetu.com/n2267be/") == "n2267be")
        #expect(NovelPreferences.ncode(from: "https://ncode.syosetu.com/n2267be/12/") == "n2267be")
        #expect(NovelPreferences.ncode(from: "https://ncode.syosetu.com/N2267BE") == "n2267be")
        // A path segment that merely starts with n is not an ncode.
        #expect(NovelPreferences.ncode(from: "https://ncode.syosetu.com/novelview/infotop/ncode/") == nil)
        #expect(NovelPreferences.ncode(from: "https://example.com/some/novel") == nil)
    }

    @Test("A position key is per novel and per chapter, and a link with no ncode still gets one")
    func positionKeys() {
        #expect(NovelPreferences.positionKey(sourceURL: "https://ncode.syosetu.com/n2267be/", chapter: 3)
                == "anicat_novel_pos_n2267be_3")
        // The novel URL and one of its chapter URLs must key the same book, or
        // the two ways of opening it keep separate positions.
        #expect(NovelPreferences.positionKey(sourceURL: "https://ncode.syosetu.com/n2267be/12/", chapter: 3)
                == NovelPreferences.positionKey(sourceURL: "https://ncode.syosetu.com/n2267be/", chapter: 3))
        #expect(NovelPreferences.positionKey(sourceURL: "https://ncode.syosetu.com/n2267be/", chapter: 3)
                != NovelPreferences.positionKey(sourceURL: "https://ncode.syosetu.com/n2267be/", chapter: 4))

        let fallback = NovelPreferences.positionKey(sourceURL: "https://mirror.example/read?id=9", chapter: 2)
        #expect(fallback.hasPrefix("anicat_novel_pos_"))
        #expect(fallback.hasSuffix("_2"))
        #expect(!fallback.contains("/"))
    }

    @Test("Typography reads back what was written, clamped to its range")
    func typographyRoundTrip() {
        let store = defaults("novel")
        #expect(NovelPreferences.typography(defaults: store) == NovelTypography())

        var settings = NovelTypography()
        settings.fontSize = 21
        settings.family = .geist
        settings.theme = .sepia
        NovelPreferences.setTypography(settings, defaults: store)
        #expect(NovelPreferences.typography(defaults: store) == settings)

        // A key written by an older build outside the range must not be able
        // to render the reader unusable.
        store.set(400.0, forKey: NovelPreferences.fontSizeKey)
        #expect(NovelPreferences.typography(defaults: store).fontSize == NovelTypography.fontSizeRange.upperBound)
    }
}
