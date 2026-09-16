import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// Compiled into the iOS app target and the widget extension, and nowhere
// else: the extension cannot depend on AnicatUI (that would pull MPVKit
// into a widget), and the app target is the only other place that sees
// both the model and these types. Live Activity attributes only: the
// home-screen widgets and their App Group snapshot were removed on
// 2026-09-15 because an App Group needs a paid team.

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
