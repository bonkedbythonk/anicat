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

    nonisolated public static func computeDays(
        from items: [ScheduleView.ScheduleItem],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [DayBucket] {
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.calendar = calendar

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
        let watching = items.filter { $0.isWatching }
        if watching.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("This week")
                    .font(.system(size: 15, weight: .semibold))
                    .tracking(-0.2)
                    .foregroundColor(SumiTheme.foreground)

                HStack(alignment: .top, spacing: SumiTheme.spaceSm) {
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
        .background(day.isToday ? SumiTheme.card.opacity(0.6) : SumiTheme.card.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(day.isToday ? SumiTheme.indigo.opacity(0.6) : SumiTheme.border, lineWidth: 1)
        )
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
                    + Text("EP \(item.episodeNumber)")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundColor(SumiTheme.muted)
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.title)
            .background(
                RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                    .fill(SumiTheme.indigo.opacity(isHovered ? 0.12 : 0))
            )
            .scaleEffect(isHovered ? 1.03 : 1.0, anchor: .leading)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
            .animation(.snappy, value: isHovered)
        }
    }
}
