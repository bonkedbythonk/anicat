import Foundation
import Observation

/// One word saved from a bubble, with the sentence it was met in.
struct StudyCard: Codable, Identifiable, Equatable {
    /// Dictionary form and reading, so 待って and 待ってる are one card.
    let id: String
    let word: String
    let reading: String
    let meaning: String
    /// The bubble the word was looked up in, and the word as written there.
    let sentence: String
    let surface: String
    let source: String
    let added: Date
    var due: Date
    /// Days until the next review; zero while the word is still being learnt.
    var interval: Double
    var ease: Double
    var reviews: Int
    var lapses: Int

    static func key(word: String, reading: String) -> String { "\(word)|\(reading)" }
}

enum StudyGrade: CaseIterable {
    case again, hard, good, easy

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}

/// Saved words and when each comes back. Anki's original scheduler (SM-2):
/// a miss brings a word back in minutes, each right answer stretches the gap
/// by the card's ease, which drops when a word is hard and rises when easy.
@MainActor
@Observable
final class StudyDeck {
    static let shared = StudyDeck(file: StudyDeck.defaultFile)

    private(set) var cards: [String: StudyCard] = [:]
    /// Words marked "Know it", never saved again when looked up.
    private(set) var known: Set<String> = []
    /// Words looked up in the open chapter, by page, for the quick check
    /// when the reader moves past that page.
    private(set) var lookedUp: [(page: Int, id: String)] = []
    private var checked: Set<String> = []
    private let file: URL

    nonisolated static var defaultFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Anicat/study-deck.json")
    }

    init(file: URL) {
        self.file = file
        if let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            cards = Dictionary(uniqueKeysWithValues: saved.cards.map { ($0.id, $0) })
            known = Set(saved.known)
        }
    }

    var dueCards: [StudyCard] {
        let now = Date()
        return cards.values.filter { $0.due <= now }.sorted { $0.due < $1.due }
    }

    /// Saves a word the reader clicked. Clicking means not knowing it, so
    /// there is no separate "save" step to forget.
    func lookedUp(word: String, reading: String, meaning: String, sentence: String, surface: String, source: String, page: Int) {
        let id = StudyCard.key(word: word, reading: reading)
        guard !known.contains(id) else { return }
        if cards[id] == nil {
            cards[id] = StudyCard(
                id: id, word: word, reading: reading, meaning: meaning,
                sentence: sentence, surface: surface, source: source,
                added: Date(), due: Date(), interval: 0, ease: 2.5, reviews: 0, lapses: 0
            )
            save()
        }
        if !lookedUp.contains(where: { $0.id == id }) {
            lookedUp.append((page, id))
        }
    }

    func isSaved(_ word: String, reading: String) -> Bool {
        cards[StudyCard.key(word: word, reading: reading)] != nil
    }

    func markKnown(word: String, reading: String) {
        let id = StudyCard.key(word: word, reading: reading)
        cards[id] = nil
        known.insert(id)
        lookedUp.removeAll { $0.id == id }
        save()
    }

    /// The words looked up on pages the reader has now moved past, each asked
    /// once per chapter.
    func takeQuickCheck(before page: Int) -> [StudyCard] {
        let ids = lookedUp.filter { $0.page < page && !checked.contains($0.id) }.map(\.id)
        checked.formUnion(ids)
        return ids.compactMap { cards[$0] }
    }

    func chapterChanged() {
        lookedUp = []
        checked = []
    }

    func grade(_ card: StudyCard, _ grade: StudyGrade) {
        guard cards[card.id] != nil else { return }
        cards[card.id] = Self.schedule(card, grade, now: Date())
        save()
    }

    /// When the card would come back after `grade`, for the button labels.
    func preview(_ card: StudyCard, _ grade: StudyGrade) -> String {
        let next = Self.schedule(card, grade, now: Date())
        let minutes = next.due.timeIntervalSinceNow / 60
        if minutes < 60 { return "\(max(1, Int(minutes.rounded()))) min" }
        let days = minutes / 1440
        if days < 1 { return "\(Int((minutes / 60).rounded())) h" }
        if days < 30 { return "\(Int(days.rounded())) d" }
        return "\(Int((days / 30).rounded())) mo"
    }

    nonisolated static func schedule(_ card: StudyCard, _ grade: StudyGrade, now: Date) -> StudyCard {
        var c = card
        c.reviews += 1
        switch grade {
        case .again:
            if card.interval > 0 { c.lapses += 1 }
            c.interval = 0
            c.ease = max(1.3, card.ease - 0.2)
            c.due = now.addingTimeInterval(60)
            return c
        case .hard:
            c.interval = card.interval == 0 ? 0.5 : max(1, card.interval * 1.2)
            c.ease = max(1.3, card.ease - 0.15)
        case .good:
            c.interval = card.interval == 0 ? 1 : max(card.interval + 1, card.interval * card.ease)
        case .easy:
            c.interval = card.interval == 0 ? 4 : card.interval * card.ease * 1.3
            c.ease = card.ease + 0.15
        }
        c.due = now.addingTimeInterval(c.interval * 86_400)
        return c
    }

    private struct Saved: Codable {
        var cards: [StudyCard]
        var known: [String]
    }

    /// Atomic, so a crash mid-write leaves the last good deck rather than
    /// half of one.
    private func save() {
        let saved = Saved(cards: Array(cards.values), known: Array(known))
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try data.write(to: file, options: .atomic)
        } catch {
            AppLog.write("[study] deck save failed: \(error)")
        }
    }
}
