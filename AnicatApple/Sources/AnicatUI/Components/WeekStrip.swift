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
            }
        }
    }

    private func dayColumn(_ day: DayBucket) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.label)
                .sumiTabularMono(size: 10, weight: day.isToday ? .semibold : .regular)
                .foregroundColor(day.isToday ? SumiTheme.indigo : SumiTheme.muted)

            if !day.items.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(day.items) { item in
                        ShowItemView(item: item, onSelect: { onSelect(item) })
                    }
                }
            } else {
                // Preserves uniform column width and grid slotting when nothing airs.
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
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

        var body: some View {
            Button(action: onSelect) {
                VStack(alignment: .leading, spacing: 5) {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: item.coverImageURL) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                                    .scaleEffect(isHovered ? 1.04 : 1.0)
                                    .animation(.easeOut(duration: 0.2), value: isHovered)
                            case .failure:
                                Rectangle()
                                    .fill(SumiTheme.card)
                                    .overlay(
                                        Image(systemName: "photo")
                                            .font(.system(size: 13))
                                            .foregroundColor(SumiTheme.muted)
                                    )
                            case .empty:
                                Rectangle()
                                    .fill(SumiTheme.card)
                            @unknown default:
                                Rectangle().fill(SumiTheme.card)
                            }
                        }
                        .frame(height: 68)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                        Text("EP \(item.episodeNumber)")
                            .sumiTabularMono(size: 9, weight: .semibold)
                            .foregroundColor(SumiTheme.foreground)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.75))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .padding(4)
                    }

                    Text(item.title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isHovered ? SumiTheme.foreground : SumiTheme.foreground.opacity(0.85))
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(item.title)
            #if os(macOS)
            .onHover { isHovered = $0 }
            #endif
            .animation(.easeOut(duration: 0.2), value: isHovered)
        }
    }
}
