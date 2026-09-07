import SwiftUI
import AnicatCoreKit

/// What the local registry knows about a year of watching: totals, a streak
/// heat map, the titles that took the most of it, and a plain-language
/// summary.
///
/// Everything here comes out of `watchStats`, which reads the registry and
/// never the network — so this page works signed out and during an AniList
/// outage, which is most of the reason it is worth having.
public struct StatsView: View {
    /// One day of the heat map. Its own type rather than `FfiDayCount` so the
    /// layout maths below can be exercised without constructing uniffi values,
    /// and so a date is a `Date` rather than a string that has to be parsed
    /// again at every call site.
    public struct DayTally: Sendable, Equatable {
        public let date: Date
        public let episodes: Int
        public let seconds: Int64

        public init(date: Date, episodes: Int, seconds: Int64) {
            self.date = date
            self.episodes = episodes
            self.seconds = seconds
        }
    }

    /// Which of the five ink steps a day's cell takes, 0 (untouched) to 4.
    ///
    /// Scaled against the busiest day rather than a fixed episode count: a
    /// fixed scale renders a light viewer's whole year at step 1 and a heavy
    /// one's at step 4, and in both cases the map stops saying anything.
    nonisolated public static func heatBucket(episodes: Int, max: Int) -> Int {
        guard episodes > 0, max > 0 else { return 0 }
        let ratio = Double(episodes) / Double(max)
        if ratio <= 0.25 { return 1 }
        if ratio <= 0.5 { return 2 }
        if ratio <= 0.75 { return 3 }
        return 4
    }

