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

    public static func formatTime(_ date: Date, timeFormat: String? = nil) -> String {
        timeFormatter(timeFormat: timeFormat).string(from: date)
    }

    public static func formatHistoryDate(_ date: Date, timeFormat: String? = nil) -> String {
        historyDateFormatter(timeFormat: timeFormat).string(from: date)
    }

    public static func timeFormatter(timeFormat: String? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = timeFormatPattern(for: timeFormat)
        return formatter
    }

    public static func historyDateFormatter(timeFormat: String? = nil) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = historyFormatPattern(for: timeFormat)
        return formatter
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
