import SwiftUI

/// Manga and Light Novels are the same page with different sources: a resume
/// queue at the top, then a shelf of what you are reading, a shelf of what you
/// have planned, and a shelf of what is trending. Light novels are AniList's
/// `NOVEL` format under the `MANGA` type, not a type of their own, which is
/// why one view serves both.
public struct ReadingView: View {
    public struct Config: Sendable {
        let title: String
        let unit: String
        let browseLabel: String
        let readingShelf: String
        let planningShelf: String
        let trendingShelf: String

        public static let manga = Config(
            title: "Manga",
            unit: "CH",
            browseLabel: "Browse all manga",
            readingShelf: "Reading",
            planningShelf: "Planning",
            trendingShelf: "Trending manga"
        )
        public static let novels = Config(
            title: "Light Novels",
            unit: "CH",
            browseLabel: "Browse all novels",
            readingShelf: "Reading",
            planningShelf: "Planning",
            trendingShelf: "Trending novels"
        )
    }

    let config: Config
    let reading: [MediaCard.Item]
    /// The AniList `PLANNING` bucket for this type. Empty rather than absent
    /// when signed out, so the shelf simply does not render.
    let planning: [MediaCard.Item]
    let trending: [MediaCard.Item]
    let isSignedIn: Bool
    let namespace: Namespace.ID?
    // Which card (if any) is the poster-morph source, as "<shelfKey>:<id>" —
    // the same title can be in the resume queue, the reading shelf, and the
    // trending shelf all at once, so a bare id can't say which one a tap
    // came from — see `AppModel.openingDetailSourceKey`.
    let openingSourceKey: String?
    // 2nd arg is the source key ("reading-queue:<id>", "reading-shelf:<id>",
    // "reading-planning:<id>" or "reading-trending:<id>") — this view knows
    // which shelf a tap came from, the caller doesn't.
    let onSelect: (MediaCard.Item, String) -> Void
    let onRead: (MediaCard.Item, String) -> Void
    let onBrowse: () -> Void

    public init(
        config: Config,
        reading: [MediaCard.Item],
        planning: [MediaCard.Item] = [],
        trending: [MediaCard.Item],
        isSignedIn: Bool,
        namespace: Namespace.ID? = nil,
        openingSourceKey: String? = nil,
        onSelect: @escaping (MediaCard.Item, String) -> Void,
        onRead: @escaping (MediaCard.Item, String) -> Void,
        onBrowse: @escaping () -> Void
    ) {
        self.config = config
        self.reading = reading
        self.planning = planning
        self.trending = trending
        self.isSignedIn = isSignedIn
        self.namespace = namespace
        self.openingSourceKey = openingSourceKey
        self.onSelect = onSelect
        self.onRead = onRead
        self.onBrowse = onBrowse
    }

    /// Only titles with progress belong in the resume queue. A "reading" entry
    /// at chapter 0 has not been started, and putting it here would offer to
    /// continue something that never began.
    private var queue: [UpNextQueueView.QueueEntry] {
        reading.compactMap { item in
            let progress = item.progress ?? 0
            let total = item.totalEpisodesOrChapters ?? 0
            return UpNextQueueView.QueueEntry(
                id: item.id,
                title: item.title,
                thumbnailURL: item.coverImageURL,
                nextEpisodeOrChapter: progress + 1,
                totalCount: total,
                progressPercent: total > 0 ? Double(progress) / Double(total) * 100 : 0,
                watchedTimeAgo: nil,
                hasNewEpisode: false,
                unit: config.unit
            )
        }
    }

    private var subtitle: String {
        let started = reading.filter { ($0.progress ?? 0) > 0 }.count
        return "\(started) in progress · \(reading.count) reading"
    }

    public var body: some View {
        SumiPage {
            SumiPageHeader(title: config.title, subtitle: subtitle) {
                SumiOutlineButton(config.browseLabel, systemImage: "arrow.right", action: onBrowse)
            }

            if !isSignedIn && reading.isEmpty && planning.isEmpty && trending.isEmpty {
                SumiEmptyState(
                    headline: "Nothing here yet",
                    detail: "Connect AniList in Settings to see what you are reading."
                )
            }

            if !queue.isEmpty {
                UpNextQueueView(
                    items: queue,
                    namespace: namespace,
                    openingSourceKey: openingSourceKey,
                    shelfKey: "reading-queue",
                    onSelect: { entry in
                        if let item = reading.first(where: { $0.id == entry.id }) { onSelect(item, "reading-queue:\(entry.id)") }
                    },
                    onPlay: { entry in
                        if let item = reading.first(where: { $0.id == entry.id }) { onRead(item, "reading-queue:\(entry.id)") }
                    }
                )
            }

            if !reading.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SumiSectionHeader(config.readingShelf, trailing: "\(reading.count) titles")
                    shelf(reading, shelfKey: "reading-shelf")
                }
                .padding(.top, 20)
            }

            // Between Reading and Trending on purpose: what you picked out
            // yourself but have not started is closer to what you are reading
            // than a global trending list is.
            if !planning.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SumiSectionHeader(config.planningShelf, trailing: "\(planning.count) titles")
                    shelf(planning, shelfKey: "reading-planning")
                }
                .padding(.top, 20)
            }

            if !trending.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SumiSectionHeader(config.trendingShelf)
                    shelf(trending, shelfKey: "reading-trending")
                }
                .padding(.top, 20)
            }
        }
    }

    private func shelf(_ items: [MediaCard.Item], shelfKey: String) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items) { item in
                    MediaCard(
                        item: item,
                        namespace: openingSourceKey == "\(shelfKey):\(item.id)" ? namespace : nil
                    ) { onSelect(item, "\(shelfKey):\(item.id)") }
                        .frame(width: 180)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
