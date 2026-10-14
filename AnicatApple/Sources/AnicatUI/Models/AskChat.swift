import Foundation
import Observation
import AnicatCoreKit
#if canImport(FoundationModels) && !os(tvOS)
import FoundationModels
#endif

/// Gate and routing for the Search page's "Ask" conversation, which runs on the
/// system's on-device language model (macOS 26 or later, Apple Intelligence on).
enum AskSearch {
    /// Routing is by phrasing, not length: "That Time I Got Reincarnated as a
    /// Slime" is eight words and must stay a title search.
    private static let requestPattern =
        #"^(something|anything|show me|recommend|suggest|give me|i (want|wanna|need|feel|watched|loved|liked)|looking for|what should|(shows?|anime) (like|with|where|about|that))|\b(similar to|more like|something like)\b"#

    static func looksLikeRequest(_ query: String) -> Bool {
        query.split(whereSeparator: \.isWhitespace).count >= 3
            && query.range(of: requestPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static var isAvailable: Bool {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26.0, iOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// The first model call after a cold start took ~18 s against ~1 s once
    /// loaded; asking for the load while the viewer is still typing hides it.
    static func prewarm() {
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26.0, iOS 26.0, *), isAvailable {
            LanguageModelSession().prewarm()
        }
        #endif
    }

    /// A looked-up title counts only when it shares at least half of the typed
    /// name's words: AniList's search is fuzzy and answers a misremembered
    /// title with whatever sounds nearest. A word one letter off counts as the
    /// same word, because the two spellings of one title differ that way
    /// ("Haikyuu" typed, "HAIKYU!!" listed).
    static func matches(_ typed: String, _ found: String) -> Bool {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
        }
        let wanted = words(typed)
        guard !wanted.isEmpty else { return false }
        let listed = words(found)
        let shared = wanted.filter { w in listed.contains { oneApart(w, $0) } }.count
        return Double(shared) / Double(wanted.count) >= 0.5
    }

    private static func oneApart(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        // Six letters or more: at five, "tenku" and "tenkuu" are one word.
        guard a.count >= 6, b.count >= 6, abs(a.count - b.count) <= 1 else { return false }
        let x = Array(a), y = Array(b)
        var i = 0
        while i < min(x.count, y.count), x[i] == y[i] { i += 1 }
        if x.count == y.count { return Array(x[(i + 1)...]) == Array(y[(i + 1)...]) }
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        return Array(long[(i + 1)...]) == Array(short[i...])
    }

    /// Words that mean a genre without naming it. The model was asked for
    /// genres first and answered "Action" for "fewer ecchi"; reading them from
    /// the message is both stricter and cheaper.
    private static let genreWords: [(pattern: String, genres: [String])] = [
        ("gore|gory|scary|creepy|spooky|terrifying", ["Horror"]),
        ("violent|fighting|battles?", ["Action"]),
        ("funny|hilarious|lighthearted|laugh|lighter|feel-?good|happier", ["Comedy"]),
        ("love story|dating|couple|relationship|crush", ["Romance"]),
        ("sad|cry|emotional|tearjerker|heartbreaking", ["Drama"]),
        ("mind-?bending|twisty|plot twist", ["Psychological", "Mystery"]),
        ("detective|whodunit|crime", ["Mystery"]),
        ("space|futuristic|cyberpunk|time travel", ["Sci-Fi"]),
        ("magic|magical|isekai|dragons?|wizards?", ["Fantasy"]),
        ("cozy|relaxing|chill|wholesome|comfy", ["Slice of Life"]),
        ("volleyball|basketball|soccer|football|baseball|tennis|boxing", ["Sports"]),
        ("band|idols?|singing", ["Music"]),
        ("giant robots?|robots?", ["Mecha"]),
        ("ghosts?|demons?|spirits?", ["Supernatural"]),
        ("suspense|tense|thrilling", ["Thriller"]),
    ]

    /// The genres a message asks for, at most two, minus any it rules out.
    /// `names` are the shows it mentions: "Psycho-Pass" is not a request for
    /// the Psychological genre.
    static func requestedGenres(_ text: String, names: [String] = []) -> [String] {
        var lowered = text.lowercased()
        for name in names where !name.isEmpty { lowered = lowered.replacingOccurrences(of: name.lowercased(), with: " ") }
        var out = genres.filter { lowered.contains(String($0.lowercased().prefix(5))) }
        for (pattern, named) in genreWords where lowered.range(of: "\\b(\(pattern))\\b", options: .regularExpression) != nil {
            for genre in named where !out.contains(genre) { out.append(genre) }
        }
        let notWanted = ruledOut(text).genres
        return Array(out.filter { !notWanted.contains($0) }.prefix(2))
    }

    /// "something ive seen already", "rewatch", "from my list": the viewer wants
    /// the titles the rest of this chat leaves out. "i watched X" must not
    /// match, it is how the first message of a chat usually begins.
    static func wantsSeen(_ text: String) -> Bool {
        text.range(
            of: #"(seen|watched)\s+(it\s+)?already|already\s+(seen|watched)|something\s+(i\s*'?\s*ve\s+|i\s+have\s+)?(seen|watched)|\brewatch|\bwatch\s+again|\bfrom\s+my\s+(list|library)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    /// Hands out the one answer a time-limited call gets.
    @MainActor private final class Gate {
        private var used = false
        func open() -> Bool {
            if used { return false }
            used = true
            return true
        }
    }

    /// The result of `work`, or `fallback` once `seconds` have passed. One turn
    /// makes several AniList calls and the engine sleeps a rate-limit cooldown
    /// out inside each, up to a minute apiece; the model's first call has also
    /// taken ~18 s. Without a limit a bad minute was a spinner that never ended.
    /// The slow work is not cancelled (it sits in calls that do not observe
    /// cancellation); its late result is dropped.
    @MainActor static func within<T: Sendable>(seconds: UInt64, fallback: T, _ work: @escaping @MainActor () async -> T) async -> T {
        let gate = Gate()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            Task { @MainActor in
                let result = await work()
                if gate.open() { continuation.resume(returning: result) }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
                if gate.open() { continuation.resume(returning: fallback) }
            }
        }
    }

    /// A greeting or a thank-you, which is a chat turn and not a request.
    static func smallTalk(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func hit(_ p: String) -> Bool { t.range(of: "^(\(p))[\\s!.?]*$", options: .regularExpression) != nil }
        if hit("thanks|thank you|thx|ty|great|cool|nice|perfect|awesome|ok|okay|lol") {
            return "Anytime. Say what you want more or less of, or tap one of the ideas below."
        }
        if hit("hi|hello|hey|yo") {
            return "Hi. Tell me a show you liked, or what you are in the mood for."
        }
        return nil
    }

    /// A show named after "like", "watched" and the like, for when the model
    /// cannot read the message. "something like Frieren but darker" gives
    /// "Frieren"; a title that runs past "but" or "and" is cut there.
    static func guessShows(_ text: String) -> [String] {
        let pattern = #"(?:like|similar to|watched|loved|liked|enjoyed)\s+(.+?)(?=\s+(?:but|and|with|because)\b|[,.?!]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return [] }
        let name = text[range].trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty || name.split(separator: " ").count > 6 ? [] : [name]
    }

    /// "surprise me": no show and no genre, the viewer's own taste is the brief.
    static func wantsSurprise(_ text: String) -> Bool {
        text.range(of: #"surprise\s+me|you\s+pick|your\s+(pick|choice)|anything\s+(good|goes)|\brandom\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What the viewer ruled out in words: "fewer ecchi", "no horror", "short".
    /// The model agreed to these in its replies ("less ecchi, shorter") and then
    /// picked The Quintessential Quintuplets, so they are enforced on the
    /// candidates instead of left to it.
    static func ruledOut(_ text: String) -> (genres: Set<String>, shortOnly: Bool) {
        let lowered = text.lowercased()
        var genres = Set<String>()
        for genre in AskSearch.genres {
            let stem = NSRegularExpression.escapedPattern(for: String(genre.lowercased().prefix(5)))
            if lowered.range(of: #"\b(fewer|less|no|without|avoid|skip|not)\s+(\w+\s+)?"# + stem, options: .regularExpression) != nil {
                genres.insert(genre)
            }
        }
        return (genres, lowered.range(of: #"\bshort(er)?\b"#, options: .regularExpression) != nil)
    }

    /// AniList genre names the model may name.
    static let genres = [
        "Action", "Adventure", "Comedy", "Drama", "Ecchi", "Fantasy", "Horror", "Mecha", "Music", "Mystery",
        "Psychological", "Romance", "Sci-Fi", "Slice of Life", "Sports", "Supernatural", "Thriller",
    ]
}

/// One conversation about what to watch. The model is never trusted to name
/// titles: asked to, it echoed the viewer's own list back and repeated the same
/// six every turn (measured). It reads the viewer's message and chooses among
/// numbered candidates that AniList supplied, so every card is a real entry.
@MainActor @Observable
final class AskChat {
    struct Message: Identifiable {
        enum Role { case viewer, assistant }
        let id = UUID()
        let role: Role
        let text: String
        var cards: [MediaCard.Item] = []
        /// Short follow-ups offered under a reply, each sent as the viewer's
        /// next message when tapped.
        var suggestions: [String] = []
    }

    private(set) var messages: [Message] = []
    private(set) var isThinking = false
    /// What the current turn is doing, for the line beside the spinner.
    private(set) var status = ""
    var isOpen = false

    /// Shows the viewer named, newest last. Their recommendations are the
    /// candidate pool, which is how "yeah, more of that" still knows what
    /// "that" is two turns later.
    private var anchors: [(id: Int64, title: String)] = []
    private var shown = Set<Int64>()
    private var details: [Int64: MediaDetail] = [:]
    private var finished: [MediaCard.Item]?
    /// Titles shown in this launch's chats, kept through "New chat": three
    /// different prompts in three fresh chats came back with the same few.
    private var recentlyShown: [Int64] = []
    /// The genres of the viewer's previous message, so "and something i've seen"
    /// after a romance still leans romance.
    private var lastGenres: [String] = []
    private var running: Task<Void, Never>?

    func open(_ text: String, model: AppModel) {
        isOpen = true
        send(text, model: model)
    }

    func send(_ text: String, model: AppModel) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        messages.append(Message(role: .viewer, text: text))
        isThinking = true
        running = Task { [weak self] in
            guard let self else { return }
            let reply = await self.answerWithin(seconds: 45, text, model: model)
            guard !Task.isCancelled else { return }
            self.messages.append(reply)
            self.isThinking = false
            self.status = ""
        }
    }

    /// Back to the plain Search page; the thread is kept for the way back.
    func close() { isOpen = false }

    func clear() {
        running?.cancel()
        running = nil
        messages = []
        anchors = []
        shown = []
        details = [:]
        finished = nil
        lastGenres = []
        isThinking = false
        status = ""
        isOpen = false
    }

    private func answerWithin(seconds: UInt64, _ text: String, model: AppModel) async -> Message {
        await AskSearch.within(
            seconds: seconds,
            fallback: Message(role: .assistant, text: "That is taking too long. Try asking again in a moment.")
        ) { await self.answer(text, model: model) }
    }

    private func answer(_ text: String, model: AppModel) async -> Message {
        if text.range(of: #"\b(manga|manhwa|webtoon|novels?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return Message(role: .assistant, text: "Ask only knows anime for now. Search handles manga and novels.")
        }
        #if canImport(FoundationModels) && !os(tvOS)
        if #available(macOS 26.0, iOS 26.0, *), let engine = model.engine {
            return await converse(text, model: model, engine: engine)
        }
        #endif
        return Message(role: .assistant, text: "Ask needs Apple Intelligence, which is not available on this Mac.")
    }

    #if canImport(FoundationModels) && !os(tvOS)
    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct Intent {
        @Guide(description: "Names of anime the viewer typed in this message, exactly as typed. Empty when they typed none.")
        var shows: [String]
    }

    @available(macOS 26.0, iOS 26.0, *)
    @Generable
    struct Reply {
        @Guide(description: "One friendly sentence, under 22 words, saying how the picks answer the request. No numbers.")
        var message: String
        @Guide(description: "Numbers of the candidates to show, best first.", .count(1...6), .element(.range(1...40)))
        var picks: [Int]
    }

    private struct Candidate {
        let facts: FfiMediaFacts
        let because: String
    }

    @available(macOS 26.0, iOS 26.0, *)
    /// A new session every turn. One kept for the whole chat carried every
    /// turn's numbered candidate list in its memory: after a dozen turns the
    /// 8k-token window was mostly old lists, and the model answered with the
    /// numbers and titles of an earlier one. What a turn needs of the chat (the
    /// named shows, what was shown, the genres) is held in code and what the
    /// viewer asked lately is in the prompt.
    private func session(loved: [String]) -> LanguageModelSession {
        var instructions = """
            You are the recommendation chat inside an anime app, talking with one viewer. \
            Each message from the app lists numbered candidates taken from AniList. \
            Choose only from those numbers and never invent a title. \
            Earlier candidates are the better matches, so prefer them, and pick four to six. \
            When your last reply is quoted, say it differently. \
            Write one friendly sentence of under 22 words that says how the picks answer the \
            request, and begin it differently each time, never with "These". Name only genres \
            from the list, never state episode counts or any number, and never claim anything \
            else about a show.
            """
        if !loved.isEmpty {
            instructions += " For taste only, the viewer rates these highest: \(loved.joined(separator: ", "))."
        }
        return LanguageModelSession(instructions: instructions)
    }

    @available(macOS 26.0, iOS 26.0, *)
    private func converse(_ text: String, model: AppModel, engine: AnicatEngine) async -> Message {
        if let reply = AskSearch.smallTalk(text) {
            return Message(role: .assistant, text: reply, suggestions: ["Surprise me", "Something I've seen already"])
        }
        // Every call below would sleep a rate-limit cooldown out one after the
        // other, so say so now instead of after minutes.
        let cooldown = Int(engine.anilistCooldownSeconds())
        if cooldown > 10 {
            return Message(role: .assistant, text: "AniList is rate limiting right now. Try again in about \(cooldown) seconds.")
        }
        // A few seconds is shorter than being told to try again.
        if cooldown > 0 { try? await Task.sleep(nanoseconds: UInt64(cooldown) * 1_000_000_000 + 300_000_000) }
        status = "Reading your message"
        // The system model can fail outright while still reporting itself
        // available (its sensitive-content model not loading, `error 15`, failed
        // every call including "hello"), so show names fall back on the wording.
        let intent = (try? await LanguageModelSession(instructions: "Read an anime viewer's message.")
            .respond(to: text, generating: Intent.self).content) ?? Intent(shows: AskSearch.guessShows(text))
        // The model volunteers things the viewer never typed: "Naruto" for
        // "something a bit more dramatic", "Action" for "fewer ecchi, and
        // shorter", and no Ecchi at all for "what about an ecchi". So it is
        // trusted for show names only, and only when the name is in the
        // message; genres are read from the words, by stem ("roman" for Romance
        // and for romantic alike).
        let lowered = text.lowercased()
        let named = intent.shows.filter { lowered.contains($0.lowercased()) }
        let unresolved = await resolveAnchors(named, engine: engine)
        // Only a name that resolved is masked out of the genre read: the model
        // took "ecchi comedy" for a show, and masking that removed both genres.
        let genres = AskSearch.requestedGenres(text, names: named.filter { !unresolved.contains($0) })
        if let first = unresolved.first, anchors.isEmpty, genres.isEmpty {
            return Message(role: .assistant, text: "I could not find \"\(first)\" on AniList. Check the spelling, or name another show.")
        }
        // `libraryItems` is only the status the Library page happens to show,
        // so the finished list is fetched here (the engine caches it): without
        // it the taste prompt was empty and "something i've seen" had a pool
        // of one.
        status = "Checking your list"
        let finishedList = await finishedTitles(engine: engine)
        let own = finishedList + model.libraryItems + model.watchingItems
        let loved = Array(own.filter { !$0.isManga }.sorted { ($0.score ?? 0) > ($1.score ?? 0) }.map(\.title).prefix(10))
        // No show and no genre ("surprise me", "something good"): the brief is
        // what the viewer rated highest, which is what knowing their list is for.
        var fromTaste = false
        if (anchors.isEmpty && genres.isEmpty || AskSearch.wantsSurprise(text)) && !AskSearch.wantsSeen(text) {
            // Three of the eight rated highest, not always the top three: every
            // prompt that named nothing got the same brief and the same answer.
            anchors = own.filter { !$0.isManga }.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
                .prefix(8).shuffled().prefix(3).map { ($0.id, $0.title) }
            fromTaste = true
        }
        status = "Finding candidates"
        var (pool, failed) = AskSearch.wantsSeen(text)
            ? await seenCandidates(own: own, engine: engine)
            : await candidates(genres: genres, engine: engine, onList: Set(own.map(\.id)))
        if !genres.isEmpty {
            // Asked for in so many words, so enforced: the model picked a
            // plain romance for "what about an ecchi", and Naruto for "ecchi
            // comedy" when one of the two genres was enough. Every genre
            // first; any of them only when that leaves too few to choose from.
            let every = pool.filter { c in genres.allSatisfy { c.facts.genres.contains($0) } }
            pool = every.count >= 3 ? every : pool.filter { c in genres.contains { c.facts.genres.contains($0) } }
        }
        let ruledOut = AskSearch.ruledOut(text)
        pool = pool.filter { c in
            c.facts.genres.allSatisfy { !ruledOut.genres.contains($0) }
                && (!ruledOut.shortOnly || (c.facts.media.episodes ?? 99) <= 13)
        }
        // Behind the ones not yet shown in any chat, when enough of those remain;
        // and with no brief to rank by, in no particular order.
        let unseenBefore = pool.filter { !recentlyShown.contains($0.facts.media.catalogId) }
        if unseenBefore.count >= 8 { pool = unseenBefore }
        if fromTaste { pool.shuffle() }
        // Candidates in rating order put the most voted-for show first, which for
        // a fake-marriage romcom was One Piece. Ranked instead by how many of
        // the wanted genres they share: the ones asked for, the named shows' own
        // genres, and last turn's. Ties keep rating order.
        let wantedGenres = Set(genres + lastGenres + anchors.flatMap { details[$0.id]?.genres ?? [] }.filter { AskSearch.genres.contains($0) })
        if !wantedGenres.isEmpty {
            pool = pool.enumerated().sorted { a, b in
                let x = a.element.facts.genres.filter(wantedGenres.contains).count
                let y = b.element.facts.genres.filter(wantedGenres.contains).count
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        }
        lastGenres = genres.isEmpty ? lastGenres : genres
        AppLog.write("[asksearch] \"\(text)\": anchors \(anchors.map(\.title)), genres \(genres), pool \(pool.count)\(failed ? ", some lookups failed" : "")")
        guard !pool.isEmpty else {
            return Message(role: .assistant, text: failed
                ? "AniList is not answering right now. Try again in a minute."
                : AskSearch.wantsSeen(text)
                    ? "Nothing on your list matches that."
                    : genres.isEmpty
                        ? "Tell me a show you liked, or a genre, and I will find more like it."
                        : "I found nothing like that which is not already on your list.")
        }

        status = "Choosing"
        var listing = "Viewer: \(text)\n"
        if fromTaste {
            listing += "The message names no show or genre, so these come from the shows they rated highest: \(anchors.map(\.title).joined(separator: ", ")).\n"
        } else if !anchors.isEmpty {
            listing += "Shows they named so far: \(anchors.map(\.title).joined(separator: ", ")).\n"
        }
        if !genres.isEmpty { listing += "Genres they asked for: \(genres.joined(separator: ", ")).\n" }
        if !ruledOut.genres.isEmpty { listing += "Genres they ruled out: \(ruledOut.genres.sorted().joined(separator: ", ")).\n" }
        if ruledOut.shortOnly { listing += "They want short series.\n" }
        // What the chat so far adds, in words and not as a transcript: the
        // viewer's last few messages (the current one is already above) and the
        // sentence it is not to repeat.
        let earlier = messages.dropLast().filter { $0.role == .viewer }.suffix(3).map(\.text)
        if !earlier.isEmpty { listing += "Earlier they asked: \(earlier.map { "\"\($0)\"" }.joined(separator: ", ")).\n" }
        if let last = messages.last(where: { $0.role == .assistant && !$0.cards.isEmpty }) {
            listing += "Your last reply was: \"\(last.text)\"\n"
        }
        listing += "Candidates:\n"
        for (index, c) in pool.enumerated() {
            let m = c.facts.media
            let length = m.episodes.map { "\($0) eps" } ?? "length unknown"
            listing += "\(index + 1). \(m.title) | \(m.format ?? "?"), \(length) | \(c.facts.genres.prefix(5).joined(separator: ", "))\n"
        }

        for attempt in 0..<2 {
            do {
                let reply = try await session(loved: loved).respond(to: listing, generating: Reply.self).content
                var picked = Set<Int>()
                var chosen = reply.picks.filter { pool.indices.contains($0 - 1) && picked.insert($0).inserted }.map { pool[$0 - 1] }
                guard !chosen.isEmpty else { break }
                // The model often stops at two or three of thirty; the pool is
                // already filtered to what was asked, in rating order, so the
                // next ones are safe to add.
                for (index, c) in pool.enumerated() where chosen.count < 4 && !picked.contains(index + 1) { chosen.append(c) }
                shown.formUnion(chosen.map { $0.facts.media.catalogId })
                remember(chosen)
                var next = ["Shorter", "Something I've seen already", "Surprise me"]
                if let first = chosen.first { next.insert("More like \(first.facts.media.title)", at: 0) }
                return Message(role: .assistant, text: reply.message, cards: chosen.map(Self.card), suggestions: next)
            } catch {
                AppLog.write("[asksearch] reply failed (attempt \(attempt + 1)): \(error)")
            }
        }
        // Both attempts failed: the candidates are already filtered to what was
        // asked, so show the first of them and say why there is no sentence.
        let plain = Array(pool.prefix(4))
        shown.formUnion(plain.map { $0.facts.media.catalogId })
        remember(plain)
        return Message(
            role: .assistant,
            text: "Apple Intelligence is not answering right now, so these are plain matches for what you asked.",
            cards: plain.map(Self.card),
            suggestions: ["Shorter", "Something I've seen already", "Surprise me"]
        )
    }

    /// The viewer's own list, best rated first, for "something i've seen
    /// already". Everything else in this file takes the list out of the pool.
    private func seenCandidates(own: [MediaCard.Item], engine: AnicatEngine) async -> (pool: [Candidate], failed: Bool) {
        var seen = Set<Int64>(shown)
        let pick = own
            .filter { !$0.isManga && seen.insert($0.id).inserted }
            .sorted { ($0.score ?? 0) > ($1.score ?? 0) }
            .prefix(30)
        guard let facts = try? await engine.mediaFacts(catalogIds: pick.map(\.id)) else { return ([], true) }
        return (facts.map { Candidate(facts: $0, because: "On your list") }, false)
    }

    private func remember(_ picks: [Candidate]) {
        recentlyShown = Array((recentlyShown + picks.map { $0.facts.media.catalogId }).suffix(80))
    }

    private func finishedTitles(engine: AnicatEngine) async -> [MediaCard.Item] {
        if let finished { return finished }
        let rows = (try? await engine.userList(status: "COMPLETED", mediaType: "ANIME")) ?? []
        let cards = rows.map(AppModel.card)
        finished = cards
        return cards
    }

    private func resolveAnchors(_ typed: [String], engine: AnicatEngine) async -> [String] {
        var unresolved: [String] = []
        for title in typed {
            guard let hit = try? await engine.searchCatalog(query: title, mediaType: "ANIME", filters: nil, page: 1)
                .first(where: { AskSearch.matches(title, $0.title) }) else {
                unresolved.append(title)
                continue
            }
            anchors.removeAll { $0.id == hit.catalogId }
            anchors.append((hit.catalogId, hit.title))
        }
        if anchors.count > 3 { anchors.removeFirst(anchors.count - 3) }
        return unresolved
    }

    /// AniList's own recommendations for the named shows plus the best of any
    /// genre asked for, with the viewer's list, earlier picks and the named
    /// shows themselves taken out. `failed` is set when AniList refused some of
    /// the lookups, so an empty pool is not reported as "nothing found".
    ///
    private func candidates(genres: [String], engine: AnicatEngine, onList: Set<Int64>) async -> (pool: [Candidate], failed: Bool) {
        var failed = false
        var wanted: [(id: Int64, because: String)] = []
        let known = details
        let fetched = await withTaskGroup(of: (Int64?, MediaDetail?, [(Int64, String)]).self) { group in
            for anchor in anchors {
                group.addTask {
                    let detail: MediaDetail?
                    if let cached = known[anchor.id] { detail = cached } else {
                        detail = try? await engine.mediaDetail(catalogId: anchor.id, isManga: false)
                    }
                    guard let detail else { return (anchor.id, nil, []) }
                    let recs = detail.recommendations
                        .sorted { ($0.rating ?? 0) > ($1.rating ?? 0) }
                        .prefix(12)
                        .map { ($0.catalogId, "Like \(anchor.title)") }
                    return (anchor.id, detail, Array(recs))
                }
            }
            var out: [(Int64?, MediaDetail?, [(Int64, String)])] = []
            for await row in group { out.append(row) }
            return out
        }
        for (anchorId, detail, rows) in fetched {
            if let anchorId, let detail { details[anchorId] = detail } else { failed = true }
            wanted += rows.map { (id: $0.0, because: $0.1) }
        }

        // Without a genre of its own the message falls back on the named
        // shows' genres, and each turn reads one page deeper: the first twelve
        // recommendations are spent after two answers, and the third turn
        // ("fewer ecchi, and shorter") had two candidates left.
        let searchGenres = !genres.isEmpty ? genres : Array(anchors
            .flatMap { details[$0.id]?.genres ?? [] }
            .filter { AskSearch.genres.contains($0) }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(2))
        let page = Int32(messages.filter { $0.role == .assistant }.count + 1)
        let found = await withTaskGroup(of: [(Int64, String)]?.self) { group in
            for genre in searchGenres {
                group.addTask {
                    let filters = SearchFilters(genre: genre, year: nil, season: nil, format: nil, minScore: 70, status: nil, sort: "POPULARITY_DESC", country: nil)
                    guard let rows = try? await engine.searchCatalog(query: "", mediaType: "ANIME", filters: filters, page: page) else { return nil }
                    // `listStatus` on a search row is the viewer's own entry, and
                    // a signed-in viewer has most of the popular titles of a
                    // genre on their list: unfiltered, one turn's eight slots
                    // were all spent on titles that were dropped afterwards.
                    return rows.filter { $0.listStatus == nil }.prefix(15).map { ($0.catalogId, genre) }
                }
            }
            var out: [[(Int64, String)]?] = []
            for await rows in group { out.append(rows) }
            return out
        }
        for rows in found {
            if let rows { wanted += rows.map { (id: $0.0, because: $0.1) } } else { failed = true }
        }

        // Titles already on the viewer's list are dropped before any lookup, so
        // none of the pool is spent on one.
        var seen = Set<Int64>(shown)
        seen.formUnion(anchors.map(\.id))
        seen.formUnion(onList)
        let fresh = Array(wanted.filter { seen.insert($0.id).inserted }.prefix(30))

        // One request for all of them. Looking each up with `mediaDetail` was
        // twelve requests a turn and AniList rate limited the second turn; the
        // engine caches every title it returns, so a follow-up that names the
        // same shows asks for almost nothing.
        var facts: [Int64: FfiMediaFacts] = [:]
        do {
            for f in try await engine.mediaFacts(catalogIds: fresh.map(\.id)) { facts[f.media.catalogId] = f }
        } catch {
            failed = true
        }

        // `listStatus` is the viewer's own entry on that title, which is the
        // "already on my list" filter without a second source of truth.
        let pool = fresh.compactMap { row -> Candidate? in
            guard let f = facts[row.id], f.media.listStatus == nil else { return nil }
            return Candidate(facts: f, because: row.because)
        }
        return (pool, failed)
    }

    private static func card(_ c: Candidate) -> MediaCard.Item {
        let m = c.facts.media
        return MediaCard.Item(
            id: m.catalogId,
            title: m.title,
            coverImageURL: URL(string: m.coverImage),
            score: m.averageScore.map { Int($0) },
            totalEpisodesOrChapters: m.episodes.map { Int($0) },
            // Under the title the card has room for a few words: the genres
            // say more than "Like <a long title>", which was cut off mid-word.
            playlistReason: c.facts.genres.isEmpty ? c.because : c.facts.genres.prefix(2).joined(separator: ", "),
            format: m.format
        )
    }
    #endif
}
