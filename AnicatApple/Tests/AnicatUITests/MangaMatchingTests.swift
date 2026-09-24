import Testing
@testable import AnicatCoreKit

/// Names from the 90-title audit (2026-09-24): the ones read wrongly before,
/// and the ones read rightly under another name that must stay so.
@Suite("Manga source matching")
struct MangaMatchingTests {
    func result(_ title: String) -> MangaSummary {
        MangaSummary(id: "https://mangakatana.com/manga/\(title)", title: title, coverImage: "", matchesAnilist: false)
    }

    func chapters(_ numbers: [Double]) -> [MangaChapter] {
        numbers.map { MangaChapter(number: String($0), title: "", id: "\($0)", pages: 1, scanlationGroup: nil) }
    }

    @Test("An unconfirmed MangaDex result needs one of the title's names")
    func unconfirmed() {
        #expect(!MangaMatching.isSameTitle("VRMMO Chronicles of a Solo Cleric", as: ["Berserk"]))
        #expect(MangaMatching.isSameTitle("Vagabond (Hong Kong Colored Version)", as: ["Vagabond"]))
        #expect(MangaMatching.isSameTitle("ONE PIECE", as: ["One Piece"]))
    }

    @Test("MangaKatana: the exact name first, spin-offs never")
    func katanaSpinOffs() {
        let mha = ["My Hero Academia Team Up Mission", "Deku & Bakugo: Rising", "Boku no Hero Academia Smash!!",
                   "Vigilante: Boku no Hero Academia Illegals", "Boku no Hero Academia"].map(result)
        let order = MangaMatching.katanaOrder(mha, titles: ["My Hero Academia", "Boku no Hero Academia"])
        #expect(order.first?.title == "Boku no Hero Academia")
        #expect(!order.contains { $0.title == "My Hero Academia Team Up Mission" })
        #expect(!order.contains { $0.title == "Boku no Hero Academia Smash!!" })

        let tr = ["Tokyo Revengers: Letter from Keisuke Baji", "Tokyo Manji Revengers"].map(result)
        #expect(MangaMatching.katanaOrder(tr, titles: ["Tokyo Revengers", "Toukyou Revengers"]).map(\.title)
            == ["Tokyo Manji Revengers"])
        #expect(MangaMatching.katanaOrder([result("Kaiju No. 8: B-Side")], titles: ["Kaiju No.8", "Kaijuu 8-gou"]).isEmpty)
    }

    @Test("MangaKatana: names the site knows and AniList does not still pass", arguments: [
        ("Oyasumi Punpun", ["Goodnight Punpun", "Oyasumi Punpun"]),
        ("Onepunch-Man (ONE)", ["One-Punch Man", "Onepunch-Man"]),
        ("Solo Max-Level Newbie", ["I’m the Max-Level Newbie", "Na Honjaman Manrep Newbie"]),
        ("Ranker Who Lives A Second Time", ["Second Life Ranker", "Dubeon Saneun Ranker"]),
        ("Return of the Mount Hua Sect", ["Return of the Blossoming Blade", "Hwasan Gwihwan"]),
        ("Tokyo Manji Revengers", ["Tokyo Revengers", "Toukyou Revengers"]),
    ])
    func keptNames(site: String, titles: [String]) {
        #expect(MangaMatching.katanaOrder([result(site)], titles: titles).count == 1)
    }

    @Test("A fragment is partial: it starts late or misses most of its numbering")
    func partial() {
        #expect(MangaMatching.isPartial(chapters(Array(stride(from: 140.0, through: 205, by: 1)))))
        #expect(MangaMatching.isPartial(chapters([1, 2, 3, 300, 309])))
        #expect(!MangaMatching.isPartial(chapters(Array(stride(from: 1.0, through: 232, by: 1)))))
        #expect(MangaMatching.isPartial([]))
    }

    @Test("A stand-in for a fragment has to reach as far as the fragment does")
    func reachesRun() {
        let fragment = MangaSource(match: result("The Swordmaster's Son"), chapters: chapters([156, 157]))
        #expect(!MangaMatching.reachesRun(chapters([0, 1, 5.5]), of: fragment))
        let apotheosis = MangaSource(match: result("Bailian Chengshen"), chapters: chapters([1, 1301]))
        #expect(MangaMatching.reachesRun(chapters([1.1, 1293]), of: apotheosis))
        #expect(MangaMatching.reachesRun(chapters([1, 2]), of: nil))
    }

    @Test("A finished title's count rules out a much longer series of the same name")
    func tooLong() {
        #expect(MangaMatching.isTooLong(chapters(Array(stride(from: 1.0, through: 139, by: 1))), finished: 94))
        #expect(!MangaMatching.isTooLong(chapters(Array(stride(from: 1.0, through: 200, by: 1))), finished: 201))
        #expect(!MangaMatching.isTooLong(chapters([1, 181.9]), finished: 181))
        #expect(!MangaMatching.isTooLong(chapters([1, 900]), finished: nil))
    }
}
