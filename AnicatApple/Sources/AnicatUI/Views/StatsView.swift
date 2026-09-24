import SwiftUI
import Charts
import AnicatCoreKit

/// What the local registry knows about a year of watching: one sentence with
/// the headline, hours per month, the hours of the day, the titles that took
/// the most of it, and a plain-language summary.
///
/// Everything here comes out of `watchStats`, which reads the registry and
/// never the network — so this page works signed out and during an AniList
/// outage, which is most of the reason it is worth having.
public struct StatsView: View {
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

    private struct MonthHours: Identifiable {
        let month: Date
        let hours: Double
        var id: Date { month }
    }

    let stats: FfiWatchStats?
    /// Names and covers for the top-titles list. `FfiTitleCount` carries an
    /// id and nothing else — the registry never learns what a show is called —
    /// so the name has to come from whatever the catalog views have loaded.
    /// Both take the row's catalog: see `HistoryView.titleFor` for why an
    /// id alone cannot name a title.
    let titleFor: (FfiCatalog, Int64) -> String?
    let coverFor: (FfiCatalog, Int64) -> URL?
    /// The 30-day window behind the "most watched" card; the year-long
    /// `stats` feeds everything else.
    let recentStats: FfiWatchStats?
    let onLoad: () -> Void
    let onSelectTitle: (Int64, String?, FfiCatalog) -> Void
    let onResolveTitle: (Int64) -> Void

    public init(
        stats: FfiWatchStats?,
        recentStats: FfiWatchStats? = nil,
        titleFor: @escaping (FfiCatalog, Int64) -> String? = { _, _ in nil },
        coverFor: @escaping (FfiCatalog, Int64) -> URL? = { _, _ in nil },
        onLoad: @escaping () -> Void = {},
        onSelectTitle: @escaping (Int64, String?, FfiCatalog) -> Void = { _, _, _ in },
        onResolveTitle: @escaping (Int64) -> Void = { _ in }
    ) {
        self.stats = stats
        self.recentStats = recentStats
        self.titleFor = titleFor
        self.coverFor = coverFor
        self.onLoad = onLoad
        self.onSelectTitle = onSelectTitle
        self.onResolveTitle = onResolveTitle
    }

    /// `perDay` summed by month. It is the last 365 days, not a calendar
    /// year, so both ends are the same month partly: bucketing by month name
    /// rather than by the month's first day folded the two into one bar.
    /// Untouched days are present and zeroed, so every month gets a bar.
    private func monthHours(_ stats: FfiWatchStats) -> [MonthHours] {
        let calendar = Calendar.current
        var order: [Date] = []
        var seconds: [Date: Int64] = [:]
        for row in stats.perDay {
            guard let day = Self.dayParser.date(from: row.date),
                  let month = calendar.dateInterval(of: .month, for: day)?.start else { continue }
            if seconds[month] == nil { order.append(month) }
            seconds[month, default: 0] += row.seconds
        }
        return order.map { MonthHours(month: $0, hours: Double(seconds[$0] ?? 0) / 3600) }
    }

    public var body: some View {
        GeometryReader { viewport in
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: SumiTheme.spaceLg) {
                header

                if let stats, stats.episodesWatched > 0 || stats.totalWatchSeconds > 0 {
                    let months = monthHours(stats)
                    summary(stats, months: months)
                    monthChart(months)
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
            // The page gutters and column every other section uses; at 24pt
            // and pinned left, Stats started to the left of its neighbours.
            .padding(.horizontal, 40)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: SumiContentWidth.forAvailable(viewport.size.width), alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        }
        .background(SumiTheme.background)
        .onAppear(perform: onLoad)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stats")
                .font(.sumiHeading(size: 28, weight: .bold))
                .foregroundColor(SumiTheme.foreground)
            Text("The last 365 days, from this device's own watch log.")
                .font(.system(size: 14))
                .foregroundColor(SumiTheme.muted)
        }
    }

