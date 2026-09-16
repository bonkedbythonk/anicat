import Foundation

/// One entry of mpv's `chapter-list`. Matroska releases from most fansub
/// groups carry these, and where they exist they beat AniSkip outright:
/// they were written against *this* encode, while an AniSkip submission is
/// timed against whichever release the submitter happened to watch.
public struct PlayerChapter: Sendable, Equatable, Identifiable {
    public var id: Double { time }
    public let title: String
    public let time: Double

    public init(title: String, time: Double) {
        self.title = title
        self.time = time
    }
}

/// What a skippable stretch of an episode is.
public enum SkipKind: String, Sendable, Equatable {
    case opening
    case ending
    case preview

    /// The word the Skip pill puts after "Skip".
    public var noun: String {
        switch self {
        case .opening: return "Opening"
        case .ending: return "Ending"
        case .preview: return "Preview"
        }
    }

    /// Which kind, if any, a chapter title names.
    ///
    /// Substring matching is not enough and was the first thing tried:
    /// "Opening Act" (a real chapter title on episode-length OVAs) contains
    /// "opening" and would skip the first three minutes of the episode. So
    /// the title has to be *nothing but* the marker — every token has to be
    /// either a marker word, a bare index ("ED 2", "OP1"), or one of the
    /// decorations groups habitually append ("Ending Credits", "Opening
    /// Theme", "Next Episode Preview"). Anything else disqualifies it.
    public static func from(chapterTitle: String) -> SkipKind? {
        let tokens = Self.tokens(of: chapterTitle)
        guard !tokens.isEmpty else { return nil }
        var found: Set<SkipKind> = []
        for token in tokens {
            if let kind = markers[token] {
                found.insert(kind)
            } else if !filler.contains(token) {
                return nil
            }
        }
        // Two different markers in one title ("OP/ED medley") name no single
        // window to jump to the end of.
        guard found.count == 1 else { return nil }
        return found.first
    }

    /// Lowercased alphanumeric words with any trailing index digits split
    /// off, so "OP1" and "ED 2" both reduce to the bare marker. Purely
    /// numeric tokens drop out entirely; they are the index, never the name.
    static func tokens(of title: String) -> [String] {
        title
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map { String($0.prefix(while: { $0.isLetter })) }
            .filter { !$0.isEmpty }
    }

    /// Whether the title names the opening in a word that can only mean the
    /// song: "OP", "NCOP", "Opening". "Intro" is not in this set, see
    /// `isIntroAlias`.
    public static func namesOpeningExplicitly(_ chapterTitle: String) -> Bool {
        tokens(of: chapterTitle).contains { explicitOpening.contains($0) }
    }

    /// "Intro" is two different chapters in the wild: some groups label the
    /// opening song with it, others the cold open before the song, the
    /// episode's first scene. Auto-skip treated both as the song and jumped
    /// the first minutes of story on releases chaptered "Intro, OP, Part A".
    /// A title that is only this alias is still an opening when nothing
    /// else says otherwise, but `PlayerChapters.skipWindows` drops it when
    /// the same file also has an explicit "OP", and the controller drops it
    /// when AniSkip places the opening somewhere else.
    public static func isIntroAlias(_ chapterTitle: String) -> Bool {
        from(chapterTitle: chapterTitle) == .opening && !namesOpeningExplicitly(chapterTitle)
    }

    private static let explicitOpening: Set<String> = ["op", "ncop", "opening", "openings"]

    /// "Avant" is not here on purpose: it is the Japanese TV term for the
    /// scene before the opening, always story, never the song.
    private static let markers: [String: SkipKind] = [
        "op": .opening, "ncop": .opening, "opening": .opening, "openings": .opening,
        "intro": .opening, "introduction": .opening,
        "ed": .ending, "nced": .ending, "ending": .ending, "endings": .ending,
        "outro": .ending,
        "preview": .preview,
    ]

    /// Words that may sit beside a marker without changing what it names.
    private static let filler: Set<String> = [
        "the", "a", "and", "credits", "song", "theme", "themes", "sequence",
        "titles", "title", "tv", "size", "version", "next", "episode", "ep",
        "start", "ends", "end", "skip",
    ]
}

/// A stretch of the episode the viewer can jump over, plus the name to put
/// on the control that does it.
public struct SkipWindow: Sendable, Equatable, Identifiable {
    public var id: Double { start }
    public let start: Double
    public let end: Double
    public let kind: SkipKind
    /// The chapter's own title where one named this window, so auto-skip can
    /// flash what it just skipped rather than a generic word. Empty for a
    /// window that came from AniSkip, which carries no names.
    public let chapterTitle: String

    public init(start: Double, end: Double, kind: SkipKind, chapterTitle: String = "") {
        self.start = start
        self.end = end
        self.kind = kind
        self.chapterTitle = chapterTitle
    }

    public func contains(_ time: Double) -> Bool {
        time >= start && time < end
    }

    /// True from `lead` seconds before the window until it ends — what the
    /// Skip pill is visible for. Distinct from `contains`, which is what
    /// auto-skip acts on: a pill that appears the instant the opening starts
    /// is a pill the viewer sees only after the thing they wanted to skip
    /// has begun.
    public func isPending(at time: Double, lead: Double = 2) -> Bool {
        time >= start - lead && time < end
    }

    public var label: String { "Skip \(kind.noun)" }

    /// What auto-skip flashes. The chapter's own title when it has one worth
    /// showing, since that is what the release actually calls this stretch.
    public var flashLabel: String {
        let trimmed = chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.noun : trimmed
    }
}

public enum PlayerChapters {
    /// The shortest stretch worth offering a skip for. Some releases place a
    /// bare marker chapter ("Opening" with the next chapter half a second
    /// later) to tag a moment rather than to bound a section; jumping over
    /// that is a no-op with a button attached.
    static let minimumWindowSeconds: Double = 5

    /// Turns a chapter list into the windows it names. A window runs from
    /// its chapter to the next one, or to the end of the file for the last
    /// chapter — which is why `duration` is needed and why a file whose
    /// duration mpv has not reported yet yields nothing for a trailing
    /// "Preview".
    public static func skipWindows(chapters: [PlayerChapter], duration: Double?) -> [SkipWindow] {
        let sorted = chapters.sorted { $0.time < $1.time }
        // With an explicit "OP" in the same file, an "Intro" chapter is
        // the cold open, not a second opening.
        let hasExplicitOpening = sorted.contains { SkipKind.namesOpeningExplicitly($0.title) }
        var windows: [SkipWindow] = []
        for (index, chapter) in sorted.enumerated() {
            guard let kind = SkipKind.from(chapterTitle: chapter.title) else { continue }
            if kind == .opening, hasExplicitOpening, SkipKind.isIntroAlias(chapter.title) { continue }
            let next = sorted.indices.contains(index + 1) ? sorted[index + 1].time : duration
            guard let end = next, end - chapter.time >= minimumWindowSeconds else { continue }
            windows.append(SkipWindow(start: chapter.time, end: end, kind: kind, chapterTitle: chapter.title))
        }
        return windows
    }

    /// The chapter covering `time`, for the seek bar's hover tooltip.
    public static func chapter(at time: Double, in chapters: [PlayerChapter]) -> PlayerChapter? {
        chapters
            .filter { $0.time <= time }
            .max { $0.time < $1.time }
    }
}
