import Foundation
import AnicatCoreKit
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// What the on-device model makes of one line.
struct StudyExplanation: Equatable {
    struct Point: Equatable {
        let phrase: String
        let meaning: String
    }

    let translation: String
    let spansBubbles: Bool
    let literal: String
    let points: [Point]
}

/// "Explain this sentence": the line, the bubbles around it and the
/// dictionary's breakdown, handed to the system model. The breakdown is in the
/// prompt so the model explains facts it was given instead of recalling
/// readings and meanings of its own, which is where a small model is wrong.
@MainActor
enum StudyExplainer {
    /// Off with the reason when the model cannot run here.
    static var unavailableReason: String? {
        let summary = AskAvailability.summary
        return summary.isOn ? nil : summary.text
    }

    private static var cache: [String: StudyExplanation] = [:]

    static func cached(_ line: String) -> StudyExplanation? { cache[line] }

    static func explain(line: String, before: [String], after: [String], tokens: [StudyToken]) async throws -> StudyExplanation {
        if let hit = cache[line] { return hit }
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            let session = LanguageModelSession(instructions: """
                You explain lines of Japanese manga to an English speaker who is a beginner: \
                they read hiragana and about 200 kanji. You get the line, the speech bubbles \
                around it on the page in reading order, and a dictionary breakdown of the \
                line's words. Use the dictionary's meanings and readings; do not invent your \
                own. A sentence in manga often runs across two or three bubbles: when this \
                line starts or ends mid-sentence, translate the whole sentence. Explain \
                particles and verb endings in plain words, without linguistics jargon.

                Particles: が marks who or what does the action (the subject). を marks \
                what the action is done to (the object). は marks the topic. に marks a \
                target, place or time. で marks where or with what. の links nouns \
                ("my", "of"). な joins a na-adjective to the noun after it. と means \
                "and", "with" or marks a quote. も means "also". か at the end asks a \
                question. ね and よ at the end soften or stress the sentence.
                """)
            let reply = try await session.respond(to: prompt(line: line, before: before, after: after, tokens: tokens), generating: Reply.self).content
            let result = StudyExplanation(
                translation: reply.translation,
                spansBubbles: reply.spansBubbles,
                literal: reply.literal,
                points: reply.points.map { .init(phrase: $0.phrase, meaning: $0.meaning) }
            )
            cache[line] = result
            return result
        }
        #endif
        throw StudySession.Failure(message: unavailableReason ?? "Apple Intelligence is not available.")
    }

    private static func prompt(line: String, before: [String], after: [String], tokens: [StudyToken]) -> String {
        var out = ""
        if !before.isEmpty { out += "Bubbles before:\n" + before.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        out += "Line to explain: \(line)\n\n"
        if !after.isEmpty { out += "Bubbles after:\n" + after.map { "- \($0)" }.joined(separator: "\n") + "\n\n" }
        out += "Dictionary breakdown of the line:\n"
        for token in tokens where token.isWord {
            guard let entry = token.entries.first else {
                out += "- \(token.surface): not in the dictionary\n"
                continue
            }
            // JMdict's first sense of a particle is often the wrong one for
            // the line: な came through as "don't" after 真っ白, and the model
            // repeated it. The particle notes in the instructions cover these.
            if entry.senses.first?.partsOfSpeech.contains("prt") == true {
                out += "- \(token.surface): particle\n"
                continue
            }
            let glosses = entry.senses.prefix(2).flatMap(\.glosses).prefix(4).joined(separator: "; ")
            let form = token.steps.isEmpty ? "" : " (\(token.steps.joined(separator: " + ")))"
            let base = entry.word == token.surface ? token.surface : "\(token.surface) = \(entry.word)\(form)"
            out += "- \(base), read \(entry.reading): \(glosses)\n"
        }
        return out
    }

    /// The first call after a cold start is slow (Ask measured ~18 s against
    /// ~1 s once loaded), so the model starts loading when study mode does.
    static func prewarm() {
        AskSearch.prewarm()
    }

    #if canImport(FoundationModels) && !os(tvOS)
    @available(macOS 26.0, iOS 26.0, *)
    /// Generated in declaration order, so the grammar comes first: with the
    /// translation first the model committed to "I am sucking up my life
    /// with pure white snow" before it had looked at what が marked.
    @Generable
    struct Reply {
        @Guide(description: "The grammar points in this line a beginner needs, best first.", .count(1...3))
        var points: [ReplyPoint]
        @Guide(description: "The line itself in English words only, word by word, keeping the Japanese word order. No Japanese characters.")
        var literal: String
        @Guide(description: "True when the sentence starts in an earlier bubble or ends in a later one.")
        var spansBubbles: Bool
        @Guide(description: "A natural English translation of the whole sentence this line belongs to, joining the bubbles before or after when the sentence runs across them. Keep who does what to whom exactly as the particles say.")
        var translation: String
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct ReplyPoint {
        @Guide(description: "A short Japanese phrase copied exactly from the line.")
        var phrase: String
        @Guide(description: "What it does here, in one or two plain English sentences.")
        var meaning: String
    }
    #endif
}
