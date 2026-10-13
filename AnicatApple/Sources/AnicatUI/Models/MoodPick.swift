import Foundation
import AnicatCoreKit
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// "Pick for me" with a mood typed in: the sheet's own candidates, reordered by
/// what the viewer said. The model picks numbers from lists the viewer already
/// has and writes the reason; genres, "fewer X" and "short" are read from the
/// words in code, as in the Ask chat, because the model got those wrong.
enum MoodPick {
    enum Outcome: Sendable {
        case picks([PickerCandidate], reason: String)
        case note(String)
    }

    @MainActor
    static func rank(_ text: String, from candidates: [PickerCandidate], engine: AnicatEngine) async -> Outcome {
        let wait = Int(engine.anilistCooldownSeconds())
        if wait > 0 {
            return .note("AniList is rate limiting right now. Try again in about \(wait) seconds.")
        }
        let top = Array(candidates.prefix(24))
        guard !top.isEmpty else { return .note("Nothing in your lists to pick from.") }
        guard let facts = try? await engine.mediaFacts(catalogIds: top.map(\.id)) else {
            return .note("AniList is not answering right now. Try again in a minute.")
        }
        let byId = Dictionary(facts.map { ($0.media.catalogId, $0) }, uniquingKeysWith: { a, _ in a })

        // Titles AniList sent nothing for (manga, a lookup that failed) cannot be
        // judged against the words, so they drop out.
        var pool = top.compactMap { c in byId[c.id].map { (candidate: c, facts: $0) } }
        let ruledOut = AskSearch.ruledOut(text)
        pool = pool.filter { entry in
            entry.facts.genres.allSatisfy { !ruledOut.genres.contains($0) }
                && (!ruledOut.shortOnly || (entry.facts.media.episodes ?? 99) <= 13)
        }
        let genres = AskSearch.requestedGenres(text)
        if !genres.isEmpty {
            let every = pool.filter { entry in genres.allSatisfy { entry.facts.genres.contains($0) } }
            pool = every.count >= 2 ? every : pool.filter { entry in genres.contains { entry.facts.genres.contains($0) } }
        }
        guard !pool.isEmpty else { return .note("Nothing in your lists matches that.") }

        let plain = Outcome.picks(pool.map(\.candidate), reason: "Closest to \"\(text)\" in your lists.")
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            return await modelOrder(text, pool: pool, fallback: plain)
        }
        #endif
        return plain
    }

    #if canImport(FoundationModels) && !os(tvOS)
    @MainActor @available(macOS 26.0, iOS 26.0, *)
    private static func modelOrder(
        _ text: String,
        pool: [(candidate: PickerCandidate, facts: FfiMediaFacts)],
        fallback: Outcome
    ) async -> Outcome {
        var listing = "Viewer's mood: \(text)\nCandidates, all from their own lists:\n"
        for (index, entry) in pool.enumerated() {
            let m = entry.facts.media
            let length = m.episodes.map { "\($0) eps" } ?? "length unknown"
            listing += "\(index + 1). \(m.title) | \(m.format ?? "?"), \(length) | \(entry.facts.genres.prefix(5).joined(separator: ", "))\n"
        }
        let session = LanguageModelSession(instructions: """
            You help a viewer choose what to watch tonight from their own lists. \
            Choose only from the numbered candidates, best match first, and pick up to six. \
            Write one friendly sentence of under 22 words saying why the first one fits their mood. \
            Name only genres from the list, never state episode counts or any number, \
            and never claim anything else about a show.
            """)
        do {
            let reply = try await session.respond(to: listing, generating: AskChat.Reply.self).content
            var seen = Set<Int>()
            var order = reply.picks.filter { pool.indices.contains($0 - 1) && seen.insert($0).inserted }.map { pool[$0 - 1].candidate }
            guard !order.isEmpty else { return fallback }
            let chosen = Set(order.map(\.id))
            order += pool.map(\.candidate).filter { !chosen.contains($0.id) }
            return .picks(order, reason: reply.message)
        } catch {
            AppLog.write("[moodpick] model failed for \"\(text)\": \(error)")
            return fallback
        }
    }
    #endif
}
