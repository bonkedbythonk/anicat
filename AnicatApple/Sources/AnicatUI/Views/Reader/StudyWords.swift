import SwiftUI
import Foundation
import AVFoundation
import AnicatCoreKit

/// Reads a sentence or a word aloud with the system's Japanese voice.
@MainActor
final class StudySpeech {
    static let shared = StudySpeech()
    private let synthesizer = AVSpeechSynthesizer()

    /// The best Japanese voice installed. The default compact voice is the
    /// robotic one; a Premium or Enhanced voice (Kyoko, Otoya and the newer
    /// ones, downloaded in System Settings > Accessibility > Spoken Content)
    /// is picked whenever there is one.
    private lazy var voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice.speechVoices()
        .filter { $0.language == "ja-JP" }
        .max { $0.quality.rawValue < $1.quality.rawValue }
        ?? AVSpeechSynthesisVoice(language: "ja-JP")

    func speak(_ text: String) {
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // A little under the default: at full speed a learner hears one
        // run-on word instead of the pieces the panel shows.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.85
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// The study dictionary: JMdict and KANJIDIC2, downloaded once and built
/// into a SQLite file by the engine.
@MainActor
@Observable
final class StudyWords {
    enum State: Equatable {
        case unknown
        case preparing
        case ready
        case failed(String)
    }

    static let shared = StudyWords()

    private(set) var state: State = .unknown
    private let dictionary: StudyDictionary
    nonisolated private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Anicat/study", isDirectory: true)

    /// Pinned to one jmdict-simplified release rather than "latest": the
    /// asset names carry the release date, so a latest URL has to be looked
    /// up first, and a dictionary a few months old reads manga the same.
    nonisolated private static let release = "3.6.2%2B20261102210542"
    nonisolated private static let words = URL(string: "https://github.com/scriptin/jmdict-simplified/releases/download/\(release)/jmdict-eng-\(release).json.tgz")!
    nonisolated private static let kanji = URL(string: "https://github.com/scriptin/jmdict-simplified/releases/download/\(release)/kanjidic2-en-\(release).json.tgz")!

    private init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        dictionary = StudyDictionary(path: Self.root.appendingPathComponent("dictionary.sqlite").path)
        if dictionary.isReady() { state = .ready }
    }

    /// Downloads and builds the dictionary the first time study mode is
    /// turned on; a no-op once it is there.
    func prepare() {
        guard state == .unknown || isFailed else { return }
        state = .preparing
        let dictionary = dictionary
        Task {
            do {
                let (words, kanji) = try await Self.download()
                try await dictionary.build(wordsJson: words.path, kanjiJson: kanji.path)
                try? FileManager.default.removeItem(at: Self.root.appendingPathComponent("download"))
                state = .ready
            } catch {
                AppLog.write("[study] dictionary failed: \(error)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var isFailed: Bool {
        if case .failed = state { return true }
        return false
    }

    func lookup(_ text: String) -> [StudyToken] {
        guard state == .ready else { return [] }
        return (try? dictionary.lookup(text: text)) ?? []
    }

    func kanji(in word: String) -> [StudyKanji] {
        guard state == .ready else { return [] }
        return (try? dictionary.kanji(word: word)) ?? []
    }

    /// The two JSON files, unpacked. `tar` rather than a decompressor in the
    /// engine: study mode is Mac-only already, and the system tar adds no
    /// dependency to the crate.
    nonisolated private static func download() async throws -> (URL, URL) {
        #if os(macOS)
        let fm = FileManager.default
        let dir = root.appendingPathComponent("download", isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for url in [words, kanji] {
            let (file, _) = try await URLSession.shared.download(from: url)
            let archive = dir.appendingPathComponent(url.lastPathComponent)
            try fm.moveItem(at: file, to: archive)
            let tar = Process()
            tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tar.arguments = ["-xzf", archive.path, "-C", dir.path]
            try tar.run()
            tar.waitUntilExit()
            guard tar.terminationStatus == 0 else {
                throw StudySession.Failure(message: "Could not unpack \(url.lastPathComponent).")
            }
        }
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        guard let words = names.first(where: { $0.hasPrefix("jmdict-eng") && $0.hasSuffix(".json") }),
              let kanji = names.first(where: { $0.hasPrefix("kanjidic2-en") && $0.hasSuffix(".json") }) else {
            throw StudySession.Failure(message: "The dictionary download had no word list in it.")
        }
        return (dir.appendingPathComponent(words), dir.appendingPathComponent(kanji))
        #else
        throw StudySession.Failure(message: "Study mode needs the Mac app.")
        #endif
    }
}

/// JMdict's part-of-speech tags in words. Tags not listed are shown as they
/// are; these are the ones manga dialogue is made of.
enum StudyTags {
    private static let names: [String: String] = [
        "n": "noun", "pn": "pronoun", "prt": "particle", "adv": "adverb", "exp": "expression",
        "int": "interjection", "conj": "conjunction", "ctr": "counter", "suf": "suffix", "pref": "prefix",
        "adj-i": "i-adjective", "adj-na": "na-adjective", "adj-no": "no-adjective", "adj-pn": "pre-noun",
        "aux-v": "auxiliary verb", "cop": "copula", "v1": "ichidan verb", "vs": "suru verb",
        "vs-i": "suru verb", "vk": "kuru verb", "vt": "transitive", "vi": "intransitive",
    ]

    static func name(_ tag: String) -> String {
        if let name = names[tag] { return name }
        if tag.hasPrefix("v5") { return "godan verb" }
        return tag
    }
}

/// The clicked bubble's sentence, split into words, and the card of the
/// word picked from it.
struct StudyWordsView: View {
    let text: String
    var before: [String] = []
    var after: [String] = []
    /// Where the bubble is, for the card saved from it.
    var source: String = ""
    var page: Int = 0
    @State private var tokens: [StudyToken] = []
    @State private var selected: Int?
    @State private var explanation: StudyExplanation?
    @State private var explaining = false
    @State private var explainError: String?
    private var words: StudyWords { StudyWords.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            listenButton("Listen to the sentence", text: text)
            if words.state == .ready, !tokens.isEmpty {
                SumiWrapHStack(spacing: 2, lineSpacing: 6) {
                    ForEach(Array(tokens.enumerated()), id: \.offset) { index, token in
                        tokenView(token, index: index)
                    }
                }
                explainSection
                if let selected, tokens.indices.contains(selected) {
                    card(tokens[selected])
                }
                Text("Dictionary: JMdict and KANJIDIC2, EDRDG, CC BY-SA 4.0")
                    .font(.system(size: 10))
                    .foregroundColor(SumiTheme.muted)
            } else {
                Text(text)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                switch words.state {
                case .preparing:
                    Text("Downloading the dictionary (13 MB) so words can be looked up. This happens once.")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                case .failed(let message):
                    Text("Word lookup is unavailable: \(message)")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.warning)
                default:
                    EmptyView()
                }
            }
        }
        .task(id: StudyLookupKey(text: text, ready: words.state == .ready)) {
            tokens = words.lookup(text)
            selected = tokens.firstIndex { $0.isWord && !$0.entries.isEmpty }
            explanation = StudyExplainer.cached(text)
        }
    }

    @ViewBuilder
    private var explainSection: some View {
        if let explanation {
            VStack(alignment: .leading, spacing: 8) {
                Text(explanation.translation)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if explanation.spansBubbles {
                    Text("The sentence runs across more than one bubble.")
                        .font(.system(size: 11.5))
                        .foregroundColor(SumiTheme.muted)
                }
                Text("Literally: \(explanation.literal)")
                    .font(.system(size: 12.5))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(explanation.points.enumerated()), id: \.offset) { _, point in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(point.phrase)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(SumiTheme.indigo)
                        Text(point.meaning)
                            .font(.system(size: 12.5))
                            .foregroundColor(SumiTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Explained on this Mac by Apple Intelligence, from the dictionary breakdown. It can be wrong.")
                    .font(.system(size: 10))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        } else if let reason = StudyExplainer.unavailableReason {
            Text("Sentence explanations: \(reason)")
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack(spacing: 8) {
                Button {
                    explaining = true
                    explainError = nil
                    Task {
                        do {
                            explanation = try await StudyExplainer.explain(line: text, before: before, after: after, tokens: tokens)
                        } catch {
                            AppLog.write("[study] explain failed: \(error)")
                            explainError = "Could not explain this line: \(error.localizedDescription)"
                        }
                        explaining = false
                    }
                } label: {
                    Text("Explain this sentence")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.indigo)
                }
                .buttonStyle(.sumiPressable)
                .disabled(explaining)
                if explaining { ProgressView().controlSize(.small) }
            }
            if let explainError {
                Text(explainError)
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A click on a word is the only signal that it was not known, so the
    /// click saves it. The word picked by default when the panel opens is not
    /// saved: nobody asked about it.
    private func save(_ token: StudyToken) {
        guard let entry = token.entries.first else { return }
        let meaning = entry.senses.prefix(2).map { $0.glosses.prefix(3).joined(separator: "; ") }.joined(separator: " / ")
        StudyDeck.shared.lookedUp(
            word: entry.word, reading: entry.reading, meaning: meaning,
            sentence: text, surface: token.surface, source: source, page: page
        )
    }

    @ViewBuilder
    private func deckLine(_ entry: StudyEntry) -> some View {
        let deck = StudyDeck.shared
        if deck.isSaved(entry.word, reading: entry.reading) {
            HStack(spacing: 12) {
                Text("Saved for review")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.success)
                Button { deck.markKnown(word: entry.word, reading: entry.reading) } label: {
                    Text("I know this")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SumiTheme.indigo)
                }
                .buttonStyle(.sumiPressable)
                .help("Remove it from the review deck and stop saving it")
            }
        }
    }

    private func listenButton(_ label: String, text: String) -> some View {
        Button { StudySpeech.shared.speak(text) } label: {
            Label(label, systemImage: "speaker.wave.2")
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SumiTheme.indigo)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .help(label)
    }

    @ViewBuilder
    private func tokenView(_ token: StudyToken, index: Int) -> some View {
        let label = Text(token.surface)
            .font(.system(size: 24, weight: .medium))
        if token.isWord {
            Button {
                selected = index
                save(token)
            } label: {
                label
                    .foregroundColor(token.entries.isEmpty ? SumiTheme.muted : (selected == index ? SumiTheme.indigo : SumiTheme.foreground))
                    .padding(.bottom, 2)
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(selected == index ? SumiTheme.indigo : SumiTheme.border)
                            .frame(height: selected == index ? 2 : 1)
                    }
            }
            .buttonStyle(.sumiPressable)
        } else {
            label.foregroundColor(SumiTheme.muted)
        }
    }

    @ViewBuilder
    private func card(_ token: StudyToken) -> some View {
        if let entry = token.entries.first {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(entry.word)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(SumiTheme.foreground)
                            .textSelection(.enabled)
                        // The reading, not the spelling: a voice reading the
                        // kanji alone guesses, and 方 comes out かた or ほう.
                        listenButton("Listen to the word", text: entry.reading)
                    }
                    if entry.reading != entry.word {
                        Text(entry.reading)
                            .font(.system(size: 14))
                            .foregroundColor(SumiTheme.muted)
                    }
                }
                deckLine(entry)
                if !token.steps.isEmpty {
                    Text(([entry.word] + token.steps).joined(separator: "  >  "))
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.indigo)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(entry.senses.prefix(4).enumerated()), id: \.offset) { number, sense in
                    VStack(alignment: .leading, spacing: 1) {
                        if !sense.partsOfSpeech.isEmpty {
                            Text(sense.partsOfSpeech.map(StudyTags.name).joined(separator: ", "))
                                .sumiTabularMono(size: 10.5)
                                .foregroundColor(SumiTheme.muted)
                        }
                        Text("\(number + 1). \(sense.glosses.joined(separator: "; "))")
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let kanji = words.kanji(in: entry.word)
                if !kanji.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(kanji, id: \.literal) { k in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(k.literal)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(SumiTheme.foreground)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(k.meanings.prefix(4).joined(separator: ", "))
                                        .font(.system(size: 12.5))
                                        .foregroundColor(SumiTheme.foreground)
                                    Text((k.onyomi + k.kunyomi).joined(separator: "  "))
                                        .font(.system(size: 11.5))
                                        .foregroundColor(SumiTheme.muted)
                                }
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                if token.entries.count > 1 {
                    Text("Also: " + token.entries.dropFirst().map { "\($0.word) (\($0.reading)) \($0.senses.first?.glosses.first ?? "")" }.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundColor(SumiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            Text("\(token.surface) is not in the dictionary.")
                .font(.system(size: 12.5))
                .foregroundColor(SumiTheme.muted)
        }
    }
}

private struct StudyLookupKey: Hashable {
    let text: String
    let ready: Bool
}
