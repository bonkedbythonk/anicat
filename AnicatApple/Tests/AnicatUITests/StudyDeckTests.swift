import Testing
import Foundation
@testable import AnicatUI

@MainActor
@Suite("Study deck")
struct StudyDeckTests {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("study-deck-\(UUID().uuidString).json")
    }

    private func add(_ deck: StudyDeck, _ word: String, page: Int = 0) {
        deck.lookedUp(word: word, reading: "よみ", meaning: "meaning", sentence: "\(word)です", surface: word, source: "Test", page: page)
    }

    @Test("Good stretches the gap by the ease; again brings it back in a minute")
    func scheduling() {
        let now = Date(timeIntervalSince1970: 0)
        let fresh = StudyCard(id: "a", word: "a", reading: "a", meaning: "", sentence: "", surface: "", source: "", added: now, due: now, interval: 0, ease: 2.5, reviews: 0, lapses: 0)
        let first = StudyDeck.schedule(fresh, .good, now: now)
        #expect(first.interval == 1)
        let second = StudyDeck.schedule(first, .good, now: now)
        #expect(second.interval == 2.5)
        let missed = StudyDeck.schedule(second, .again, now: now)
        #expect(missed.interval == 0)
        #expect(missed.lapses == 1)
        #expect(missed.due == now.addingTimeInterval(60))
        #expect(missed.ease < second.ease)
    }

    @Test("A looked-up word is saved once and survives a reload")
    func savesAndReloads() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let deck = StudyDeck(file: file)
        add(deck, "待つ")
        add(deck, "待つ")
        #expect(deck.cards.count == 1)
        #expect(deck.dueCards.count == 1)
        let reloaded = StudyDeck(file: file)
        #expect(reloaded.cards.count == 1)
    }

    @Test("Know it removes the card and keeps the word from coming back")
    func knowIt() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let deck = StudyDeck(file: file)
        add(deck, "僕")
        deck.markKnown(word: "僕", reading: "よみ")
        add(deck, "僕")
        #expect(deck.cards.isEmpty)
    }

    @Test("The quick check asks about pages left behind, once each")
    func quickCheck() {
        let file = tempFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let deck = StudyDeck(file: file)
        add(deck, "雪", page: 1)
        add(deck, "命", page: 2)
        #expect(deck.takeQuickCheck(before: 1).isEmpty)
        #expect(deck.takeQuickCheck(before: 2).map(\.word) == ["雪"])
        #expect(deck.takeQuickCheck(before: 2).isEmpty)
        #expect(deck.takeQuickCheck(before: 3).map(\.word) == ["命"])
    }
}
