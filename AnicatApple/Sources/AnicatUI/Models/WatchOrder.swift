import Foundation

/// Puts a title and its relations into the order someone would watch them
/// in, for the Related tab's Timeline.
///
/// Pure and self-contained on purpose: the ordering is the whole feature,
/// and it is the part that has to be provable without a running AniList
/// behind it.
public enum WatchOrder {
    /// One row of the timeline: a relation, or the title being viewed.
    ///
    /// `year`, `season`, `episodeCount` and `listStatus` are all optional
    /// because `FfiRelation` carries none of them — it has only the id,
    /// relation type, title, format, cover, airing status and score. The
    /// caller fills what it can from elsewhere (the open title knows its
    /// own year; a relation the viewer has opened before has a detail
    /// snapshot on disk) and leaves the rest nil, which is the ordinary
    /// case rather than the exception.
    public struct Entry: Identifiable, Equatable, Sendable {
        public let id: Int64
        public let title: String
        /// AniList's own vocabulary — `PREQUEL`, `SEQUEL`, `SIDE_STORY` and
        /// the rest. `nil` for the title being viewed, which is not related
        /// to itself.
        public let relationType: String?
        public let format: String?
        public let coverURL: URL?
        public let year: Int?
        /// `WINTER`/`SPRING`/`SUMMER`/`FALL`. Nothing in the FFI surfaces
        /// this today, so it is nil at runtime; the ordering handles it so
        /// that a source for it changes only where entries are built.
        public let season: String?
        public let episodeCount: Int?
        /// The viewer's own list status, when it is known.
        public let listStatus: String?
        public let isCurrent: Bool

        public init(
            id: Int64,
            title: String,
            relationType: String?,
            format: String? = nil,
            coverURL: URL? = nil,
            year: Int? = nil,
            season: String? = nil,
            episodeCount: Int? = nil,
            listStatus: String? = nil,
            isCurrent: Bool = false
        ) {
            self.id = id
            self.title = title
            self.relationType = relationType
            self.format = format
            self.coverURL = coverURL
            self.year = year
            self.season = season
            self.episodeCount = episodeCount
            self.listStatus = listStatus
            self.isCurrent = isCurrent
        }
    }

    /// The three bands, in the order they are shown.
    enum Tier: Int, Comparable {
        /// The main line: what came before this title, this title, what
        /// came after.
        case mainLine = 0
        /// Side stories, spin-offs, alternative versions and adaptations —
        /// watchable, but not the spine.
        case aside = 1
        /// Shared characters and anything AniList has no better word for.
        case tangent = 2

        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// Where a relation sits within the main line. This is what makes the
    /// timeline readable with no dates at all: `FfiRelation` has no start
    /// date, so at runtime a prequel and a sequel are usually both undated,
    /// and ordering the main line by date alone would sort them by the
    /// tiebreaker rather than by the story.
    private enum MainLineRank: Int {
        case before = 0
        case current = 1
        case after = 2
    }

    private static let beforeTypes: Set<String> = ["PREQUEL", "PARENT", "SOURCE"]
    private static let afterTypes: Set<String> = ["SEQUEL"]
    private static let asideTypes: Set<String> = [
        "SIDE_STORY", "SPIN_OFF", "ALTERNATIVE", "ALTERNATIVE_VERSION",
        "ADAPTATION", "SUMMARY", "COMPILATION", "CONTAINS"
    ]

    /// The relations and the title itself, in watch order.
    ///
    /// Ordering, most significant first: the tier, then position in the
    /// main line (prequels, this title, sequels), then start year, then
    /// season, then title. Entries with no year sort after entries that
    /// have one *within* their rank — never across ranks, or an undated
    /// prequel would land after the dated title it precedes.
    public static func sort(relations: [Entry], current: Entry) -> [Entry] {
        let entries = relations + [current]
        return entries.sorted { lhs, rhs in
            let lhsTier = tier(for: lhs)
            let rhsTier = tier(for: rhs)
            if lhsTier != rhsTier { return lhsTier < rhsTier }

            if lhsTier == .mainLine {
                let lhsRank = mainLineRank(for: lhs).rawValue
                let rhsRank = mainLineRank(for: rhs).rawValue
                if lhsRank != rhsRank { return lhsRank < rhsRank }
            }

            switch (lhs.year, rhs.year) {
            case let (l?, r?) where l != r:
                return l < r
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                break
            }

            let lhsSeason = seasonRank(lhs.season)
            let rhsSeason = seasonRank(rhs.season)
            if lhsSeason != rhsSeason { return lhsSeason < rhsSeason }

            // Last resort, so the order is total: two undated side stories
            // must not swap places between renders of the same list.
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }

    static func tier(for entry: Entry) -> Tier {
        if entry.isCurrent { return .mainLine }
        guard let type = entry.relationType?.uppercased() else { return .tangent }
        if beforeTypes.contains(type) || afterTypes.contains(type) { return .mainLine }
        if asideTypes.contains(type) { return .aside }
        return .tangent
    }

    private static func mainLineRank(for entry: Entry) -> MainLineRank {
        if entry.isCurrent { return .current }
        guard let type = entry.relationType?.uppercased() else { return .current }
        if beforeTypes.contains(type) { return .before }
        if afterTypes.contains(type) { return .after }
        return .current
    }

    /// Broadcast order within a year. An unknown season sorts last, the
    /// same way an unknown year does.
    private static func seasonRank(_ season: String?) -> Int {
        switch season?.uppercased() {
        case "WINTER": return 0
        case "SPRING": return 1
        case "SUMMER": return 2
        case "FALL", "AUTUMN": return 3
        default: return 4
        }
    }

    /// The rows grouped for display, in the order `sort` produced. Entries
    /// with no year fall into one group per run, not one group overall.
    public struct YearGroup: Identifiable, Equatable, Sendable {
        /// Position in the list, and the identity SwiftUI sees. Not the
        /// year: the sort is tier-first, so one year can legitimately open
        /// two groups (a 2013 sequel in the main line, a 2013 side story
        /// below it) and two rows sharing an `id` is undefined behavior.
        public let index: Int
        public let year: Int?
        public let entries: [Entry]
        public var id: Int { index }

        /// What the timeline's rail is labelled with.
        public var label: String { year.map(String.init) ?? "Undated" }
    }

    /// Groups an already-sorted list by year without reordering it, so a
    /// year's heading appears where the sort put that year's first entry.
    public static func grouped(_ entries: [Entry]) -> [YearGroup] {
        var groups: [YearGroup] = []
        for entry in entries {
            if let last = groups.last, last.year == entry.year {
                groups[groups.count - 1] = YearGroup(
                    index: last.index,
                    year: last.year,
                    entries: last.entries + [entry]
                )
            } else {
                groups.append(YearGroup(index: groups.count, year: entry.year, entries: [entry]))
            }
        }
        return groups
    }
}
