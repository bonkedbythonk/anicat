import Foundation

/// Whether a stretch of an episode can hold an opening or an ending at all,
/// judged from its subtitles before any audio is compared.
///
/// A sung opening or ending runs about 90 seconds with nobody speaking, and
/// the subtitles show it as a hole in the dialogue. Watari-kun ep 24 had no
/// hole longer than 45 seconds anywhere in 23:40 (dialogue ran to 23:36): no
/// opening and no ending, and the search still fetched ep 25 to compare with.
/// This answers "is there a hole", so that fetch can be skipped; it never
/// says where an opening is.
///
/// Only a positive answer is acted on. Checked against the subtitle tracks of
/// 123 releases (AnimeTosho's extracted attachments, September 2026:
/// SubsPlease, Erai-raws, Kaleido, Commie, GJM, Vodes, VARYG, Yameii). Of the
/// 50 AniSkip openings and endings inside their window in that sample, none
/// came out `absent` but one: Solo Leveling 24's opening at 0-89 s, submitted
/// against a 1384 s file where this release runs 1420 s and talks at 36-52 s.
/// The other `absent` openings: Dan Da Dan 11 (AniSkip: 522 s, past the
/// window), Fate/strange Fake 13 (its opening's lines start at 1420 s), and
/// Watari-kun 24, Liar Game 01, Mushoku Tensei S2 23-24, with no AniSkip
/// entry and no 60 s pause anywhere in the file. Too little dialogue to judge
/// -- signs-only dub tracks, a style naming scheme this does not know, the
/// sparse talk around an ending -- is `unknown`, which changes nothing.
enum SubtitleGaps {
    enum Verdict: Equatable {
        /// Dialogue never stops long enough for a song.
        case absent
        case plausible
        /// No subtitles to judge by, or too few dialogue lines.
        case unknown
    }

    struct Line: Equatable {
        let start: Double
        let end: Double
        let style: String
        /// The event's text with its override tags, as the file has it.
        let text: String
    }

    /// Shorter than any TV-size opening or ending (85-95 s in the sample
    /// above, 91-100 s on Watari-kun), longer than the pauses in dialogue
    /// around a scene change: the longest in an episode without an opening
    /// was 44 s.
    static let songSeconds: Double = 60
    /// Below this many dialogue lines in a window the track is not the
    /// dialogue track: a dub release's "Signs" track had 0-5 in 8 minutes,
    /// a full track 47-167.
    static let minimumLines = 20

    static func verdict(dialogue: [(start: Double, end: Double)], from low: Double, to high: Double) -> (verdict: Verdict, longestGap: Double?) {
        let spans = dialogue
            .filter { $0.end > low && $0.start < high }
            .map { (start: max($0.start, low), end: min($0.end, high)) }
            .sorted { $0.start < $1.start }
        guard spans.count >= minimumLines else { return (.unknown, nil) }
        var longest = 0.0
        var covered = low
        for span in spans {
            longest = max(longest, span.start - covered)
            covered = max(covered, span.end)
        }
        // The edges count: an opening that starts the episode is a hole from
        // the window's start to the first line.
        longest = max(longest, high - covered)
        return (longest >= songSeconds ? .plausible : .absent, longest)
    }

