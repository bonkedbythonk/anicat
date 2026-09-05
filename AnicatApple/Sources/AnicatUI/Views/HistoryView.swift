import SwiftUI
import AnicatCoreKit

/// History: what the registry has been quietly recording all along — a
/// per-day activity chart, a plain log, and the AniList lifetime totals.
///
/// The log needs no token. Only the profile header does, which is why the two
/// halves degrade independently rather than the page being all-or-nothing.
public struct HistoryView: View {
    let viewer: ViewerProfile?
    let activity: [ActivityRow]
    /// Titles for the ids in the log, as far as they are known from the lists
    /// already loaded. An id with no title still shows, with the id — losing
    /// the row entirely would misreport how much was watched.
    let titles: [Int64: String]
    let namespace: Namespace.ID?
    let openingSourceKey: String?
    let onSelectFavourite: (MediaCard.Item) -> Void

    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @State private var favouritesType: String = "ANIME"

    public init(
        viewer: ViewerProfile?,
        activity: [ActivityRow],
        titles: [Int64: String],
        namespace: Namespace.ID? = nil,
        openingSourceKey: String? = nil,
        onSelectFavourite: @escaping (MediaCard.Item) -> Void = { _ in }
    ) {
        self.viewer = viewer
        self.activity = activity
        self.titles = titles
        self.namespace = namespace
        self.openingSourceKey = openingSourceKey
        self.onSelectFavourite = onSelectFavourite
    }

    /// SQLite writes `YYYY-MM-DD HH:MM:SS` in UTC.
    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private struct Bar: Identifiable {
        let id: Int
        let day: Int
        let count: Int
        let isToday: Bool
    }

    /// The last 30 days as labelled bars. Absolute counts, not a heat scale —
    /// a colour ramp needs a legend to decode and a bar does not.
    private var bars: [Bar] {
        var counts: [String: Int] = [:]
        let key = DateFormatter()
        key.dateFormat = "yyyy-MM-dd"
        for row in activity {
            guard let date = Self.parser.date(from: row.watchedAt) else { continue }
            counts[key.string(from: date), default: 0] += 1
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return (0..<30).reversed().enumerated().map { index, offset in
            let date = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            return Bar(
                id: index,
                day: calendar.component(.day, from: date),
                count: counts[key.string(from: date)] ?? 0,
                isToday: offset == 0
            )
        }
    }

    private var thisWeek: Int { bars.suffix(7).reduce(0) { $0 + $1.count } }
    private var thisMonth: Int { bars.reduce(0) { $0 + $1.count } }

    public var body: some View {
        SumiPage {
            if let viewer {
                profileHeader(viewer)
            } else {
                SumiPageHeader(
                    title: "History",
                    subtitle: "\(activity.count) watches recorded on this device"
                )
            }

            VStack(alignment: .leading, spacing: 12) {
                SumiSectionHeader(
                    "Last 30 days",
                    trailing: "\(thisWeek) this week · \(thisMonth) this month"
                )
                chart
            }
            .padding(.top, 12)

            VStack(alignment: .leading, spacing: 12) {
                SumiSectionHeader("Recent")
                if activity.isEmpty {
                    SumiEmptyState(
                        headline: "Nothing watched yet",
                        detail: "Episodes you play are logged here, signed in or not."
                    )
                } else {
                    log
                }
            }
            .padding(.top, 12)

            if let viewer, !viewer.favouriteAnime.isEmpty || !viewer.favouriteManga.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        SumiSectionHeader("Favorites")
                        Spacer()
                        SumiSegmentedControl(
                            options: [("ANIME", "Anime"), ("MANGA", "Manga")],
                            selection: $favouritesType
                        )
                    }
                    favourites(for: viewer)
                }
                .padding(.top, 12)
            }
        }
    }

    private func favourites(for viewer: ViewerProfile) -> some View {
        let items = (favouritesType == "MANGA" ? viewer.favouriteManga : viewer.favouriteAnime).map(AppModel.card)
        return Group {
            if items.isEmpty {
                SumiEmptyState(
                    headline: favouritesType == "MANGA" ? "No favorite manga yet" : "No favorite anime yet",
                    detail: "Heart a title from its detail page and it shows up here."
                )
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 165, maximum: 200), spacing: 20, alignment: .top)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(items) { item in
                        MediaCard(
                            item: item,
                            namespace: openingSourceKey == "history-fav:\(item.id)" ? namespace : nil
                        ) {
                            onSelectFavourite(item)
                        }
                    }
                }
            }
        }
        .animation(.smooth, value: favouritesType)
    }

    private func profileHeader(_ viewer: ViewerProfile) -> some View {
        HStack(spacing: 16) {
            AsyncImage(url: viewer.avatarUrl.flatMap(URL.init(string:))) { phase in
                if let image = phase.image {
                    image.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Rectangle().fill(SumiTheme.card)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))

            VStack(alignment: .leading, spacing: 6) {
                Text(viewer.name)
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(SumiTheme.foreground)
                Text(statsLine(viewer))
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }
            Spacer()
        }
    }

    private func statsLine(_ v: ViewerProfile) -> String {
        var parts: [String] = []
        if let minutes = v.minutesWatched, minutes > 0 {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            parts.append("\(days)d \(hours)h watched")
        }
        if let eps = v.episodesWatched { parts.append("\(eps) episodes") }
        if let chapters = v.chaptersRead { parts.append("\(chapters) chapters") }
        if let anime = v.animeCount { parts.append("\(anime) anime") }
        if let manga = v.mangaCount { parts.append("\(manga) manga") }
        return parts.joined(separator: " · ")
    }

    private var chart: some View {
        let rows = bars
        let peak = max(rows.map(\.count).max() ?? 1, 1)
        return VStack(spacing: 8) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(rows) { bar in
                    VStack(spacing: 4) {
                        // The count sits above the bar rather than inside it:
                        // at one or two watches the bar is too short to hold
                        // a legible label.
                        Text(bar.count > 0 ? "\(bar.count)" : " ")
                            .sumiTabularMono(size: 9)
                            .foregroundColor(SumiTheme.muted)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(bar.isToday ? SumiTheme.indigo : SumiTheme.indigo.opacity(0.55))
                            .frame(height: max(CGFloat(bar.count) / CGFloat(peak) * 90, bar.count > 0 ? 4 : 2))
                            .opacity(bar.count > 0 ? 1 : 0.25)
                        Text(bar.isToday ? "now" : (bar.day % 5 == 0 ? "\(bar.day)" : " "))
                            .sumiTabularMono(size: 9)
                            .foregroundColor(bar.isToday ? SumiTheme.indigo : SumiTheme.muted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(16)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private var log: some View {
        let stamp = SumiTimeFormatter.historyDateFormatter(timeFormat: timeFormat)
        return VStack(spacing: 0) {
            ForEach(Array(activity.prefix(60).enumerated()), id: \.offset) { index, row in
                HStack(spacing: 12) {
                    Text(titles[row.catalogId] ?? "Media \(row.catalogId)")
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)
                        .lineLimit(1)
                    Text("— EP \(row.episodeNumber)")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                    Spacer(minLength: 12)
                    Text(Self.parser.date(from: row.watchedAt).map { stamp.string(from: $0) } ?? "")
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                if index < min(activity.count, 60) - 1 {
                    Rectangle().fill(SumiTheme.border).frame(height: 1)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusLg))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusLg)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}