    /// "In the last year", not "this year": `totalWatchSeconds` and `perDay`
    /// are a rolling 365 days, and in March "this year" would claim ten
    /// months of last year's watching.
    private func summary(_ stats: FfiWatchStats, months: [MonthHours]) -> some View {
        let hours = Double(stats.totalWatchSeconds) / 3600
        let hoursText = hours < 10 ? String(format: "%.1f", hours) : String(format: "%.0f", hours)
        let titles = Int(stats.titlesStarted)
        let busiest = months.max(by: { $0.hours < $1.hours }).flatMap { $0.hours > 0 ? $0.month : nil }
        let accent = { (text: String) in Text(text).bold().foregroundStyle(SumiTheme.indigo) }
        let tail = busiest.map { ", most of it in \($0.formatted(.dateTime.month(.wide)))." } ?? "."
        return Text("You watched \(accent("\(hoursText) hours")) across \(accent("\(titles) title\(titles == 1 ? "" : "s")")) in the last year\(tail)")
            .font(.system(size: 17))
            .foregroundStyle(SumiTheme.foreground)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func monthChart(_ months: [MonthHours]) -> some View {
        Chart(months) { month in
            BarMark(
                x: .value("Month", month.month, unit: .month),
                y: .value("Hours", month.hours)
            )
            .foregroundStyle(SumiTheme.indigo.opacity(0.7))
            .cornerRadius(2)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .month)) { _ in
                AxisValueLabel(format: .dateTime.month(.abbreviated), centered: true)
                    .font(.system(size: 10))
                    .foregroundStyle(SumiTheme.muted)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisValueLabel {
                    if let hours = value.as(Double.self) {
                        // Whole hours read "0 h" on every tick of a first
                        // week, when the axis runs 0.2, 0.4, 0.6.
                        Text(hours < 10 ? String(format: "%.1f h", hours) : "\(Int(hours)) h")
                            .sumiTabularMono(size: 10)
                            .foregroundColor(SumiTheme.muted)
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) {
                Rectangle().fill(SumiTheme.border).frame(height: 1)
            }
        }
        .frame(height: 160)
    }

    private func habitCard(_ stats: FfiWatchStats) -> some View {
        card(title: "Habits") {
            HStack(spacing: 6) {
                Text("You start episodes most often around")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                Text(String(format: "%02d:00", stats.busiestHour))
                    .sumiTabularMono(size: 13, weight: .bold)
                    .foregroundColor(SumiTheme.indigo)
            }

            if stats.byHour.count == 24, stats.byHour.contains(where: { $0 > 0 }) {
                hourChart(stats.byHour, busiest: Int(stats.busiestHour))
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

    /// Episodes started per hour of the day, the busiest hour in full
    /// accent. Drawn like the History page's 30-day bars, 48pt tall: the
    /// card is a sentence with a picture under it, not a page of its own.
    private func hourChart(_ byHour: [Int32], busiest: Int) -> some View {
        let peak = max(byHour.max() ?? 1, 1)
        return VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let count = byHour[hour]
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(hour == busiest ? SumiTheme.indigo : SumiTheme.indigo.opacity(0.45))
                        .frame(height: max(CGFloat(count) / CGFloat(peak) * 48, count > 0 ? 3 : 2))
                        .opacity(count > 0 ? 1 : 0.25)
                        .frame(maxWidth: .infinity)
                        .help("\(count) episode\(count == 1 ? "" : "s") started at \(String(format: "%02d:00", hour))")
                }
            }
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    Text(hour % 6 == 0 ? String(format: "%02d", hour) : " ")
                        .sumiTabularMono(size: 9)
                        .foregroundColor(hour == busiest ? SumiTheme.indigo : SumiTheme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 4)
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
                        if titleFor(row.catalog, row.catalogId) == nil { onResolveTitle(row.catalogId) }
                    }
            }
        }
    }

    private func topTitleRow(index: Int, row: FfiTitleCount) -> some View {
        let title = titleFor(row.catalog, row.catalogId)
        return Button {
            onSelectTitle(row.catalogId, title, row.catalog)
        } label: {
            HStack(spacing: 10) {
                Text("\(index + 1)")
                    .sumiTabularMono(size: 11)
                    .foregroundColor(SumiTheme.muted)
                    .frame(width: 18, alignment: .trailing)

                CachedAsyncImage(url: coverFor(row.catalog, row.catalogId), maxPixelSize: 120) { image in
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
                    .font(.sumiHeading(size: 13, weight: .medium))
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
        let top = stats.topTitles.first.flatMap { titleFor($0.catalog, $0.catalogId) }
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

    /// A section under a hairline, not a filled and stroked box.
    @ViewBuilder
    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.sumiHeading(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundColor(SumiTheme.foreground)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 16)
        .overlay(alignment: .top) {
            Rectangle().fill(SumiTheme.border).frame(height: 1)
        }
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
