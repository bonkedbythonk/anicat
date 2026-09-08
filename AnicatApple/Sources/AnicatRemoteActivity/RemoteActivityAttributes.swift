#if os(iOS)
import ActivityKit
import Foundation

/// What the Live Activity shows while the phone is a remote for a Mac.
///
/// Its own target, depending on nothing, because both the app and the widget
/// extension have to see this type and the widget must not link `AnicatUI`:
/// that would pull mpv, FFmpeg and their whole xcframework closure into an
/// extension that draws two lines of text and a progress bar.
public struct RemoteActivityAttributes: ActivityAttributes {
    // `Sendable` spelled out: this type crosses from the MainActor into
    // ActivityKit's own async calls, and a public struct from another module
    // is not inferred as such.
    public struct ContentState: Codable, Hashable, Sendable {
        public var title: String
        public var subtitle: String
        public var isPlaying: Bool
        public var currentTime: Double
        public var duration: Double
        /// What the Mac's Skip pill is offering, nil when it offers nothing.
        public var skipLabel: String?

        public init(
            title: String,
            subtitle: String,
            isPlaying: Bool,
            currentTime: Double,
            duration: Double,
            skipLabel: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.isPlaying = isPlaying
            self.currentTime = currentTime
            self.duration = duration
            self.skipLabel = skipLabel
        }
    }

    /// The Mac being controlled. Fixed for the life of the activity: a
    /// different Mac is a different session, not an update to this one.
    public var hostName: String

    public init(hostName: String) {
        self.hostName = hostName
    }
}
#endif
