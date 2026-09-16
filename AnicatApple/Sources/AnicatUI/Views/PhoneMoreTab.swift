#if os(iOS)
import SwiftUI
import AnicatCoreKit

/// The sidebar sections that did not earn a tab, in the rail's own order.
///
/// A plain list. Each row pushes the section's phone view; Settings moved
/// here from behind the Up Next avatar, which stays as a shortcut because
/// it is where people already look for the account.
struct PhoneMoreTab: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PhoneScheduleView(model: model, showDetail: $showDetail) } label: {
                        Label("Schedule", systemImage: "calendar")
                    }
                    NavigationLink { PhoneHistoryView(model: model, showDetail: $showDetail) } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    NavigationLink { PhoneDownloadsView(model: model) } label: {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    NavigationLink { PhoneStatsView(model: model, showDetail: $showDetail) } label: {
                        Label("Stats", systemImage: "chart.bar")
                    }
                }
                Section {
                    NavigationLink { PhoneSettingsView(model: model) } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(SumiTheme.background)
            .navigationTitle("More")
            .modifier(DetailPush(model: model, isPresented: $showDetail))
        }
    }
}

// MARK: - Schedule

/// The week, one day at a time.
///
/// The Mac's `WeekStrip` draws seven columns side by side; at 402pt that is
/// 50pt a column, one poster wide. Here the days are a row of chips and
/// the picked day's episodes are a list underneath, sorted by air time.
struct PhoneScheduleView: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool
    @AppStorage("anicat_schedule_watching_only") private var watchingOnly = true
    @State private var selectedDay: Date = Calendar.current.startOfDay(for: Date())

    private var calendar: Calendar { Calendar.current }

    private var days: [Date] {
        let today = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    private var items: [ScheduleView.ScheduleItem] {
        let start = selectedDay.timeIntervalSince1970
        let end = (calendar.date(byAdding: .day, value: 1, to: selectedDay) ?? selectedDay).timeIntervalSince1970
        return model.scheduleItems
            .filter { Double($0.airingAt) >= start && Double($0.airingAt) < end }
            .filter { !watchingOnly || $0.isWatching }
            .sorted { $0.airingAt < $1.airingAt }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                dayChips
                // A chip, not a `Toggle`: the switch sat in the scroll view
                // and never took a tap on the simulator, and a chip is what
                // the day row above already is.
                Button {
                    withAnimation(.snappy) { watchingOnly.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: watchingOnly ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Only what I am watching")
                            .font(.system(size: 13, weight: .medium))
                    }
                    .foregroundStyle(watchingOnly ? SumiTheme.background : SumiTheme.foreground)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(watchingOnly ? SumiTheme.indigo : SumiTheme.card, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 16)
                if model.scheduleItems.isEmpty {
                    EmptyHint(title: "No schedule yet", detail: "Airing times load with the home page.")
                } else if items.isEmpty {
                    EmptyHint(
                        title: "Nothing airs \(calendar.isDateInToday(selectedDay) ? "today" : "that day")",
                        detail: watchingOnly ? "Turn off the watching filter to see everything airing." : "Try another day."
                    )
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            Button { open(item) } label: {
                                ScheduleRow(item: item)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(SumiTheme.border).padding(.leading, 72)
                        }
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .background(SumiTheme.background)
        .navigationTitle("Schedule")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refreshAll(showLoading: false) }
    }

    @ViewBuilder
    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { day in
                    let selected = calendar.isDate(day, inSameDayAs: selectedDay)
                    let count = model.scheduleItems.filter {
                        calendar.isDate(Date(timeIntervalSince1970: Double($0.airingAt)), inSameDayAs: day)
                            && (!watchingOnly || $0.isWatching)
                    }.count
                    Button {
                        withAnimation(.snappy) { selectedDay = day }
                    } label: {
                        VStack(spacing: 2) {
                            Text(calendar.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.system(size: 12, weight: .semibold))
                            Text(day.formatted(.dateTime.day()))
                                .font(.system(size: 15, weight: .bold))
                            Text(count == 0 ? " " : "\(count)")
                                .font(.system(size: 10, design: .monospaced))
                                .opacity(0.8)
                        }
                        .foregroundStyle(selected ? SumiTheme.background : SumiTheme.foreground)
                        .frame(width: 58)
                        .padding(.vertical, 8)
                        .background(selected ? SumiTheme.indigo : SumiTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func open(_ item: ScheduleView.ScheduleItem) {
        showDetail = true
        Task { await model.openDetail(id: item.id, title: item.title, coverURL: item.coverImageURL, isManga: false) }
    }
}

private struct ScheduleRow: View {
    let item: ScheduleView.ScheduleItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(url: item.coverImageURL, maxPixelSize: 200) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                SumiTheme.card
            }
            .frame(width: 44, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 15))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("EP \(item.episodeNumber) \u{00B7} \(item.airingTimeText.uppercased()) \u{00B7} \(item.countdownText.uppercased())")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(item.isWatching ? SumiTheme.indigo : SumiTheme.muted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SumiTheme.muted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - History

/// The watch log grouped by day, newest first. Swipe to take a watch back;
/// the Mac's `HistoryView` folds favourites and a 30-day chart in as well,
/// which is a profile page rather than a history and is not reproduced.
struct PhoneHistoryView: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool
    @State private var confirmingClear = false

    private static let parser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private struct DayGroup: Identifiable {
        let day: Date
        let rows: [ActivityRow]
        var id: Date { day }
    }

    private var rows: [ActivityRow] { model.appMode == .cinema ? model.cinemaActivity : model.activity }

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        var buckets: [Date: [ActivityRow]] = [:]
        for row in rows {
            guard let date = Self.parser.date(from: row.watchedAt) else { continue }
            buckets[calendar.startOfDay(for: date), default: []].append(row)
        }
        return buckets.keys.sorted(by: >).map { day in
            DayGroup(day: day, rows: buckets[day]!.sorted { $0.watchedAt > $1.watchedAt })
        }
    }

    var body: some View {
        Group {
            if rows.isEmpty {
                EmptyHint(title: "Nothing watched yet", detail: "Episodes you play show up here, from this device's own log.")
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .background(SumiTheme.background)
            } else {
                List {
                    ForEach(groups) { group in
                        Section(Self.dayLabel(group.day)) {
                            ForEach(group.rows, id: \.self) { row in
                                Button { open(row) } label: { HistoryRowView(row: row, title: title(for: row), time: time(of: row)) }
                                    .buttonStyle(.plain)
                                    .listRowBackground(SumiTheme.card)
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            Task { await model.removeWatch(row) }
                                        } label: {
                                            Label("Remove", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(SumiTheme.background)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !rows.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Clear") { confirmingClear = true }
                }
            }
        }
        .confirmationDialog("Clear the whole watch history on this device?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear history", role: .destructive) {
                Task { await model.clearWatchHistory() }
            }
        } message: {
            Text("AniList progress is not touched.")
        }
        .task { await model.loadHistory() }
    }

    private func title(for row: ActivityRow) -> String {
        model.registryTitle(catalog: row.catalog, id: row.catalogId) ?? "Title \(row.catalogId)"
    }

    private func time(of row: ActivityRow) -> String {
        guard let date = Self.parser.date(from: row.watchedAt) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }

    private static func dayLabel(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private func open(_ row: ActivityRow) {
        showDetail = true
        Task {
            switch row.catalog {
            case .tmdbMovie:
                await model.openCinemaDetail(catalog: .tmdbMovie, id: row.catalogId, title: nil)
            case .tmdbTv:
                await model.openCinemaDetail(catalog: .tmdbTv, id: row.catalogId, title: nil)
            default:
                await model.openDetail(id: row.catalogId, isManga: false)
            }
        }
    }
}

private struct HistoryRowView: View {
    let row: ActivityRow
    let title: String
    let time: String

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15))
                    .foregroundStyle(SumiTheme.foreground)
                    .lineLimit(2)
                Text("\(row.catalog == .tmdbMovie ? "FILM" : "EP \(row.episodeNumber)") \u{00B7} \(time)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(SumiTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SumiTheme.muted)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Stats and Downloads

/// The Mac's `StatsView` fits a phone once its five summary tiles wrap
/// (done in the view itself under `#if os(iOS)`); the heat map already
/// scrolls sideways. Wrapped here only to hand it the model's closures.
struct PhoneStatsView: View {
    @Bindable var model: AppModel
    @Binding var showDetail: Bool

    var body: some View {
        StatsView(
            stats: model.watchStatsSnapshot,
            recentStats: model.watchStatsRecentSnapshot,
            titleFor: { catalog, id in model.registryTitle(catalog: catalog, id: id) },
            coverFor: { catalog, id in model.registryCover(catalog: catalog, id: id) },
            onLoad: { model.loadWatchStats() },
            onSelectTitle: { id, title, catalog in
                showDetail = true
                Task {
                    switch catalog {
                    case .tmdbMovie:
                        await model.openCinemaDetail(catalog: .tmdbMovie, id: id, title: title)
                    case .tmdbTv:
                        await model.openCinemaDetail(catalog: .tmdbTv, id: id, title: title)
                    default:
                        await model.openDetail(id: id, title: title, isManga: false)
                    }
                }
            },
            onResolveTitle: { id in model.ensureKnownTitle(id) }
        )
        .background(SumiTheme.background)
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// `DownloadsView` compiles for iOS and has no fixed widths; the Reveal in
/// Finder button is already behind `#if os(macOS)`.
struct PhoneDownloadsView: View {
    @Bindable var model: AppModel

    var body: some View {
        DownloadsView(
            downloads: model.libraryDownloads,
            onPlay: { download in Task { await model.playDownloadedFile(download) } },
            onRemove: { download in model.libraryDownloads.removeAll { $0.id == download.id } },
            chapters: model.offlineChapters,
            chapterBytes: model.offlineBytes,
            chapterCapBytes: model.offlineCapBytes,
            titles: model.knownTitles,
            onRemoveChapter: { chapter in model.deleteOfflineChapter(chapter) }
        )
        .background(SumiTheme.background)
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .task { model.loadOfflineChapters() }
    }
}
#endif
