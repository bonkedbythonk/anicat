import SwiftUI
import AnicatCoreKit

public struct ScheduleView: View {
    public struct ScheduleItem: Identifiable, Sendable, Codable, Equatable {
        public let id: Int64
        public let title: String
        public let coverImageURL: URL?
        public let episodeNumber: Int
        public let airingTimeText: String
        public let countdownText: String
        public let dayGroup: String // e.g. "Monday, September 4"
        public let airingAt: Int64 // unix seconds; dayGroup is display-only and not sortable
        public let isWatching: Bool

        public init(
            id: Int64,
            title: String,
            coverImageURL: URL?,
            episodeNumber: Int,
            airingTimeText: String,
            countdownText: String,
            dayGroup: String,
            airingAt: Int64,
            isWatching: Bool = false
        ) {
            self.id = id
            self.title = title
            self.coverImageURL = coverImageURL
            self.episodeNumber = episodeNumber
            self.airingTimeText = airingTimeText
            self.countdownText = countdownText
            self.dayGroup = dayGroup
            self.airingAt = airingAt
            self.isWatching = isWatching
        }
    }

    public let items: [ScheduleItem]
    public let onSelectItem: (ScheduleItem) -> Void
    /// The requested month's airing slots, keyed and fetched by the model.
    /// Separate from `items`, which is only the *next* episode of each title
    /// the home page already had — see `CalendarView`'s note.
    public let calendarSlots: [FfiAiringSlot]
    public let isCalendarLoading: Bool
    /// Fired with a date inside whichever month the page wants; the model
    /// deduplicates by month key, so calling it on every appear costs nothing
    /// once the month is cached.
    public let onRequestMonth: (Date) -> Void
    public let onSelectSlot: (FfiAiringSlot) -> Void

    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @State private var watchingOnly: Bool = true
    /// "week" (shown as Days) or "month". Days is the default: it answers
    /// "what is on tonight", which is what this section is opened for.
    @State private var mode: String = "week"
    /// Owned here rather than in `CalendarView` so switching to Days and back
    /// returns to the month that was being looked at.
    @State private var calendarMonth: Date = Date()
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())
    /// The month `calendarSlots` belongs to. The model holds one month at a
    /// time, the last one asked for, and Days and Month can each want a
    /// different one; reading the slots against any other month filled the
    /// wrong days, or left a week's tail empty when it ran into the next.
    @State private var requestedMonth: Date?

    public init(
        items: [ScheduleItem],
        calendarSlots: [FfiAiringSlot] = [],
        isCalendarLoading: Bool = false,
        onRequestMonth: @escaping (Date) -> Void = { _ in },
        onSelectSlot: @escaping (FfiAiringSlot) -> Void = { _ in },
        onSelectItem: @escaping (ScheduleItem) -> Void
    ) {
        self.items = items
        self.calendarSlots = calendarSlots
        self.isCalendarLoading = isCalendarLoading
        self.onRequestMonth = onRequestMonth
        self.onSelectSlot = onSelectSlot
        self.onSelectItem = onSelectItem
    }

    // MARK: - Data

    /// One line of the day list, from either source.
    fileprivate struct Row: Identifiable {
        let id: String
        let title: String
        let coverURL: URL?
        let episode: Int
        let airingAt: Int64
        let onList: Bool
        let status: String?
        let open: () -> Void
    }

    private func isLoaded(_ day: Date) -> Bool {
        guard let requestedMonth, !calendarSlots.isEmpty else { return false }
        return Calendar.current.isDate(day, equalTo: requestedMonth, toGranularity: .month)
    }

    /// A day's rows come from the month slots when that month is loaded, and
    /// from `items` otherwise, never both: the two overlap on every title in
    /// the viewer's list, and merging them counted each one twice.
    private func rows(on day: Date) -> [Row] {
        if isLoaded(day) {
            return CalendarView.slots(on: day, from: calendarSlots, watchingOnly: false).map { slot in
                Row(
                    id: "s\(slot.catalogId)-\(slot.episode)",
                    title: slot.title,
                    coverURL: URL(string: slot.coverImage),
                    episode: Int(slot.episode),
                    airingAt: slot.airingAt,
                    onList: slot.onUserList,
                    status: Self.statusLabel(slot.userStatus),
                    open: { onSelectSlot(slot) }
                )
            }
        }
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return [] }
        let from = Int64(start.timeIntervalSince1970)
        let to = Int64(end.timeIntervalSince1970)
        return items
            .filter { $0.airingAt >= from && $0.airingAt < to }
            .sorted { $0.airingAt < $1.airingAt }
            .map { item in
                Row(
                    id: "i\(item.id)-\(item.episodeNumber)",
                    title: item.title,
                    coverURL: item.coverImageURL,
                    episode: item.episodeNumber,
                    airingAt: item.airingAt,
                    onList: item.isWatching,
                    // `isWatching` is true for Planning as well, so it cannot
                    // name the status.
                    status: item.isWatching ? "On list" : nil,
                    open: { onSelectItem(item) }
                )
            }
    }

    nonisolated private static func statusLabel(_ status: String?) -> String? {
        switch status {
        case "CURRENT": "Watching"
        case "PLANNING": "Planning"
        case "COMPLETED": "Completed"
        case "PAUSED": "Paused"
        case "DROPPED": "Dropped"
        case "REPEATING": "Rewatching"
        case nil: nil
        default: "On list"
        }
    }

    /// "Times in Amsterdam": the city of the zone the times are drawn in.
    private var timeZoneMeta: String {
        let zone = TimeZone.current
        let parts = zone.identifier.split(separator: "/")
        if parts.count > 1, let city = parts.last {
            return "Times in \(city.replacingOccurrences(of: "_", with: " "))"
        }
        return "Times in \(zone.localizedName(for: .shortGeneric, locale: .current) ?? zone.identifier)"
    }

    nonisolated private static let dayTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM"
        return f
    }()

    private func request(_ month: Date) {
        requestedMonth = month
        onRequestMonth(month)
    }

    // MARK: - Body

    public var body: some View {
        // The same frame every other section draws in (see the home page in
        // RootView): 40pt margins and the shared width cap. This page had
        // 16pt margins and no cap, so its header sat 24pt further left than
        // the shelves on the pages beside it and its rows ran the full width
        // of a fullscreen window while theirs stopped.
        GeometryReader { viewport in
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: SumiTheme.spaceLg) {
                SumiPageHeader(title: "Schedule", subtitle: timeZoneMeta) {
                    HStack(spacing: SumiTheme.spaceMd) {
                        SumiSlashToggle(
                            [("global", "All"), ("watching", "Watching")],
                            selection: watchingOnly ? "watching" : "global"
                        ) { key in
                            withAnimation(.sumi(.page)) { watchingOnly = key == "watching" }
                        }
                        SumiSlashToggle(
                            [("week", "Days"), ("month", "Month")],
                            selection: mode
                        ) { key in
                            withAnimation(.snappy) { mode = key }
                        }
                    }
                }
                .padding(.horizontal, SumiTheme.spaceMd)

                if mode == "month" {
                    CalendarView(
                        month: $calendarMonth,
                        // Until the model answers for this month the slots in
                        // hand are the Days page's month, which would paint
                        // onto the grid's pad days.
                        slots: requestedMonth.map { Calendar.current.isDate($0, equalTo: calendarMonth, toGranularity: .month) } == true ? calendarSlots : [],
                        isLoading: isCalendarLoading,
                        watchingOnly: watchingOnly,
                        timeFormat: timeFormat,
                        onSelectSlot: onSelectSlot
                    )
                    .padding(.horizontal, SumiTheme.spaceMd)
                } else {
                    daysPage
                        .padding(.horizontal, SumiTheme.spaceMd)
                }
            }
            .padding(.horizontal, 40 - SumiTheme.spaceMd)
            .padding(.top, 40 - SumiTheme.spaceLg)
            .padding(.bottom, 32 - SumiTheme.spaceLg)
            .padding(.vertical, SumiTheme.spaceLg)
            .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        }
        .sumiGround()
        // Days reads the month slots too (past airings and the titles not in
        // the list exist nowhere else), so it asks on appear rather than
        // only on entering Month.
        .onAppear { request(mode == "month" ? calendarMonth : selectedDay) }
        .onChange(of: mode) { _, next in
            request(next == "month" ? calendarMonth : selectedDay)
        }
        .onChange(of: calendarMonth) { _, next in
            if mode == "month" { request(next) }
        }
        .onChange(of: selectedDay) { _, next in
            if let requestedMonth, Calendar.current.isDate(next, equalTo: requestedMonth, toGranularity: .month) { return }
            request(next)
        }
    }

    @ViewBuilder
    private var daysPage: some View {
        let dayRows = rows(on: selectedDay)
        let yours = dayRows.filter(\.onList)
        let others = watchingOnly ? [] : dayRows.filter { !$0.onList }

        VStack(alignment: .leading, spacing: SumiTheme.spaceLg) {
            ScheduleDayStrip(
                days: ScheduleDayStrip.week(containing: Date()),
                selected: selectedDay,
                yoursCount: { rows(on: $0).filter(\.onList).count },
                onSelect: { day in
                    SumiHaptics.selection()
                    withAnimation(.sumi(.page)) { selectedDay = day }
                }
            )

            VStack(alignment: .leading, spacing: 6) {
                SumiSectionHeader("In your list", trailing: Self.dayTitleFormatter.string(from: selectedDay))
                if yours.isEmpty {
                    Text(isCalendarLoading && !isLoaded(selectedDay) ? "Loading" : "Nothing from your list airs on this day.")
                        .font(.system(size: 12.5))
                        .foregroundColor(SumiTheme.muted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(yours) { row in
                        ScheduleRowView(row: row, muted: false, timeFormat: timeFormat)
                            .sumiTransition(.opacity)
                    }
                }
            }

            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SumiSectionHeader("Also airing", trailing: "\(others.count) more")
                    ForEach(others) { row in
                        ScheduleRowView(row: row, muted: true, timeFormat: timeFormat)
                            .sumiTransition(.opacity)
                    }
                }
                .sumiTransition(.opacity)
            }
        }
    }
}

