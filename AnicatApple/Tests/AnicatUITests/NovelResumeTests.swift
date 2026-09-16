import Testing
import Foundation
@testable import AnicatUI

@Suite("Novel resume")
struct NovelResumeTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "anicat.tests.novel.\(UUID().uuidString)")!
    }

    @Test("a resumed novel remembers which reader it came from")
    func lastNovelCarriesItsSource() {
        // Without this the resume button handed an lnori book URL to
        // `novelInfo`, which refuses anything that is not a syosetu.com URL:
        // "Continue chapter 4 of Volume 1" opened an error, network or not.
        let store = defaults()
        NovelPreferences.setLastNovel(
            url: "https://lnori.com/book/12020/x#page05",
            title: "Volume 1",
            chapter: 3,
            source: AppModel.NovelSource.lnori.rawValue,
            catalogId: 85470,
            defaults: store
        )

        let last = NovelPreferences.lastNovel(defaults: store)
        #expect(last?.source == "lnori")
        #expect(last?.catalogId == 85470)
        #expect(last?.chapter == 3)
    }

    @Test("a row written before the source was recorded reads as Syosetu")
    func olderRowsDefaultToSyosetu() {
        // Syosetu was the only source when those rows were written, so the
        // default has to be the one that was true then, not the new one.
        let store = defaults()
        store.set("https://ncode.syosetu.com/n2267be/", forKey: NovelPreferences.lastNovelURLKey)
        store.set("Mushoku Tensei", forKey: NovelPreferences.lastNovelTitleKey)
        store.set(7, forKey: NovelPreferences.lastNovelChapterKey)

        let last = NovelPreferences.lastNovel(defaults: store)
        #expect(last?.source == "syosetu")
        #expect(last?.catalogId == nil)
    }

    @Test("a pasted link keeps no catalog id, even after one was stored")
    func aPastedLinkClearsTheCatalogId() {
        // The two entry points share one saved row. A Syosetu link written
        // after an lnori volume must not inherit that volume's AniList id, or
        // the offline lookup would go hunting under the wrong title.
        let store = defaults()
        NovelPreferences.setLastNovel(
            url: "https://lnori.com/book/12020/x",
            title: "Volume 1",
            chapter: 1,
            source: "lnori",
            catalogId: 85470,
            defaults: store
        )
        NovelPreferences.setLastNovel(
            url: "https://ncode.syosetu.com/n2267be/",
            title: "Something else",
            chapter: 0,
            source: "syosetu",
            catalogId: nil,
            defaults: store
        )

        #expect(NovelPreferences.lastNovel(defaults: store)?.catalogId == nil)
    }
}
