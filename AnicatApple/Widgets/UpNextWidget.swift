import SwiftUI
import WidgetKit

struct UpNextEntry: TimelineEntry {
    let date: Date
    let items: [WidgetSnapshot.UpNextEntry]
    let covers: [Int64: Data]
    var isPlaceholder = false
}

struct UpNextProvider: TimelineProvider {
    func placeholder(in context: Context) -> UpNextEntry {
        UpNextEntry(date: Date(), items: [
            .init(id: 1, title: "Frieren: Beyond Journey's End", episode: 5, coverURL: nil, isNew: true),
            .init(id: 2, title: "Dandadan", episode: 9, coverURL: nil, isNew: false),
            .init(id: 3, title: "The Apothecary Diaries", episode: 12, coverURL: nil, isNew: false),
        ], covers: [:], isPlaceholder: true)
    }

    func getSnapshot(in context: Context, completion: @escaping (UpNextEntry) -> Void) {
        // WidgetKit's completion is not `Sendable`; Swift 6 refuses it inside a
        // Task without this. It is called exactly once, on any thread WidgetKit
        // accepts.
        nonisolated(unsafe) let completion = completion
        Task { completion(await entry()) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UpNextEntry>) -> Void) {
        nonisolated(unsafe) let completion = completion
        Task {
            let entry = await entry()
            // The app reloads the timeline itself whenever the queue
            // changes; this is only the fallback for a phone that has not
            // opened it in a while.
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(3600))))
        }
    }

    private func entry() async -> UpNextEntry {
        let items = Array((WidgetSnapshot.load()?.upNext ?? []).prefix(3))
        var covers: [Int64: Data] = [:]
        for item in items {
            if let data = await CoverFetcher.fetch(item.coverURL) { covers[item.id] = data }
        }
        return UpNextEntry(date: Date(), items: items, covers: covers)
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.anicat.ios.upnext", provider: UpNextProvider()) { entry in
            UpNextWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("Up Next")
        .description("The next episode of what you are watching.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct UpNextWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: UpNextEntry

    var body: some View {
        if entry.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("UP NEXT").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                Text("Nothing in your queue.").font(.system(size: 13)).foregroundStyle(.secondary)
                Spacer()
            }
        } else if family == .systemSmall, let first = entry.items.first {
            Link(destination: DeepLinks.play(id: first.id, episode: first.episode)) {
                VStack(alignment: .leading, spacing: 6) {
                    CoverImage(data: entry.covers[first.id])
                        .frame(height: 70)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text(first.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                    Text("\(first.isNew ? "NEW  " : "")EP \(first.episode)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(first.isNew ? WidgetTheme.accent : .secondary)
                    Spacer(minLength: 0)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("UP NEXT").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(.secondary)
                ForEach(entry.items) { item in
                    Link(destination: DeepLinks.play(id: item.id, episode: item.episode)) {
                        HStack(spacing: 10) {
                            CoverImage(data: entry.covers[item.id])
                                .frame(width: 26, height: 38)
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Text("\(item.isNew ? "NEW  " : "")EP \(item.episode)")
                                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(item.isNew ? WidgetTheme.accent : .secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "play.fill").font(.system(size: 11)).foregroundStyle(WidgetTheme.accent)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

enum DeepLinks {
    static func play(id: Int64, episode: Int) -> URL { URL(string: "anicat://play/\(id)/\(episode)")! }
    static func title(id: Int64, manga: Bool) -> URL { URL(string: "anicat://title/\(id)\(manga ? "?manga=1" : "")")! }
}