    /// The tallies as GitHub-shaped columns: one column per week, seven rows
    /// with Monday at the top. `nil` is a cell outside the range — the days
    /// before the first tally in the opening week, and after the last in the
    /// closing one.
    ///
    /// The leading pad is the whole point. Without it the first tally lands on
    /// row 0 whatever weekday it actually is, and every row of the map is then
    /// labelled with the wrong day.
    nonisolated public static func heatColumns(
        _ tallies: [DayTally],
        calendar: Calendar = .current
    ) -> [[DayTally?]] {
        guard let first = tallies.first else { return [] }
        // Sunday is 1 in every calendar, whatever its own `firstWeekday` says,
        // so Monday maps to row 0 without reading the locale.
        let leading = (calendar.component(.weekday, from: first.date) + 5) % 7
        var cells: [DayTally?] = Array(repeating: nil, count: leading)
        cells.append(contentsOf: tallies.map { Optional($0) })
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<($0 + 7)]) }
    }

    /// Where each month's name goes along the top of the map: the column that
    /// holds that month's first cell. Only the first column of a month gets a
    /// label, so a month that starts mid-week is not written twice.
    nonisolated public static func monthLabels(
        for columns: [[DayTally?]],
        calendar: Calendar = .current
    ) -> [Int: String] {
        var labels: [Int: String] = [:]
        var lastMonth = -1
        for (index, column) in columns.enumerated() {
            guard let day = column.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: day.date)
            if month != lastMonth {
                lastMonth = month
                labels[index] = Self.monthAbbreviations[month - 1]
            }
        }
        return labels
    }

    /// The "Year in review" card's two sentences. Templated, not generated:
    /// the numbers are already on the page, and this is here to say what they
    /// add up to.
    nonisolated public static func yearInReview(
        hours: Double,
        episodes: Int,
        titles: Int,
        longestStreak: Int,
        busiestHour: Int,
        topTitle: String?
    ) -> String {
        guard episodes > 0 || hours > 0 else {
            return "Nothing has been recorded in the last year yet. Play an episode and this page fills itself in."
        }
        let first = "Over the last year you finished \(episodes) episode\(episodes == 1 ? "" : "s") "
            + "across \(titles) title\(titles == 1 ? "" : "s"), \(String(format: "%.1f", hours)) hours in all."
        var second = " Your longest run was \(longestStreak) day\(longestStreak == 1 ? "" : "s") in a row"
        second += ", and \(String(format: "%02d:00", busiestHour)) is the hour you start most often"
        if let topTitle {
            second += "; \(topTitle) took more of it than anything else."
        } else {
            second += "."
        }
        return first + second
    }

    nonisolated private static let monthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"
    ]

    /// The five ink steps a heat cell takes. Index 0 is the untouched track,
    /// which is a foreground wash rather than the accent at low alpha — the
    /// accent at 5% still reads as "a little bit of watching" on a day with
    /// none.
    private static let heatOpacities: [Double] = [0, 0.22, 0.42, 0.68, 1.0]

    /// `YYYY-MM-DD` as the engine writes it, parsed back with a fixed locale
    /// and calendar. `DateFormatter` with no locale set follows the device's,
    /// and an Arabic or Persian one turns these into unparseable nil.
    nonisolated private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    nonisolated private static let tooltipFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM yyyy"
        return f
    }()

    let stats: FfiWatchStats?
    /// Names and covers for the top-titles list. `FfiTitleCount` carries an
    /// id and nothing else — the registry never learns what a show is called —
    /// so the name has to come from whatever the catalog views have loaded.
    let knownTitles: [Int64: String]
    let knownCovers: [Int64: URL]
    /// The 30-day window behind the "most watched" card; the year-long
    /// `stats` feeds everything else.
    let recentStats: FfiWatchStats?
    let onLoad: () -> Void
    let onSelectTitle: (Int64, String?) -> Void
    let onResolveTitle: (Int64) -> Void

    public init(
        stats: FfiWatchStats?,
        recentStats: FfiWatchStats? = nil,
        knownTitles: [Int64: String] = [:],
        knownCovers: [Int64: URL] = [:],
        onLoad: @escaping () -> Void = {},
        onSelectTitle: @escaping (Int64, String?) -> Void = { _, _ in },
        onResolveTitle: @escaping (Int64) -> Void = { _ in }
    ) {
        self.stats = stats
        self.recentStats = recentStats
        self.knownTitles = knownTitles
        self.knownCovers = knownCovers
        self.onLoad = onLoad
        self.onSelectTitle = onSelectTitle
        self.onResolveTitle = onResolveTitle
    }

    private var tallies: [DayTally] {
        (stats?.perDay ?? []).compactMap { row in
            guard let date = Self.dayParser.date(from: row.date) else { return nil }
            return DayTally(date: date, episodes: Int(row.episodes), seconds: row.seconds)
        }
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: SumiTheme.spaceLg) {
                header

                if let stats, stats.episodesWatched > 0 || stats.totalWatchSeconds > 0 {
                    summaryRow(stats)
                    heatMapCard
                    habitCard(stats)
                    topTitlesCard(stats)
                    yearInReviewCard(stats)
                } else {
                    SumiEmptyState(
                        headline: "No watch history yet",
                        detail: "Everything on this page comes from the local registry, so it fills in as you watch — no sign-in required."
                    )
                    .padding(.top, 40)
                }
            }
            .padding(.horizontal, SumiTheme.spaceLg)
            .padding(.vertical, SumiTheme.spaceLg)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(SumiTheme.background)
        .onAppear(perform: onLoad)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stats")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(SumiTheme.foreground)
            Text("The last 365 days, from this device's own watch log.")
                .font(.system(size: 14))
                .foregroundColor(SumiTheme.muted)
        }
    }

    private func summaryRow(_ stats: FfiWatchStats) -> some View {
        HStack(alignment: .top, spacing: 12) {
            statTile("Hours", String(format: "%.1f", Double(stats.totalWatchSeconds) / 3600))
            statTile("Episodes", "\(stats.episodesWatched)")
            statTile("Titles", "\(stats.titlesStarted)")
            statTile("Current streak", "\(stats.currentStreakDays)d")
            statTile("Longest streak", "\(stats.longestStreakDays)d")
        }
    }

    private func statTile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(SumiTheme.foreground)
                .contentTransition(.numericText())
            Text(label.uppercased())
                .sumiTabularMono(size: 10)
                .foregroundColor(SumiTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(SumiTheme.card.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private var heatMapCard: some View {
        let days = tallies
        let columns = Self.heatColumns(days)
        let labels = Self.monthLabels(for: columns)
        let busiest = days.map(\.episodes).max() ?? 0

        return card(title: "Activity") {
            // Horizontal scroll rather than a smaller cell: a year is 53
            // columns, and shrinking them to fit a narrow window took the
            // squares below the size a pointer can pick one out of.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 4) {
                    weekdayGutter
                    VStack(alignment: .leading, spacing: 3) {
                        monthRow(columns: columns, labels: labels)
                        HStack(spacing: 3) {
                            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                                VStack(spacing: 3) {
                                    ForEach(Array(column.enumerated()), id: \.offset) { _, day in
                                        heatCell(day, busiest: busiest)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            legend
        }
    }

    private var weekdayGutter: some View {
        VStack(alignment: .trailing, spacing: 3) {
            // The month row's own height, so the gutter starts level with the
            // first square rather than the first label.
            Color.clear.frame(height: 12)
            ForEach(Array(["Mon", "", "Wed", "", "Fri", "", "Sun"].enumerated()), id: \.offset) { _, label in
                Text(label)
                    .sumiTabularMono(size: 8)
                    .foregroundColor(SumiTheme.muted)
                    .frame(height: 11, alignment: .center)
            }
        }
        .frame(width: 26, alignment: .trailing)
    }

    private func monthRow(columns: [[DayTally?]], labels: [Int: String]) -> some View {
        HStack(spacing: 3) {
            ForEach(0..<max(columns.count, 1), id: \.self) { index in
                Text(labels[index] ?? "")
                    .sumiTabularMono(size: 8)
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize()
                    .frame(width: 11, height: 12, alignment: .leading)
            }
        }
    }

    private func heatCell(_ day: DayTally?, busiest: Int) -> some View {
        let bucket = day.map { Self.heatBucket(episodes: $0.episodes, max: busiest) } ?? 0
        return RoundedRectangle(cornerRadius: 2)
            .fill(bucket == 0 ? SumiTheme.foregroundWash : SumiTheme.indigo.opacity(Self.heatOpacities[bucket]))
            .frame(width: 11, height: 11)
            .opacity(day == nil ? 0 : 1)
            .help(day.map { tally in
                "\(Self.tooltipFormatter.string(from: tally.date)) — \(tally.episodes) episode\(tally.episodes == 1 ? "" : "s")"
            } ?? "")
    }

    private var legend: some View {
        HStack(spacing: 4) {
            Spacer()
            Text("Less")
                .sumiTabularMono(size: 9)
                .foregroundColor(SumiTheme.muted)
            ForEach(0..<5, id: \.self) { step in
                RoundedRectangle(cornerRadius: 2)
                    .fill(step == 0 ? SumiTheme.foregroundWash : SumiTheme.indigo.opacity(Self.heatOpacities[step]))
                    .frame(width: 11, height: 11)
            }
            Text("More")
                .sumiTabularMono(size: 9)
                .foregroundColor(SumiTheme.muted)
        }
    }

    private func habitCard(_ stats: FfiWatchStats) -> some View {
        card(title: "Habits") {
            // Stated rather than charted: the registry answers with the single
            // busiest hour, not a 24-bucket histogram, and a bar chart of one
            // known value and 23 blanks would be a picture of nothing.
            HStack(spacing: 6) {
                Text("You start episodes most often around")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                Text(String(format: "%02d:00", stats.busiestHour))
                    .sumiTabularMono(size: 13, weight: .bold)
                    .foregroundColor(SumiTheme.indigo)
            }

            if let firstWatch = stats.firstWatchAt {
                // The registry hands back an ISO-8601 stamp; shown raw it read
                // "since 2026-09-05T20:40:22+02:00".
                Text("Watching here since \(Self.longDate(fromISO: firstWatch)).")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted)
            }
        }
    }

    private func topTitlesCard(_ stats: FfiWatchStats) -> some View {
        let rows = Array((recentStats ?? stats).topTitles.prefix(10))
        return card(title: recentStats == nil ? "Most watched" : "Most watched, last 30 days") {
            if rows.isEmpty {
                Text("Nothing watched in the last 30 days.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                topTitleRow(index: index, row: row)
                    .onAppear {
                        if knownTitles[row.catalogId] == nil { onResolveTitle(row.catalogId) }
                    }
            }
        }
    }

    private func topTitleRow(index: Int, row: FfiTitleCount) -> some View {
        let title = knownTitles[row.catalogId]
        return Button {
            onSelectTitle(row.catalogId, title)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: 18, alignment: .trailing)

                CachedAsyncImage(url: knownCovers[row.catalogId], maxPixelSize: 120) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Rectangle().fill(SumiTheme.foregroundWash)
                }
                .frame(width: 32, height: 46)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))

                // A registry row whose title no catalog view has fetched this
                // session shows its id: the alternative is a blank row, and
                // the id is at least the thing the log actually stores.
                Text(title ?? "AniList #\(row.catalogId)")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(title == nil ? SumiTheme.muted : SumiTheme.foreground)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(row.episodes) ep")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)

                Text(String(format: "%.1f h", Double(row.seconds) / 3600))
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: 54, alignment: .trailing)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
    }

    private func yearInReviewCard(_ stats: FfiWatchStats) -> some View {
        let top = stats.topTitles.first.flatMap { knownTitles[$0.catalogId] }
        return card(title: "Year in review") {
            Text(Self.yearInReview(
                hours: Double(stats.totalWatchSeconds) / 3600,
                episodes: Int(stats.episodesWatched),
                titles: Int(stats.titlesStarted),
                longestStreak: Int(stats.longestStreakDays),
                busiestHour: Int(stats.busiestHour),
                topTitle: top
            ))
            .font(.system(size: 13))
            .foregroundColor(SumiTheme.foreground.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(SumiTheme.foreground)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(SumiTheme.card.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}


extension StatsView {
    static func longDate(fromISO iso: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime]
        var date = parser.date(from: iso)
        if date == nil {
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            date = parser.date(from: iso)
        }
        guard let date else { return iso }
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
