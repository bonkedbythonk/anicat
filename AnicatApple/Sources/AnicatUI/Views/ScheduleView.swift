import SwiftUI

public struct ScheduleView: View {
    public struct ScheduleItem: Identifiable, Sendable {
        public let id: Int64
        public let title: String
        public let coverImageURL: URL?
        public let episodeNumber: Int
        public let airingTimeText: String
        public let countdownText: String
        public let dayGroup: String // e.g. "Monday, September 4"
        public let airingAt: Int64 // unix seconds; dayGroup is display-only and not sortable
        public let isWatching: Bool

        public init(
            id: Int64,
            title: String,
            coverImageURL: URL?,
            episodeNumber: Int,
            airingTimeText: String,
            countdownText: String,
            dayGroup: String,
            airingAt: Int64,
            isWatching: Bool = false
        ) {
            self.id = id
            self.title = title
            self.coverImageURL = coverImageURL
            self.episodeNumber = episodeNumber
            self.airingTimeText = airingTimeText
            self.countdownText = countdownText
            self.dayGroup = dayGroup
            self.airingAt = airingAt
            self.isWatching = isWatching
        }
    }

    public let items: [ScheduleItem]
    public let onSelectItem: (ScheduleItem) -> Void

    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @State private var watchingOnly: Bool = false

    public init(
        items: [ScheduleItem],
        onSelectItem: @escaping (ScheduleItem) -> Void
    ) {
        self.items = items
        self.onSelectItem = onSelectItem
    }

    private var groupedItems: [(day: String, items: [ScheduleItem])] {
        let filtered = items.filter { !watchingOnly || $0.isWatching }
        let grouped = Dictionary(grouping: filtered, by: { $0.dayGroup })
        return grouped.map { (day: $0.key, items: $0.value) }
            .sorted(by: { ($0.items.map(\.airingAt).min() ?? 0) < ($1.items.map(\.airingAt).min() ?? 0) })
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: SumiTheme.spaceLg) {
                // Header Row
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Airing Schedule")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(SumiTheme.foreground)
                        Text("Keep track of the latest releases and upcoming episodes")
                            .font(.system(size: 14))
                            .foregroundColor(SumiTheme.muted)
                    }

                    Spacer()

                    // Global vs Watching Only Toggle
                    HStack(spacing: 2) {
                        Button(action: {
                            withAnimation(.snappy) {
                                watchingOnly = false
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                Text("Global")
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(!watchingOnly ? SumiTheme.foreground : SumiTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(!watchingOnly ? SumiTheme.card : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button(action: {
                            withAnimation(.snappy) {
                                watchingOnly = true
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "tv")
                                Text("Watching")
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(watchingOnly ? SumiTheme.foreground : SumiTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(watchingOnly ? SumiTheme.card : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .animation(.snappy, value: watchingOnly)
                    .padding(3)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                }
                .padding(.horizontal, SumiTheme.spaceMd)

                Group {
                    if groupedItems.isEmpty {
                        SumiEmptyState(
                            headline: watchingOnly ? "No watching shows airing soon" : "No airing shows found",
                            detail: watchingOnly ? "Shows you are currently watching with upcoming episodes will appear here." : "Airing schedules will appear here for ongoing shows."
                        )
                        .padding(.top, 40)
                    } else {
                        // Day Groups
                        ForEach(groupedItems, id: \.day) { group in
                            VStack(alignment: .leading, spacing: SumiTheme.spaceMd) {
                                Text(group.day.uppercased())
                                    .sumiTabularMono(size: 13, weight: .bold)
                                    .foregroundColor(SumiTheme.indigo)
                                    .padding(.horizontal, SumiTheme.spaceMd)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                                    ForEach(group.items) { item in
                                        Button(action: { onSelectItem(item) }) {
                                            HStack(spacing: 12) {
                                                // Poster Thumbnail
                                                CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 150) { img in
                                                    img.resizable().aspectRatio(contentMode: .fill)
                                                } placeholder: {
                                                    Rectangle().fill(SumiTheme.card)
                                                }
                                                .frame(width: 55, height: 75)
                                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                                                // Meta
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(item.title)
                                                        .font(.system(size: 13.5, weight: .semibold))
                                                        .foregroundColor(SumiTheme.foreground)
                                                        .lineLimit(2)

                                                    HStack(spacing: 8) {
                                                        Text("Ep \(item.episodeNumber)")
                                                            .sumiTabularMono(size: 11, weight: .medium)
                                                            .foregroundColor(SumiTheme.indigo)

                                                        Text(item.airingAt > 0 ? SumiTheme.formatTime(Date(timeIntervalSince1970: TimeInterval(item.airingAt)), timeFormat: timeFormat) : item.airingTimeText)
                                                            .sumiTabularMono(size: 11)
                                                            .foregroundColor(SumiTheme.muted)
                                                    }

                                                    Text(item.countdownText)
                                                        .sumiTabularMono(size: 10.5)
                                                        .foregroundColor(SumiTheme.muted.opacity(0.8))
                                                }
                                                Spacer()
                                            }
                                            .padding(8)
                                            .background(SumiTheme.card)
                                            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                                            .overlay(
                                                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                                                    .stroke(SumiTheme.border, lineWidth: 1)
                                            )
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                                .padding(.horizontal, SumiTheme.spaceMd)
                            }
                        }
                    }
                }
                .animation(.smooth, value: watchingOnly)
            }
            .padding(.vertical, SumiTheme.spaceLg)
        }
        .background(SumiTheme.background)
    }
}
