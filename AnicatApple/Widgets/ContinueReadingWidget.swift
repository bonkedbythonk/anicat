import SwiftUI
import WidgetKit

struct ReadingWidgetEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshot.ReadingEntry]
    let covers: [Int64: Data]
}

struct ReadingProvider: TimelineProvider {
    func placeholder(in context: Context) -> ReadingWidgetEntry {
        ReadingWidgetEntry(date: Date(), items: [
            .init(id: 1, title: "One Piece", nextChapter: 1102, coverURL: nil),
            .init(id: 2, title: "Chainsaw Man", nextChapter: 180, coverURL: nil),
        ], covers: [:])
    }
    func getSnapshot(in context: Context, completion: @escaping (ReadingWidgetEntry) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task { completion(await entry()) }
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ReadingWidgetEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task { completion(Timeline(entries: [await entry()], policy: .after(Date().addingTimeInterval(3600)))) }
    }
    private func entry() async -> ReadingWidgetEntry {
        let items = Array((WidgetSnapshot.load()?.reading ?? []).prefix(3))
        var covers: [Int64: Data] = [:]
        for item in items { if let data = await CoverFetcher.fetch(item.coverURL) { covers[item.id] = data } }
        return ReadingWidgetEntry(date: Date(), items: items, covers: covers)
    }
}

struct ContinueReadingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.anicat.ios.reading", provider: ReadingProvider()) { entry in
            ReadingWidgetView(entry: entry).containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Continue Reading")
        .description("Pick a manga back up where you left it.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct ReadingWidgetView: View {
    let entry: ReadingWidgetEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CONTINUE READING").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
            if entry.items.isEmpty {
                Text("Nothing in progress.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
            ForEach(entry.items) { item in
                Link(destination: DeepLinks.title(id: item.id, manga: true)) {
                    HStack(spacing: 10) {
                        CoverImage(data: entry.covers[item.id])
                            .frame(width: 26, height: 38)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("CH \(item.nextChapter)")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }
}
