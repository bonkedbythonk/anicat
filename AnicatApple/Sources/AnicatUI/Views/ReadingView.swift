import SwiftUI

/// Manga and Light Novels are the same page with different sources: a resume
/// queue at the top, then a shelf of what you are reading and a shelf of what
/// is trending. Light novels are AniList's `NOVEL` format under the `MANGA`
/// type, not a type of their own, which is why one view serves both.
public struct ReadingView: View {
    public struct Config: Sendable {
        let title: String
        let unit: String
        let browseLabel: String
        let readingShelf: String
        let trendingShelf: String

        public static let manga = Config(
            title: "Manga",
            unit: "CH",
            browseLabel: "Browse all manga",
            readingShelf: "Reading",
            trendingShelf: "Trending manga"
        )
        public static let novels = Config(
            title: "Light Novels",
            unit: "CH",
            browseLabel: "Browse all novels",
            readingShelf: "Reading",
            trendingShelf: "Trending novels"
        )
    }

    let config: Config
    let reading: [MediaCard.Item]
    let trending: [MediaCard.Item]
    let isSignedIn: Bool
    let onSelect: (MediaCard.Item) -> Void
    let onRead: (MediaCard.Item) -> Void
    let onBrowse: () -> Void

    public init(
        config: Config,
        reading: [MediaCard.Item],
        trending: [MediaCard.Item],
        isSignedIn: Bool,
        onSelect: @escaping (MediaCard.Item) -> Void,
        onRead: @escaping (MediaCard.Item) -> Void,
        onBrowse: @escaping () -> Void
    ) {
        self.config = config
        self.reading = reading
        self.trending = trending
        self.isSignedIn = isSignedIn
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

            if !isSignedIn && reading.isEmpty && trending.isEmpty {
                SumiEmptyState(
                    headline: "Nothing here yet",
                    detail: "Connect AniList in Settings to see what you are reading."
                )
            }

            if !queue.isEmpty {
                UpNextQueueView(items: queue, onSelect: { entry in
                    if let item = reading.first(where: { $0.id == entry.id }) { onSelect(item) }
                }, onPlay: { entry in
                    if let item = reading.first(where: { $0.id == entry.id }) { onRead(item) }
                })
            }

            if !reading.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SumiSectionHeader(config.readingShelf, trailing: "\(reading.count) titles")
                    shelf(reading)
                }
                .padding(.top, 20)
            }

            if !trending.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SumiSectionHeader(config.trendingShelf)
                    shelf(trending)
                }
                .padding(.top, 20)
            }
        }
    }

    private func shelf(_ items: [MediaCard.Item]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 16) {
                ForEach(items) { item in
                    MediaCard(item: item) { onSelect(item) }
                        .frame(width: 180)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
