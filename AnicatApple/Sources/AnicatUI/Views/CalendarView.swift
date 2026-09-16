import SwiftUI
import AnicatCoreKit

/// The Schedule section's month grid: every airing slot AniList knows about
/// for the visible month, laid out Monday-first, with a day's full list in a
/// column beside it.
///
/// Its sibling tab, the week list, is driven by `nextAiringEpisode` on the
/// titles the home page already fetched, so it can only ever show the *next*
/// episode of each. This one asks the engine for a real date window, which is
/// why it can show a month at all.
public struct CalendarView: View {
    /// One square of the grid. `inMonth` is false for the pad days that fill
    /// the first and last week — they are still real dates and still carry
    /// their slots, just drawn dimmed.
    public struct DayCell: Identifiable, Sendable, Equatable {
        public let id: Int
        public let date: Date
        public let inMonth: Bool

        public init(id: Int, date: Date, inMonth: Bool) {
            self.id = id
            self.date = date
            self.inMonth = inMonth
        }
    }

    /// The grid for whichever month `month` falls in: a whole number of
    /// Monday-to-Sunday weeks, padded at both ends with the neighbouring
    /// months' days.
    ///
    /// Monday-first comes from the arithmetic on `.weekday` (always 1 for
    /// Sunday, whatever the calendar's own `firstWeekday` is), not from the
    /// passed calendar's locale. Deriving it from `firstWeekday` instead put
    /// the grid a day out for anyone whose region starts the week on Sunday,
    /// and made the result depend on the test runner's locale.
    nonisolated public static func monthGrid(
        for month: Date,
        calendar: Calendar = .current
    ) -> [DayCell] {
        let cal = calendar
        guard let first = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let dayRange = cal.range(of: .day, in: .month, for: first) else { return [] }

        // Sunday is 1, so Monday (2) is index 0 and Sunday lands last.
        let leading = (cal.component(.weekday, from: first) + 5) % 7
        guard let gridStart = cal.date(byAdding: .day, value: -leading, to: first) else { return [] }

        let monthIndex = cal.component(.month, from: first)
        let weeks = (leading + dayRange.count + 6) / 7
        return (0..<(weeks * 7)).compactMap { offset in
            guard let date = cal.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            return DayCell(
                id: offset,
                date: date,
                inMonth: cal.component(.month, from: date) == monthIndex
            )
        }
    }

    /// Slots falling on `date`, in airing order. Whole-day bounds come from
    /// the calendar rather than a fixed 86,400s step so a DST switch does not
    /// push an evening slot into the next day.
    nonisolated public static func slots(
        on date: Date,
        from slots: [FfiAiringSlot],
        watchingOnly: Bool,
        calendar: Calendar = .current
    ) -> [FfiAiringSlot] {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        let from = Int64(start.timeIntervalSince1970)
        let to = Int64(end.timeIntervalSince1970)
        return slots
            .filter { !watchingOnly || $0.onUserList }
            .filter { $0.airingAt >= from && $0.airingAt < to }
            .sorted { $0.airingAt < $1.airingAt }
    }

    @Binding var month: Date
    let slots: [FfiAiringSlot]
    let isLoading: Bool
    let watchingOnly: Bool
    let timeFormat: String
    let onSelectSlot: (FfiAiringSlot) -> Void

    @State private var selectedDay: Date?

    public init(
        month: Binding<Date>,
        slots: [FfiAiringSlot],
        isLoading: Bool,
        watchingOnly: Bool,
        timeFormat: String,
        onSelectSlot: @escaping (FfiAiringSlot) -> Void
    ) {
        self._month = month
        self.slots = slots
        self.isLoading = isLoading
        self.watchingOnly = watchingOnly
        self.timeFormat = timeFormat
        self.onSelectSlot = onSelectSlot
    }

    /// Three chips is what a cell fits at the narrowest column the grid ever
    /// draws; everything past that is counted rather than clipped.
    private static let chipsPerCell = 3

