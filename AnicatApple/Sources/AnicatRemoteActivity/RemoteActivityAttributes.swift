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
        /// Stamped on its own in the index block, so it stays legible in the
        /// compact Island where the title never fits.
        public var episodeNumber: Int
        public var isPlaying: Bool
        public var currentTime: Double
        public var duration: Double
        /// What the Mac's Skip pill is offering, nil when it offers nothing.
        public var skipLabel: String?

        public init(
            title: String,
            subtitle: String,
            episodeNumber: Int = 0,
            isPlaying: Bool,
            currentTime: Double,
            duration: Double,
            skipLabel: String? = nil
        ) {
            self.title = title
            self.subtitle = subtitle
            self.episodeNumber = episodeNumber
            self.isPlaying = isPlaying
            self.currentTime = currentTime
            self.duration = duration
            self.skipLabel = skipLabel
        }
    }

    /// The Mac being controlled. Fixed for the life of the activity: a
    /// different Mac is a different session, not an update to this one.
    public var hostName: String

    /// The current skin, as hex, so the lock screen is in the same palette
    /// as the app rather than in the system's default chrome.
    ///
    /// Carried in the attributes and not the state because a skin change
    /// mid-episode is rare and an activity is cheap to replace, while a
    /// field on the state costs bytes in every one-second update -- and
    /// ActivityKit caps a content state at 4 KB.
    ///
    /// Hex strings rather than the `Color`s themselves: `SumiPalette` lives
    /// in AnicatUI, which the widget must never link, and hex is what the
    /// palette stores anyway.
    public var backgroundHex: String
    public var cardHex: String
    public var foregroundHex: String
    public var accentHex: String
    public var mutedAlpha: Double
    public var borderAlpha: Double
    /// Sakura Zen sets its headings in a serif. Without this the one skin
    /// whose identity is its typeface would lose it on the lock screen.
    public var usesSerifHeadings: Bool

    public init(
        hostName: String,
        backgroundHex: String = "#12100E",
        cardHex: String = "#1B1815",
        foregroundHex: String = "#F5F0E8",
        accentHex: String = "#7C6BF5",
        mutedAlpha: Double = 0.62,
        borderAlpha: Double = 0.14,
        usesSerifHeadings: Bool = false
    ) {
        self.hostName = hostName
        self.backgroundHex = backgroundHex
        self.cardHex = cardHex
        self.foregroundHex = foregroundHex
        self.accentHex = accentHex
        self.mutedAlpha = mutedAlpha
        self.borderAlpha = borderAlpha
        self.usesSerifHeadings = usesSerifHeadings
    }
}
#endif