    /// The spans of the lines that are somebody talking.
    ///
    /// A line is dropped when any of these says it is something else:
    /// - its style is not a dialogue style (`isDialogueStyle`);
    /// - it carries karaoke timing or a music note, or is a drawing;
    /// - all of its text is italic. Crunchyroll sets opening lyrics in the
    ///   dialogue styles, italic: One Piece Log's opening sits in "Default"
    ///   and "On Top", which read as 100% dialogue and called six episodes
    ///   with an opening "absent". Italic dialogue (thoughts, a voice off)
    ///   is lost with it, which only ever makes a hole longer;
    /// - another line starts and ends at the same moment in another style or
    ///   with other words: romaji over its translation, the same song again.
    static func dialogue(_ lines: [Line], italicStyles: Set<String>) -> [(start: Double, end: Double)] {
        let kept = lines.filter { line in
            guard isDialogueStyle(line.style) else { return false }
            let text = line.text
            if text.range(of: #"\\(k|kf|ko|K)\d"#, options: .regularExpression) != nil { return false }
            if text.contains("♪") { return false }
            if text.range(of: #"\\p[1-9]"#, options: .regularExpression) != nil { return false }
            guard !plainText(text).isEmpty else { return false }
            return !isWhollyItalic(text, styleItalic: italicStyles.contains(line.style))
        }
        var byTiming: [String: Set<String>] = [:]
        func timing(_ line: Line) -> String { String(format: "%.1f-%.1f", line.start, line.end) }
        for line in kept { byTiming[timing(line), default: []].insert(line.style + "\u{1}" + plainText(line.text)) }
        return kept
            .filter { (byTiming[timing($0)]?.count ?? 0) < 2 }
            .map { (start: $0.start, end: $0.end) }
    }

    /// Words a dialogue style's name is made of, in the naming schemes seen:
    /// "Default", "Main", "DefaultItalics", "On Top", "Flashback - Italics",
    /// "GJM_Main_1080p", "Irumakun - Default".
    private static let dialogueWords: Set<String> = [
        "default", "main", "dialogue", "dialog", "italic", "italics", "flashback", "top", "ontop",
        "narration", "narrator", "thought", "thoughts", "overlap", "alt", "internal",
    ]
    /// Words that make a style something else even beside a dialogue word:
    /// "Default - Signs", "Main Song", "Signs_Title".
    private static let otherWords: Set<String> = [
        "sign", "signs", "song", "songs", "kara", "karaoke", "title", "credits", "credit", "insert",
        "lyrics", "romaji", "kanji", "opening", "ending", "ts", "os",
    ]

    static func isDialogueStyle(_ style: String) -> Bool {
        let words = styleWords(style)
        // "OP", "ED1", "OPv2", "OP1R", "ED1 - ROM"
        if words.contains(where: { otherWords.contains($0) || $0.range(of: #"^(op|ed)(\d+|v\d+)?[a-z]?$"#, options: .regularExpression) != nil }) {
            return false
        }
        return words.contains(where: dialogueWords.contains)
    }

    /// "DefaultItalicsTop" -> default, italics, top.
    static func styleWords(_ style: String) -> [String] {
        let split = style.replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
        return split.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// The styles whose `Italic` field is set, from a script's header.
    static func italicStyles(header: String) -> Set<String> {
        var format: [String]?
        var italic = Set<String>()
        for raw in header.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Format:"), format == nil, line.contains("Italic") {
                format = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            } else if line.hasPrefix("Style:"), let format {
                let fields = line.dropFirst(6).split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                guard let name = format.firstIndex(of: "Name"), let flag = format.firstIndex(of: "Italic"),
                      fields.indices.contains(name), fields.indices.contains(flag) else { continue }
                if fields[flag] == "-1" || fields[flag] == "1" { italic.insert(fields[name]) }
            }
        }
        return italic
    }

    static func plainText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\\[Nnh]"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Every visible character is set in italic, by the style or by `\i1`.
    /// A bare `\i` resets to the style's own setting.
    static func isWhollyItalic(_ text: String, styleItalic: Bool) -> Bool {
        var italic = styleItalic
        var sawText = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character == "{", let close = text[index...].firstIndex(of: "}") {
                let block = String(text[index...close])
                let pattern = try! NSRegularExpression(pattern: #"\\i(\d?)(?![a-z])"#)
                for match in pattern.matches(in: block, range: NSRange(block.startIndex..., in: block)) {
                    let digit = Range(match.range(at: 1), in: block).map { String(block[$0]) } ?? ""
                    italic = digit.isEmpty ? styleItalic : digit == "1"
                }
                index = text.index(after: close)
                continue
            }
            if character == "\\", let next = text.index(index, offsetBy: 1, limitedBy: text.endIndex),
               next < text.endIndex, "Nnh".contains(text[next]) {
                index = text.index(after: next)
                continue
            }
            if !character.isWhitespace {
                sawText = true
                if !italic { return false }
            }
            index = text.index(after: index)
        }
        return sawText
    }
}
