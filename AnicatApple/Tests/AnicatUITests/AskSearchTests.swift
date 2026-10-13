import Testing
@testable import AnicatUI

@Suite("Ask search routing")
struct AskSearchTests {
    @Test("requests go to the model, titles stay a title search", arguments: [
        ("something like Frieren but darker", true),
        ("anime like Berserk", true),
        ("i watched More than a married couple but not lovers", true),
        ("recommend me something short", true),
        ("shows with time travel", true),
        ("That Time I Got Reincarnated as a Slime", false),
        ("A Silent Voice", false),
        ("The Eminence in Shadow", false),
        ("Frieren", false),
    ])
    func routing(query: String, expected: Bool) {
        #expect(AskSearch.looksLikeRequest(query) == expected)
    }

    @Test("a fuzzy AniList hit counts only when it shares the typed name's words")
    func matching() {
        #expect(AskSearch.matches("Vinland Saga", "Vinland Saga Season 2"))
        #expect(AskSearch.matches("More than a married couple but not lovers", "More than a Married Couple, but Not Lovers"))
        #expect(!AskSearch.matches("Tenku no Orvar", "Tenkuu Shinpan"))
    }

    @Test("what the viewer rules out is read from their words")
    func ruledOut() {
        let a = AskSearch.ruledOut("good but fewer ecchi, and shorter")
        #expect(a.genres == ["Ecchi"] && a.shortOnly)
        let b = AskSearch.ruledOut("yeah i want more of the romance type")
        #expect(b.genres.isEmpty && !b.shortOnly)
        #expect(AskSearch.ruledOut("no violent horror please").genres == ["Horror"])
    }

    @Test("asking for what is already on the list is told apart from mentioning it", arguments: [
        ("and something ive seen already?", true),
        ("something i've watched before, but sweeter", true),
        ("i want to rewatch a romance", true),
        ("i watched More than a married couple and loved it", false),
        ("yeah i want more of the romance type", false),
    ])
    func seen(text: String, expected: Bool) {
        #expect(AskSearch.wantsSeen(text) == expected)
    }

    @Test("genres are read from the words, with synonyms, minus what is ruled out", arguments: [
        ("what about an ecchi", ["Ecchi"]),
        ("something violent with gore", ["Horror", "Action"]),
        ("a cozy show to unwind", ["Slice of Life"]),
        ("fewer ecchi, and shorter", []),
        ("i want something romantic", ["Romance"]),
        ("hi", []),
    ])
    func genreWords(text: String, expected: [String]) {
        #expect(AskSearch.requestedGenres(text) == expected)
    }

    @Test("a show's own name is not a genre request")
    func namesAreNotGenres() {
        #expect(AskSearch.requestedGenres("like Psycho-Pass please", names: ["Psycho-Pass"]).isEmpty)
    }

    @Test("a title one letter off still matches")
    func oneLetterOff() {
        #expect(AskSearch.matches("Haikyuu", "HAIKYU!!"))
        #expect(!AskSearch.matches("Haikyuu", "Naruto"))
    }

    @Test("greetings and thanks are chat, not requests")
    func smallTalk() {
        #expect(AskSearch.smallTalk("thanks!") != nil)
        #expect(AskSearch.smallTalk("Hi") != nil)
        #expect(AskSearch.smallTalk("hi, something like Frieren") == nil)
        #expect(AskSearch.smallTalk("something lighter") == nil)
    }

    @Test("a show is found in the wording when the model cannot read it", arguments: [
        ("something like Frieren but darker", ["Frieren"]),
        ("i watched More than a married couple but not lovers and loved it, what next?", ["More than a married couple"]),
        ("anime like One Piece and Fairy Tail", ["One Piece"]),
        ("a cozy romance with magic", []),
    ])
    func guessedShows(text: String, expected: [String]) {
        #expect(AskSearch.guessShows(text) == expected)
    }
}
