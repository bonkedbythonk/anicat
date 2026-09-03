import SwiftUI

public struct UpNextQueueView: View {
    public struct QueueEntry: Identifiable, Sendable {
        public let id: Int64
        public let title: String
        public let thumbnailURL: URL?
        public let nextEpisodeOrChapter: Int
        public let totalCount: Int
        public let progressPercent: Double // 0 to 100
        public let watchedTimeAgo: String?
        public let hasNewEpisode: Bool
        public let unit: String // "EP" or "CH"

        public init(
            id: Int64,
            title: String,
            thumbnailURL: URL?,
            nextEpisodeOrChapter: Int,
            totalCount: Int = 0,
            progressPercent: Double = 0,
            watchedTimeAgo: String? = nil,
            hasNewEpisode: Bool = false,
            unit: String = "EP"
        ) {
            self.id = id
            self.title = title
            self.thumbnailURL = thumbnailURL
            self.nextEpisodeOrChapter = nextEpisodeOrChapter
            self.totalCount = totalCount
            self.progressPercent = progressPercent
            self.watchedTimeAgo = watchedTimeAgo
            self.hasNewEpisode = hasNewEpisode
            self.unit = unit
        }
    }

    public let items: [QueueEntry]
    public let onSelect: (QueueEntry) -> Void
    public let onPlay: (QueueEntry) -> Void

    public init(
        items: [QueueEntry],
        onSelect: @escaping (QueueEntry) -> Void,
        onPlay: @escaping (QueueEntry) -> Void
    ) {
        self.items = items
        self.onSelect = onSelect
        self.onPlay = onPlay
    }

    public var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, entry in
                RowView(
                    entry: entry,
                    isFirst: index == 0,
                    onSelect: { onSelect(entry) },
                    onPlay: { onPlay(entry) }
                )

                if index < items.count - 1 {
                    Divider()
                        .background(SumiTheme.border)
                }
            }
        }
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private struct RowView: View {
        let entry: QueueEntry
        let isFirst: Bool
        let onSelect: () -> Void
        let onPlay: () -> Void

        @State private var isHovered = false

        var body: some View {
            HStack(spacing: 16) {
                // Clickable Body: Thumbnail + Text
                Button(action: onSelect) {
                    HStack(spacing: 16) {
                        // 104x60 Thumbnail
                        ZStack {
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                .fill(SumiTheme.background)
                                .frame(width: 104, height: 60)

                            AsyncImage(url: entry.thumbnailURL) { phase in
                                if let image = phase.image {
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fill)
                                        .frame(width: 104, height: 60)
                                        .clipped()
                                } else {
                                    Rectangle()
                                        .fill(SumiTheme.background)
                                        .overlay(
                                            Image(systemName: "photo")
                                                .font(.system(size: 16))
                                                .foregroundColor(SumiTheme.muted)
                                        )
                                }
                            }
                        }
                        .frame(width: 104, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                        // Info Column
                        VStack(alignment: .leading, spacing: 4) {
                            Text(entry.title)
                                .font(.system(size: isFirst ? 15 : 13.5, weight: isFirst ? .semibold : .medium))
                                .foregroundColor(SumiTheme.foreground)
                                .lineLimit(1)

                            HStack(spacing: 16) {
                                Text("\(entry.unit) \(entry.nextEpisodeOrChapter)\(entry.totalCount > 0 ? " / \(entry.totalCount)" : "")")

                                if entry.hasNewEpisode {
                                    Text(entry.unit == "CH" ? "New chapter out" : "New episode out")
                                        .foregroundColor(SumiTheme.indigo)
                                        .fontWeight(.semibold)
                                } else if let watched = entry.watchedTimeAgo {
                                    Text("Watched \(watched)")
                                }
                            }
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)

                            // 2px Progress Bar
                            if entry.totalCount > 0 {
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule()
                                            .fill(SumiTheme.foreground.opacity(0.1))
                                        Capsule()
                                            .fill(SumiTheme.indigo)
                                            .frame(width: min(geo.size.width * CGFloat(entry.progressPercent / 100.0), geo.size.width))
                                    }
                                }
                                .frame(maxWidth: 420, maxHeight: 2)
                                .padding(.top, 2)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)

                // Dedicated Play / Resume Button
                Button(action: onPlay) {
                    Text(isFirst ? (entry.unit == "CH" ? "Continue" : "Resume") : (entry.unit == "CH" ? "Read" : "Play"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(isFirst ? SumiTheme.background : SumiTheme.foreground.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(isFirst ? SumiTheme.indigo : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                .stroke(isFirst ? Color.clear : SumiTheme.border, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(isFirst ? SumiTheme.card : (isHovered ? SumiTheme.card.opacity(0.6) : Color.clear))
            #if os(macOS)
            .onHover { hovering in
                isHovered = hovering
            }
            #endif
        }
    }
}
