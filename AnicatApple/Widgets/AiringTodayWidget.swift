import SwiftUI
import WidgetKit

struct AiringEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshot.AiringEntry]
    let covers: [Int64: Data]
}

struct AiringProvider: TimelineProvider {
    func placeholder(in context: Context) -> AiringEntry {
        AiringEntry(date: Date(), items: [
            .init(id: 1, title: "ONE PIECE", episode: 1180, airingAt: Int64(Date().addingTimeInterval(3600).timeIntervalSince1970), coverURL: nil, isWatching: true),
            .init(id: 2, title: "Black Clover Season 2", episode: 4, airingAt: Int64(Date().addingTimeInterval(7200).timeIntervalSince1970), coverURL: nil, isWatching: false),
        ], covers: [:])
    }
    func getSnapshot(in context: Context, completion: @escaping (AiringEntry) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task { completion(await entry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<AiringEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            let entry = await entry()
            // Refresh at the next air time so an aired row drops off, else
            // hourly.
            let next = entry.items.map { Date(timeIntervalSince1970: TimeInterval($0.airingAt)) }.filter { $0 > Date() }.min()
            completion(Timeline(entries: [entry], policy: .after(next ?? Date().addingTimeInterval(3600))))
        }
    }
    private func entry() async -> AiringEntry {
        let calendar = Calendar.current
        let today = (WidgetSnapshot.load()?.airing ?? [])
            .filter { calendar.isDateInToday(Date(timeIntervalSince1970: TimeInterval($0.airingAt))) }
            .filter { Date(timeIntervalSince1970: TimeInterval($0.airingAt)) > Date().addingTimeInterval(-3600) }
            .sorted { $0.airingAt < $1.airingAt }
        let items = Array(today.prefix(3))
        var covers: [Int64: Data] = [:]
        for item in items { if let data = await CoverFetcher.fetch(item.coverURL) { covers[item.id] = data } }
        return AiringEntry(date: Date(), items: items, covers: covers)
    }
}

struct AiringTodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.anicat.ios.airing", provider: AiringProvider()) { entry in
            AiringWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Airing Today")
        .description("What airs today, from your schedule.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct AiringWidgetView: View {
    let entry: AiringEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("AIRING TODAY").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            if entry.items.isEmpty {
                Text("Nothing more today.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(entry.items) { item in
                Link(destination: DeepLinks.title(id: item.id, manga: false)) {
                    HStack(spacing: 10) {
                        CoverImage(data: entry.covers[item.id])
                            .frame(width: 26, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("EP \(item.episode) \u{00B7} \(Date(timeIntervalSince1970: TimeInterval(item.airingAt)).formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(item.isWatching ? WidgetTheme.accent : .secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
