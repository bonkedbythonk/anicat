import SwiftUI

/// One round of cards: the sentence with the word marked, a moment to recall
/// it, then the answer and a grade. Used for the quick check in the reader
/// and for the daily review.
struct StudyReviewView: View {
    let title: String
    let onDone: () -> Void
    @State private var queue: [String]
    @State private var total: Int
    @State private var done = 0
    @State private var revealed = false
    private var deck: StudyDeck { StudyDeck.shared }

    init(title: String, cards: [StudyCard], onDone: @escaping () -> Void) {
        self.title = title
        self.onDone = onDone
        _queue = State(initialValue: cards.map(\.id))
        _total = State(initialValue: cards.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(queue.isEmpty ? title : "\(title) · \(min(done + 1, total)) of \(total)")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
                Spacer()
                Button(action: onDone) {
                    Text(queue.isEmpty ? "Close" : "Skip")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(SumiTheme.muted)
                }
                .buttonStyle(.sumiPressable)
            }
            if let id = queue.first, let card = deck.cards[id] {
                cardView(card)
            } else {
                Text(total == 0 ? "Nothing to review right now." : "Done. These words come back when they are due.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
            }
        }
        .padding(SumiTheme.spaceLg)
        .frame(maxWidth: 520, alignment: .leading)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusLg).stroke(SumiTheme.border, lineWidth: 1))
    }

    @ViewBuilder
    private func cardView(_ card: StudyCard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sentence(card)
                .font(.system(size: 26, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            if revealed {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(card.word)
                            .font(.system(size: 30, weight: .bold))
                            .foregroundColor(SumiTheme.foreground)
                        Button { StudySpeech.shared.speak(card.reading) } label: {
                            Label("Listen to the word", systemImage: "speaker.wave.2")
                                .labelStyle(.iconOnly)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(SumiTheme.indigo)
                        }
                        .buttonStyle(.sumiPressable)
                    }
                    if card.reading != card.word {
                        Text(card.reading)
                            .font(.system(size: 15))
                            .foregroundColor(SumiTheme.muted)
                    }
                    Text(card.meaning)
                        .font(.system(size: 14))
                        .foregroundColor(SumiTheme.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                    if !card.source.isEmpty {
                        Text(card.source)
                            .font(.system(size: 11.5))
                            .foregroundColor(SumiTheme.muted)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(StudyGrade.allCases, id: \.self) { grade in
                        Button { answer(card, grade) } label: {
                            VStack(spacing: 2) {
                                Text(grade.label)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(grade == .again ? SumiTheme.danger : (grade == .good ? SumiTheme.success : SumiTheme.foreground))
                                Text(deck.preview(card, grade))
                                    .sumiTabularMono(size: 10.5)
                                    .foregroundColor(SumiTheme.muted)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(SumiTheme.foregroundWash)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
            } else {
                Text("What does \(card.surface) mean, and how is it read? Say it before you look.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button { revealed = true } label: {
                    Text("Show answer")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(SumiTheme.indigo)
                }
                .buttonStyle(.sumiPressable)
                .keyboardShortcut(.space, modifiers: [])
            }
        }
    }

    /// The sentence with the word as it was written there marked.
    private func sentence(_ card: StudyCard) -> Text {
        guard let range = card.sentence.range(of: card.surface) else {
            return Text(card.sentence).foregroundColor(SumiTheme.foreground)
        }
        return Text(card.sentence[..<range.lowerBound]).foregroundColor(SumiTheme.foreground)
            + Text(card.sentence[range]).foregroundColor(SumiTheme.indigo).underline()
            + Text(card.sentence[range.upperBound...]).foregroundColor(SumiTheme.foreground)
    }

    /// A missed word goes to the back of this round, so it is asked again
    /// before the round ends rather than only tomorrow.
    private func answer(_ card: StudyCard, _ grade: StudyGrade) {
        deck.grade(card, grade)
        queue.removeFirst()
        if grade == .again {
            queue.append(card.id)
        } else {
            done += 1
        }
        revealed = false
    }
}

/// The Study section: the daily review of every word saved while reading.
struct StudyHomeView: View {
    @State private var reviewing: [StudyCard]?
    private var deck: StudyDeck { StudyDeck.shared }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Study")
                    .font(.sumiHeading(size: 28, weight: .bold))
                    .foregroundColor(SumiTheme.foreground)
                if let reviewing {
                    StudyReviewView(title: "Review", cards: reviewing) { self.reviewing = nil }
                } else {
                    let due = deck.dueCards
                    VStack(alignment: .leading, spacing: 6) {
                        Text(due.isEmpty ? "Nothing due" : "\(due.count) \(due.count == 1 ? "word" : "words") due")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                        Text("\(deck.cards.count) saved from manga. Words you click in study mode are saved here and come back on a schedule: soon after a miss, further apart each time you get one right.")
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !due.isEmpty {
                        Button { reviewing = due } label: {
                            Text("Start review")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(SumiTheme.background)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 9)
                                .background(SumiTheme.indigo)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        }
                        .buttonStyle(.sumiPressable)
                    }
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
