import SwiftUI

public struct WeekStrip: View {
    public struct DayBucket: Identifiable, Sendable {
        public let id: Int
        public let date: Date
        public let label: String
        public let isToday: Bool
        public let items: [ScheduleView.ScheduleItem]

        public init(id: Int, date: Date, label: String, isToday: Bool, items: [ScheduleView.ScheduleItem]) {
            self.id = id
            self.date = date
            self.label = label
            self.isToday = isToday
            self.items = items
        }
    }

    public let items: [ScheduleView.ScheduleItem]
    public let onSelect: (ScheduleView.ScheduleItem) -> Void

    public init(
        items: [ScheduleView.ScheduleItem],
        onSelect: @escaping (ScheduleView.ScheduleItem) -> Void
    ) {
        self.items = items
        self.onSelect = onSelect
    }

    nonisolated private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    nonisolated public static func computeDays(
        from items: [ScheduleView.ScheduleItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayBucket] {
        let today = calendar.startOfDay(for: now)
        let formatter = dayFormatter

        let watchingItems = items.filter { $0.isWatching }

        // Calendar day boundaries handle DST switches that fixed 86,400s intervals miss.
        return (0..<7).map { offset in
            let dayDate = calendar.date(byAdding: .day, value: offset, to: today) ?? today
            let nextDayDate = calendar.date(byAdding: .day, value: 1, to: dayDate) ?? dayDate
            let start = dayDate.timeIntervalSince1970
            let end = nextDayDate.timeIntervalSince1970

            let dayShows = watchingItems.filter { item in
                let t = TimeInterval(item.airingAt)
                return t >= start && t < end
            }

            return DayBucket(
                id: offset,
                date: dayDate,
                label: formatter.string(from: dayDate),
                isToday: offset == 0,
                items: dayShows
            )
        }
    }

    public var days: [DayBucket] {
        Self.computeDays(from: items)
    }

    public var body: some View {
        if !items.contains(where: \.isWatching) {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("This week")
                    .font(.sumiHeading(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)

                HStack(alignment: .top, spacing: 0) {
                    ForEach(days) { day in
                        dayColumn(day)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func dayColumn(_ day: DayBucket) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.label)
                .sumiTabularMono(size: 9.5, weight: day.isToday ? .semibold : .regular)
                .foregroundColor(day.isToday ? SumiTheme.indigo : SumiTheme.muted)

            if !day.items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(day.items.prefix(3)) { item in
                        ShowItemView(item: item, onSelect: { onSelect(item) })
                    }
                }
            } else {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .leading) {
            if day.id > 0 {
                Rectangle()
                    .fill(SumiTheme.border)
                    .frame(width: 1)
            }
        }
    }

    private struct ShowItemView: View {
        let item: ScheduleView.ScheduleItem
        let onSelect: () -> Void

        @State private var isHovered = false

        private var displayTitle: String {
            // Cut franchise subtitles after colon to prevent overflow in narrow day columns,
            // matching the web WeekStrip ("Sousou no Frieren: ..." -> "Sousou no Frieren").
            let parts = item.title.split(separator: ":", maxSplits: 1)
            if parts.count > 1 && parts[0].count > 3 {
                return String(parts[0]).trimmingCharacters(in: .whitespaces)
            }
            return item.title
        }

        var body: some View {
            Button(action: onSelect) {
                (
                    Text(displayTitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(isHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.8))
                    + Text(" ")
                    + Text("Ep \(item.episodeNumber)")
                        .font(.system(size: 8.5, weight: .medium)).monospacedDigit()
                        .foregroundColor(SumiTheme.muted)
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .help(item.title)
            .background(
                SumiRect(cornerRadius: SumiTheme.radiusSm)
                    .fill(SumiTheme.indigo.opacity(isHovered ? 0.12 : 0))
            )
            .stableHover { isHovered = $0 }
            .animation(.snappy, value: isHovered)
        }
    }
}

/// The Schedule page's row of seven day cells: weekday, date, and how many
/// of the viewer's own titles air that day. Separate from `WeekStrip`, the
/// home page's glance, which lists titles rather than counts and which the
/// bucketing tests pin to seven days from today.
struct ScheduleDayStrip: View {
    let days: [Date]
    let selected: Date
    let yoursCount: (Date) -> Int
    let onSelect: (Date) -> Void

    nonisolated private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    /// Monday to Sunday of the week holding `date`, by the same `.weekday`
    /// arithmetic as `CalendarView.monthGrid`, so the strip and the month
    /// grid agree on where a week starts whatever the region's first day is.
    nonisolated static func week(containing date: Date, calendar: Calendar = .current) -> [Date] {
        let day = calendar.startOfDay(for: date)
        let leading = (calendar.component(.weekday, from: day) + 5) % 7
        guard let monday = calendar.date(byAdding: .day, value: -leading, to: day) else { return [day] }
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
    }

    var body: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                cell(day)
            }
        }
    }

    private func cell(_ day: Date) -> some View {
        let isToday = Calendar.current.isDateInToday(day)
        let isSelected = Calendar.current.isDate(day, inSameDayAs: selected)
        let count = yoursCount(day)
        return Button {
            onSelect(day)
        } label: {
            VStack(spacing: 2) {
                Text(isToday ? "Today" : Self.weekdayFormatter.string(from: day))
                    .font(.system(size: 12, weight: isToday ? .semibold : .regular))
                    .foregroundColor(isToday ? SumiTheme.indigo : SumiTheme.muted)
                Text("\(Calendar.current.component(.day, from: day))")
                    .sumiTabularMono(size: 17, weight: .semibold)
                    .foregroundColor(SumiTheme.foreground)
                Text(count > 0 ? "\(count) yours" : "0")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
                    .contentTransition(.numericText())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    SumiRect(cornerRadius: SumiTheme.radiusMd)
                        .fill(SumiTheme.card)
                        .overlay {
                            SumiRect(cornerRadius: SumiTheme.radiusMd)
                                .strokeBorder(SumiTheme.border, lineWidth: 1)
                        }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
