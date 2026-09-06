import Foundation

public enum SumiTimeFormatter {
    public static let storageKey = "anicat_time_format"

    public static var currentTimeFormat: String {
        UserDefaults.standard.string(forKey: storageKey) ?? "24-hour"
    }

    public static var is12Hour: Bool {
        currentTimeFormat == "12-hour (AM/PM)"
    }

    public static func timeFormatPattern(for format: String? = nil) -> String {
        let fmt = format ?? currentTimeFormat
        return fmt == "12-hour (AM/PM)" ? "h:mm a" : "HH:mm"
    }

    public static func historyFormatPattern(for format: String? = nil) -> String {
        let fmt = format ?? currentTimeFormat
        return fmt == "12-hour (AM/PM)" ? "EEE hh:mm a" : "EEE HH:mm"
    }

    private static let time12Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()

    private static let time24Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let history12Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE hh:mm a"
        return f
    }()

    private static let history24Formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE HH:mm"
        return f
    }()

    public static func formatTime(_ date: Date, timeFormat: String? = nil) -> String {
        let is12 = (timeFormat ?? currentTimeFormat) == "12-hour (AM/PM)"
        return (is12 ? time12Formatter : time24Formatter).string(from: date)
    }

    public static func formatHistoryDate(_ date: Date, timeFormat: String? = nil) -> String {
        let is12 = (timeFormat ?? currentTimeFormat) == "12-hour (AM/PM)"
        return (is12 ? history12Formatter : history24Formatter).string(from: date)
    }

    /// "3h ago" / "2d ago" for a forum post or comment. Not
    /// `RelativeDateTimeFormatter`: its abbreviated style still emits
    /// localized words of varying length ("3 hr. ago", "2 days ago"), which
    /// wraps in the fixed-width mono line these are drawn in and stops the
    /// column of dates down a comment thread from lining up.
    public static func relativeShort(from date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        case ..<604_800: return "\(Int(seconds / 86_400))d ago"
        case ..<2_629_800: return "\(Int(seconds / 604_800))w ago"
        case ..<31_557_600: return "\(Int(seconds / 2_629_800))mo ago"
        default: return "\(Int(seconds / 31_557_600))y ago"
        }
    }

    /// AniList timestamps arrive as unix seconds over the FFI boundary.
    public static func relativeShort(unixSeconds: Int64, now: Date = Date()) -> String {
        relativeShort(from: Date(timeIntervalSince1970: TimeInterval(unixSeconds)), now: now)
    }

    public static func timeFormatter(timeFormat: String? = nil) -> DateFormatter {
        let is12 = (timeFormat ?? currentTimeFormat) == "12-hour (AM/PM)"
        return is12 ? time12Formatter : time24Formatter
    }

    public static func historyDateFormatter(timeFormat: String? = nil) -> DateFormatter {
        let is12 = (timeFormat ?? currentTimeFormat) == "12-hour (AM/PM)"
        return is12 ? history12Formatter : history24Formatter
    }
}

extension SumiTheme {
    public static func formatTime(_ date: Date, timeFormat: String? = nil) -> String {
        SumiTimeFormatter.formatTime(date, timeFormat: timeFormat)
    }

    public static func timeFormatter(timeFormat: String? = nil) -> DateFormatter {
        SumiTimeFormatter.timeFormatter(timeFormat: timeFormat)
    }
}
