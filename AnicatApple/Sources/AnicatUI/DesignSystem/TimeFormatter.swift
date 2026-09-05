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
