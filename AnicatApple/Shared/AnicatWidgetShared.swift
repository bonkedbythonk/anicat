import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Compiled into the iOS app target and the widget extension, and nowhere
// else: the extension cannot depend on AnicatUI (that would pull MPVKit
// into a widget), and the app target is the only other place that sees
// both the model and these types.

/// The App Group both processes read. A widget has no other way to see
/// what the app knows: the app writes a small JSON snapshot here and calls
/// `WidgetCenter.reloadAllTimelines`, the widget decodes it.
public enum AnicatWidgetShared {
    public static let appGroup = "group.com.anicat.ios"
    public static let snapshotFile = "widget-snapshot.json"

    public static var snapshotURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(snapshotFile)
    }
}

/// What the widgets draw. Small on purpose: three rows each, titles and
/// the one number that matters, cover URLs the widget fetches itself.
public struct WidgetSnapshot: Codable, Sendable {
    public struct UpNextEntry: Codable, Sendable, Identifiable {
        public var id: Int64
        public var title: String
        public var episode: Int
        public var coverURL: String?
        public var isNew: Bool
        public init(id: Int64, title: String, episode: Int, coverURL: String?, isNew: Bool) {
            self.id = id; self.title = title; self.episode = episode; self.coverURL = coverURL; self.isNew = isNew
        }
    }
    public struct AiringEntry: Codable, Sendable, Identifiable {
        public var id: Int64
        public var title: String
        public var episode: Int
        public var airingAt: Int64
        public var coverURL: String?
        public var isWatching: Bool
        public init(id: Int64, title: String, episode: Int, airingAt: Int64, coverURL: String?, isWatching: Bool) {
            self.id = id; self.title = title; self.episode = episode; self.airingAt = airingAt; self.coverURL = coverURL; self.isWatching = isWatching
        }
    }
    public struct ReadingEntry: Codable, Sendable, Identifiable {
        public var id: Int64
        public var title: String
        public var nextChapter: Int
        public var coverURL: String?
        public init(id: Int64, title: String, nextChapter: Int, coverURL: String?) {
            self.id = id; self.title = title; self.nextChapter = nextChapter; self.coverURL = coverURL
        }
    }

    public var writtenAt: Date
    public var upNext: [UpNextEntry]
    public var airing: [AiringEntry]
    public var reading: [ReadingEntry]

    public init(writtenAt: Date = Date(), upNext: [UpNextEntry], airing: [AiringEntry], reading: [ReadingEntry]) {
        self.writtenAt = writtenAt; self.upNext = upNext; self.airing = airing; self.reading = reading
    }

    public static func load() -> WidgetSnapshot? {
        guard let url = AnicatWidgetShared.snapshotURL,
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    public func save() throws {
        guard let url = AnicatWidgetShared.snapshotURL else { return }
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}

#if canImport(ActivityKit)
/// A download on the lock screen and the Dynamic Island.
public struct DownloadActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var percent: Double
        public var status: String
        public init(percent: Double, status: String) { self.percent = percent; self.status = status }
    }
    public var title: String
    public var episode: Int
    public var isFilm: Bool
    public init(title: String, episode: Int, isFilm: Bool) { self.title = title; self.episode = episode; self.isFilm = isFilm }
}

/// The Mac's playback while the phone is its remote.
public struct RemoteActivityAttributes: ActivityAttributes, Sendable {
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var episode: Int
        public var isPlaying: Bool
        public var currentTime: Double
        public var duration: Double
        public init(title: String, episode: Int, isPlaying: Bool, currentTime: Double, duration: Double) {
            self.title = title; self.episode = episode; self.isPlaying = isPlaying; self.currentTime = currentTime; self.duration = duration
        }
    }
    public var macName: String
    public init(macName: String) { self.macName = macName }
}
#endif