    nonisolated private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    nonisolated private static let dayTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f
    }()

    private static let weekdayLabels = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]

    private var days: [DayCell] { Self.monthGrid(for: month) }

    public var body: some View {
        HStack(alignment: .top, spacing: SumiTheme.spaceLg) {
            VStack(alignment: .leading, spacing: 12) {
                monthHeader
                weekdayHeader
                grid
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            if let selectedDay {
                dayColumn(selectedDay)
                    .frame(width: 280)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.sumi(.pop), value: selectedDay)
        // Paging the month keeps the selected day, which would then belong to
        // a month whose slots are no longer loaded and read as an empty day.
        .onChange(of: month) { _, _ in selectedDay = nil }
    }

    private var monthHeader: some View {
        HStack(spacing: 8) {
            Text(Self.monthTitleFormatter.string(from: month))
                .font(.sumiHeading(size: 17, weight: .semibold))
                .foregroundColor(SumiTheme.foreground)
                .contentTransition(.numericText())

            if isLoading {
                ProgressView()
                    .scaleEffect(0.5)
                    .tint(SumiTheme.muted)
                    .frame(width: 16, height: 16)
            }

            Spacer()

            monthStepButton(systemName: "chevron.left", months: -1)
            Button {
                SumiHaptics.selection()
                withAnimation(.sumi(.pop)) { month = Date() }
            } label: {
                Text("Today")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(SumiTheme.foreground.opacity(0.7))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            monthStepButton(systemName: "chevron.right", months: 1)
        }
    }

    private func monthStepButton(systemName: String, months: Int) -> some View {
        Button {
            SumiHaptics.selection()
            guard let next = Calendar.current.date(byAdding: .month, value: months, to: month) else { return }
            withAnimation(.sumi(.pop)) { month = next }
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(SumiTheme.muted)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 6) {
            ForEach(Self.weekdayLabels, id: \.self) { label in
                Text(label)
                    .sumiTabularMono(size: 10)
                    .foregroundColor(SumiTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7),
            spacing: 6
        ) {
            ForEach(days) { day in
                dayCell(day)
            }
        }
    }

    private func dayCell(_ day: DayCell) -> some View {
        let daySlots = Self.slots(on: day.date, from: slots, watchingOnly: watchingOnly)
        let isToday = Calendar.current.isDateInToday(day.date)
        let isSelected = selectedDay.map { Calendar.current.isDate($0, inSameDayAs: day.date) } ?? false
        let onList = daySlots.contains(where: \.onUserList)

        return Button {
            SumiHaptics.selection()
            selectedDay = isSelected ? nil : day.date
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text("\(Calendar.current.component(.day, from: day.date))")
                        .sumiTabularMono(size: 11, weight: isToday ? .bold : .regular)
                        .foregroundColor(isToday ? SumiTheme.indigo : SumiTheme.foreground.opacity(day.inMonth ? 0.8 : 0.35))

                    if onList {
                        Circle()
                            .fill(SumiTheme.indigo)
                            .frame(width: 4, height: 4)
                    }

                    Spacer(minLength: 0)
                }

                if isLoading && daySlots.isEmpty {
                    ForEach(0..<2, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(SumiTheme.foregroundWash)
                            .frame(height: 26)
                    }
                } else {
                    ForEach(daySlots.prefix(Self.chipsPerCell), id: \.self) { slot in
                        slotChip(slot)
                    }
                    if daySlots.count > Self.chipsPerCell {
                        Text("+\(daySlots.count - Self.chipsPerCell)")
                            .sumiTabularMono(size: 9)
                            .foregroundColor(SumiTheme.muted)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(6)
            .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
            .background(isToday ? SumiTheme.card.opacity(0.6) : SumiTheme.card.opacity(day.inMonth ? 0.3 : 0.12))
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                    .stroke(
                        isSelected ? SumiTheme.indigo : (isToday ? SumiTheme.indigo.opacity(0.6) : SumiTheme.border),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    private func slotChip(_ slot: FfiAiringSlot) -> some View {
        HStack(spacing: 4) {
            CachedAsyncImage(url: URL(string: slot.coverImage), maxPixelSize: 60) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(SumiTheme.foregroundWash)
            }
            .frame(width: 18, height: 26)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            Text("\(slot.episode)")
                .sumiTabularMono(size: 9)
                .foregroundColor(slot.onUserList ? SumiTheme.indigo : SumiTheme.muted)

            Spacer(minLength: 0)
        }
        .help(slot.title)
    }

    private func dayColumn(_ date: Date) -> some View {
        let daySlots = Self.slots(on: date, from: slots, watchingOnly: watchingOnly)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(Self.dayTitleFormatter.string(from: date))
                    .font(.sumiHeading(size: 13, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                Spacer()
                Button {
                    selectedDay = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(SumiTheme.muted)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }

            if daySlots.isEmpty {
                Text(watchingOnly ? "Nothing from your list airs today." : "Nothing airs on this day.")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
            } else {
                ForEach(daySlots, id: \.self) { slot in
                    daySlotRow(slot)
                }
            }
        }
        .padding(12)
        .background(SumiTheme.card.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private func daySlotRow(_ slot: FfiAiringSlot) -> some View {
        Button {
            onSelectSlot(slot)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                CachedAsyncImage(url: URL(string: slot.coverImage), maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.foregroundWash)
                }
                .frame(width: 36, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                VStack(alignment: .leading, spacing: 3) {
                    Text(slot.title)
                        .font(.sumiHeading(size: 12.5, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    HStack(spacing: 6) {
                        Text(SumiTheme.formatTime(
                            Date(timeIntervalSince1970: TimeInterval(slot.airingAt)),
                            timeFormat: timeFormat
                        ))
                        .sumiTabularMono(size: 10)
                        .foregroundColor(SumiTheme.muted)

                        Text("Ep \(slot.episode)")
                            .sumiTabularMono(size: 10)
                            .foregroundColor(SumiTheme.indigo)
                    }

                    if slot.onUserList {
                        Text(slot.userStatus == "CURRENT" ? "Watching" : "On your list")
                            .sumiTabularMono(size: 9)
                            .foregroundColor(SumiTheme.indigo)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(SumiTheme.indigo.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }
}
