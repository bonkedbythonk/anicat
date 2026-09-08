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
    /// Chapters read, merged into the same log and the same day chart.
    ///
    /// A separate list rather than more `ActivityRow`s: that row is keyed by
    /// an episode number, and a chapter has a provider id and a number that
    /// can be fractional. Empty for anyone who reads nothing, which is what
    /// it was for everyone before reading was recorded at all.
    var reading: [ReadingEntry] = []

    /// One chapter read, as this view draws it.
    public struct ReadingEntry: Identifiable, Sendable {
        public var id: String { "\(catalogId):\(chapterId)" }
        public let catalogId: Int64
        public let chapterId: String
        public let chapterNumber: String
        public let readAt: String

        public init(catalogId: Int64, chapterId: String, chapterNumber: String, readAt: String) {
            self.catalogId = catalogId
            self.chapterId = chapterId
            self.chapterNumber = chapterNumber
            self.readAt = readAt
        }
    }
    /// Titles for the ids in the log, as far as they are known from the lists
    /// already loaded. An id with no title still shows, with the id — losing
    /// the row entirely would misreport how much was watched.
    let titles: [Int64: String]
    let namespace: Namespace.ID?
    let openingSourceKey: String?
    let onSelectFavourite: (MediaCard.Item) -> Void
    /// Opens a log row's title. The second argument is the title as this view
    /// resolved it from `titles`, or nil for an id no loaded list has named —
    /// the caller has a catalog fetch and this view does not.
    let onOpenTitle: ((Int64, String?) -> Void)?
    /// Deletes one watch from the registry. Optional, and the menu item is
    /// absent when it is nil: the engine exposes no per-row delete, so
    /// without a caller supplying one there is nothing honest to offer.
    let onRemoveActivity: ((ActivityRow) -> Void)?
    /// Deletes the whole local watch log. Optional for the same reason.
    /// Not `clearLocalRegistry` under another name — that also wipes resume
    /// positions and provider overrides, and is already Settings' action.
    let onClearHistory: (() -> Void)?

    @AppStorage("anicat_time_format") private var timeFormat: String = "24-hour"
    @State private var favouritesType: String = "ANIME"
    @State private var clearConfirming: Bool = false

    public init(
        viewer: ViewerProfile?,
        activity: [ActivityRow],
        reading: [ReadingEntry] = [],
        titles: [Int64: String],
        namespace: Namespace.ID? = nil,
        openingSourceKey: String? = nil,
        onSelectFavourite: @escaping (MediaCard.Item) -> Void = { _ in },
        onOpenTitle: ((Int64, String?) -> Void)? = nil,
        onRemoveActivity: ((ActivityRow) -> Void)? = nil,
        onClearHistory: (() -> Void)? = nil
    ) {
        self.viewer = viewer
        self.activity = activity
        self.reading = reading
        self.titles = titles
        self.namespace = namespace
        self.openingSourceKey = openingSourceKey
        self.onSelectFavourite = onSelectFavourite
        self.onOpenTitle = onOpenTitle
        self.onRemoveActivity = onRemoveActivity
        self.onClearHistory = onClearHistory
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
        for row in reading {
            guard let date = Self.parser.date(from: row.readAt) else { continue }
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
                HStack {
                    SumiSectionHeader("Recent")
                    Spacer()
                    if let onClearHistory, !activity.isEmpty {
                        clearButton(onClearHistory)
                    }
                }
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

    /// The two-step confirm from Settings' maintenance buttons rather than a
    /// dialog. The count goes in the confirm label because this is the one
    /// unrecoverable action on the page and "Clear history" alone does not
    /// say how much is about to go.
    private func clearButton(_ action: @escaping () -> Void) -> some View {
        Button {
            if clearConfirming {
                action()
                clearConfirming = false
            } else {
                clearConfirming = true
            }
        } label: {
            Text(clearConfirming ? "Clear \(activity.count) watches? Click again" : "Clear history")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(SumiTheme.dangerLight)
                .padding(.horizontal, clearConfirming ? 10 : 0)
                .padding(.vertical, 4)
                .background(clearConfirming ? SumiTheme.danger.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                .contentShape(Rectangle())
        }
        .buttonStyle(.sumiPressable)
        .animation(.snappy, value: clearConfirming)
    }

    private var log: some View {
        let stamp = SumiTimeFormatter.historyDateFormatter(timeFormat: timeFormat)
        let entries = mergedLog.prefix(60)
        return VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                switch entry {
                case .watched(let row):
                    logRow(row, stamp: stamp)
                case .read(let row):
                    readingRow(row, stamp: stamp)
                }

                if index < entries.count - 1 {
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

    /// One log line, whichever kind it is.
    private enum LogEntry {
        case watched(ActivityRow)
        case read(ReadingEntry)

        var timestamp: String {
            switch self {
            case .watched(let row): return row.watchedAt
            case .read(let row): return row.readAt
            }
        }
    }

    /// Episodes and chapters in one list, newest first. Both are "what was
    /// read or watched on this device", and two separate logs would make
    /// answering "what was I doing on Tuesday" a comparison between them.
    private var mergedLog: [LogEntry] {
        (activity.map(LogEntry.watched) + reading.map(LogEntry.read))
            .sorted { $0.timestamp > $1.timestamp }
    }

    /// A chapter's line. `CH` rather than `EP`, and the number as text
    /// because chapters number fractionally.
    @ViewBuilder
    private func readingRow(_ row: ReadingEntry, stamp: DateFormatter) -> some View {
        let title = titles[row.catalogId]
        HStack(spacing: 12) {
            Text(title ?? "Media \(row.catalogId)")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
                .lineLimit(1)
            Text("— CH \(row.chapterNumber)")
                .sumiTabularMono(size: 11.5)
                .foregroundColor(SumiTheme.muted)
            Spacer()
            Text(Self.parser.date(from: row.readAt).map { stamp.string(from: $0) } ?? "")
                .sumiTabularMono(size: 11)
                .foregroundColor(SumiTheme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .onTapGesture { onOpenTitle?(row.catalogId, title) }
    }

    @ViewBuilder
    private func logRow(_ row: ActivityRow, stamp: DateFormatter) -> some View {
        // An id no loaded list has named still shows, with the id — dropping
        // the row would misreport how much was watched. It is still openable:
        // the detail page fetches the title this view could not resolve.
        let title = titles[row.catalogId]
        let content = HStack(spacing: 12) {
            Text(title ?? "Media \(row.catalogId)")
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
        .contentShape(Rectangle())

        let tappable = Group {
            if let onOpenTitle {
                Button { onOpenTitle(row.catalogId, title) } label: { content }
                    .buttonStyle(.sumiPressable)
            } else {
                content
            }
        }

        // Attached only when it would have an entry. An unconditional
        // `.contextMenu` with both callbacks nil pops an empty menu on
        // right-click, which reads as a broken row rather than an inert one.
        if onOpenTitle != nil || onRemoveActivity != nil {
            tappable.contextMenu {
                if let onOpenTitle {
                    Button("Open") { onOpenTitle(row.catalogId, title) }
                }
                if let onRemoveActivity {
                    Button("Remove from history", role: .destructive) { onRemoveActivity(row) }
                }
            }
        } else {
            tappable
        }
    }
}