/// time | poster | title and episode | status | countdown, on a hairline.
private struct ScheduleRowView: View {
    let row: ScheduleView.Row
    let muted: Bool
    let timeFormat: String

    /// "Out in 2 h". Computed from `airingAt` at draw time rather than taken
    /// from `ScheduleItem.countdownText`, which is rendered once at fetch and
    /// still said "in 3h" hours after the episode was out.
    nonisolated static func outText(_ airingAt: Int64, now: Date) -> String {
        let seconds = Int(airingAt) - Int(now.timeIntervalSince1970)
        if seconds <= 0 { return "Out" }
        if seconds < 3600 { return "Out in \(max(1, seconds / 60)) min" }
        if seconds < 86_400 { return "Out in \(seconds / 3600) h" }
        return "Out in \(seconds / 86_400) d"
    }

    var body: some View {
        Button(action: row.open) {
            HStack(spacing: 14) {
                Text(SumiTheme.formatTime(Date(timeIntervalSince1970: TimeInterval(row.airingAt)), timeFormat: timeFormat))
                    .sumiTabularMono(size: 13)
                    .foregroundColor(muted ? SumiTheme.muted : SumiTheme.foreground)
                    .frame(width: 56, alignment: .leading)

                CachedAsyncImage(url: row.coverURL, maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.foregroundWash)
                }
                .frame(width: 40, height: 56)
                .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 13, weight: muted ? .regular : .semibold))
                        .foregroundColor(SumiTheme.foreground.opacity(muted ? 0.8 : 1))
                        .lineLimit(1)
                    Text("Episode \(row.episode)")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(row.status ?? "")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: 120, alignment: .leading)

                // Once a minute is as fine as the label reads.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(Self.outText(row.airingAt, now: context.date))
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(muted ? SumiTheme.muted : SumiTheme.indigo)
                }
                .frame(width: 110, alignment: .trailing)
            }
            .padding(.vertical, 8)
            .overlay(alignment: .bottom) {
                Rectangle().fill(SumiTheme.border).frame(height: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .help(row.title)
    }
}
