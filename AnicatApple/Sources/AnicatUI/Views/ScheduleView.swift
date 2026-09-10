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
    /// The visible month's airing slots, keyed and fetched by the model.
    /// Separate from `items`, which is only the *next* episode of each title
    /// the home page already had — see `CalendarView`'s note.
    public let calendarSlots: [FfiAiringSlot]
    public let isCalendarLoading: Bool
    /// Fired with a date inside whichever month the calendar wants; the model
    /// deduplicates by month key, so calling it on every appear costs nothing
    /// once the month is cached.
    public let onRequestMonth: (Date) -> Void
    public let onSelectSlot: (FfiAiringSlot) -> Void

    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @State private var watchingOnly: Bool = true
    /// "week" or "month". Week is the default: it answers "what is on
    /// tonight", which is what this section is opened for.
    @State private var mode: String = "week"
    /// Owned here rather than in `CalendarView` so switching to the week tab
    /// and back returns to the month that was being looked at.
    @State private var calendarMonth: Date = Date()
    @Namespace private var toggleNamespace

    // Cached result of the O(n log n) group+sort — rebuilt only when `items`
    // or `watchingOnly` changes, not on every body re-evaluation.
    @State private var groupedItems: [(day: String, items: [ScheduleItem])] = []

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

    private func recomputeGroups() {
        // AniList's `nextAiringEpisode` schedule already only ever returns
        // future airings, but for a show with a long-running weekly slot that
        // window stretches arbitrarily far out — this caps what's shown to a
        // week so the page reads as "what's airing soon", not the entire
        // remaining season.
        let now = Date().timeIntervalSince1970
        let sevenDaysOut = now + 7 * 24 * 60 * 60
        let filtered = items
            .filter { !watchingOnly || $0.isWatching }
            .filter { Double($0.airingAt) <= sevenDaysOut }
        let grouped = Dictionary(grouping: filtered, by: { $0.dayGroup })
        groupedItems = grouped.map { (day: $0.key, items: $0.value) }
            .sorted(by: { ($0.items.first?.airingAt ?? 0) < ($1.items.first?.airingAt ?? 0) })
    }

    /// The filter and the list it produces change in one transaction. The
    /// list used to be rebuilt from an `onChange` on the next update, outside
    /// the toggle's `withAnimation`, so the pill slid while every card
    /// popped in place. Cards keep their identity across the filter, so
    /// inside the transaction a survivor slides to its new slot and the
    /// section it left collapses under it.
    private func setWatchingOnly(_ value: Bool) {
        withAnimation(.sumi(.page)) {
            watchingOnly = value
            recomputeGroups()
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(alignment: .leading, spacing: SumiTheme.spaceLg) {
                // Header Row
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Airing Schedule")
                            .font(.sumiHeading(size: 28, weight: .bold))
                            .foregroundColor(SumiTheme.foreground)
                        Text(watchingOnly ? "\(groupedItems.reduce(0) { $0 + $1.items.count }) shows in your watchlist" : "Keep track of the latest releases and upcoming episodes")
                            .font(.system(size: 14))
                            .foregroundColor(SumiTheme.muted)
                            .contentTransition(.numericText())
                            .animation(.sumiSpring, value: watchingOnly)
                    }

                    Spacer()

                    // Global vs Watching Only Toggle
                    HStack(spacing: 2) {
                        Button(action: {
                            if watchingOnly {
                                SumiHaptics.selection()
                                setWatchingOnly(false)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "globe")
                                Text("Global")
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(!watchingOnly ? SumiTheme.foreground : SumiTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                if !watchingOnly {
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                        .fill(SumiTheme.card)
                                        .matchedGeometryEffect(id: "scheduleTogglePill", in: toggleNamespace)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)

                        Button(action: {
                            if !watchingOnly {
                                SumiHaptics.selection()
                                setWatchingOnly(true)
                            }
                        }) {
                            HStack(spacing: 6) {
                                Image(systemName: "tv")
                                Text("Watching")
                            }
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(watchingOnly ? SumiTheme.foreground : SumiTheme.muted)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background {
                                if watchingOnly {
                                    RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                        .fill(SumiTheme.card)
                                        .matchedGeometryEffect(id: "scheduleTogglePill", in: toggleNamespace)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                    }
                    .animation(.sumiSpring, value: watchingOnly)
                    .padding(3)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                }
                .padding(.horizontal, SumiTheme.spaceMd)

                SumiSegmentedControl(
                    options: [("week", "Week"), ("month", "Calendar")],
                    selection: $mode
                )
                .fixedSize()
                .padding(.horizontal, SumiTheme.spaceMd)

                if mode == "month" {
                    CalendarView(
                        month: $calendarMonth,
                        slots: calendarSlots,
                        isLoading: isCalendarLoading,
                        watchingOnly: watchingOnly,
                        timeFormat: timeFormat,
                        onSelectSlot: onSelectSlot
                    )
                    .padding(.horizontal, SumiTheme.spaceMd)
                } else if groupedItems.isEmpty {
                    SumiEmptyState(
                        headline: watchingOnly ? "No watching shows airing soon" : "No airing shows found",
                        detail: watchingOnly ? "Shows you are currently watching with upcoming episodes will appear here." : "Airing schedules will appear here for ongoing shows."
                    )
                    .padding(.top, 40)
                } else {
                    // Day Groups rendered lazily
                    ForEach(groupedItems, id: \.day) { group in
                        ScheduleDaySection(
                            group: group,
                            timeFormat: timeFormat,
                            onSelectItem: onSelectItem
                        )
                        .sumiTransition(.opacity)
                    }
                }
            }
            .padding(.vertical, SumiTheme.spaceLg)
        }
        .background(SumiTheme.background)
        .onAppear { recomputeGroups() }
        .onChange(of: items) { _, _ in recomputeGroups() }
        // Asked for on every entry into the calendar tab and on every page,
        // not once on appear: the month cache is keyed per month, so the
        // request that is already answered is dropped by the model rather
        // than gated by a flag here.
        .onChange(of: mode) { _, next in
            if next == "month" { onRequestMonth(calendarMonth) }
        }
        .onChange(of: calendarMonth) { _, next in
            if mode == "month" { onRequestMonth(next) }
        }
    }
}

private struct ScheduleDaySection: View {
    let group: (day: String, items: [ScheduleView.ScheduleItem])
    let timeFormat: String
    let onSelectItem: (ScheduleView.ScheduleItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SumiTheme.spaceMd) {
            Text(group.day.uppercased())
                .sumiTabularMono(size: 13, weight: .bold)
                .foregroundColor(SumiTheme.indigo)
                .padding(.horizontal, SumiTheme.spaceMd)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12)], spacing: 12) {
                ForEach(group.items) { item in
                    ScheduleItemCard(
                        item: item,
                        timeFormat: timeFormat,
                        onSelect: { onSelectItem(item) }
                    )
                    // A card that leaves the filter shrinks out where it
                    // stood; one that joins grows in. Without a transition a
                    // removed card vanished on the first frame while its
                    // neighbours were still travelling into its space.
                    .sumiTransition(.opacity.combined(with: .scale(scale: 0.94)))
                }
            }
            .padding(.horizontal, SumiTheme.spaceMd)
        }
    }
}

private struct ScheduleItemCard: View {
    let item: ScheduleView.ScheduleItem
    let timeFormat: String
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Poster Thumbnail
                CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 150) { img in
                    img.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.card)
                }
                .frame(width: 55, height: 75)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                // Meta
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.sumiHeading(size: 13.5, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(2)

                    HStack(spacing: 8) {
                        Text("Ep \(item.episodeNumber)")
                            .sumiTabularMono(size: 11, weight: .medium)
                            .foregroundColor(SumiTheme.indigo)
                            .contentTransition(.numericText())

                        Text(item.airingAt > 0 ? SumiTheme.formatTime(Date(timeIntervalSince1970: TimeInterval(item.airingAt)), timeFormat: timeFormat) : item.airingTimeText)
                            .sumiTabularMono(size: 11)
                            .foregroundColor(SumiTheme.muted)
                    }

                    Text(item.countdownText)
                        .sumiTabularMono(size: 10.5)
                        .foregroundColor(SumiTheme.muted.opacity(0.8))
                        .contentTransition(.numericText())
                }
                Spacer()
            }
            .padding(8)
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }
}
