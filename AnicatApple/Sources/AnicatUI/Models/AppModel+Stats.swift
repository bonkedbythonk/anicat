// AppModel, on-demand screens: the Stats page's registry snapshot and the
// schedule calendar's per-month airing windows. Neither is part of
// `refreshAll` — both are paid for when their screen is opened, and the
// calendar's month cache is what keeps paging back and forth free.

import Foundation
import AnicatCoreKit

extension AppModel {
    /// `"YYYY-MM"` for the month `date` falls in. Built by hand rather than
    /// through a `DateFormatter` so it cannot pick up a non-Gregorian
    /// calendar or a localized numbering system and stop matching itself
    /// across a locale change.
    nonisolated static func calendarMonthKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", parts.year ?? 0, parts.month ?? 0)
    }

    /// Fills `calendarMonths` for the month `month` falls in, once.
    ///
    /// The window runs a week past each end of the month because the grid's
    /// first and last rows are padded with the neighbouring months' days, and
    /// those cells are drawn with their slots like any other. Without the
    /// overhang they came up empty and the last week of a month looked like
    /// nothing was airing.
    public func loadCalendarMonth(_ month: Date) async {
        guard let engine else { return }
        let calendar = Calendar.current
        let key = Self.calendarMonthKey(month, calendar: calendar)
        guard calendarMonths[key] == nil, !calendarLoadingMonths.contains(key) else { return }

        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)),
              let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart),
              let from = calendar.date(byAdding: .day, value: -7, to: monthStart),
              let to = calendar.date(byAdding: .day, value: 7, to: monthEnd) else { return }

        calendarLoadingMonths.insert(key)
        defer { calendarLoadingMonths.remove(key) }
        do {
            let slots = try await engine.airingSchedule(
                fromUnix: Int64(from.timeIntervalSince1970),
                toUnix: Int64(to.timeIntervalSince1970)
            )
            await recordAniListSuccess()
            calendarMonths[key] = slots
        } catch {
            // Deliberately leaves the key unset: caching the empty result
            // would make one failed request mean the month stays blank for
            // the rest of the session, with no way to ask again.
            await recordAniListFailure(error)
        }
    }

    /// The Stats page's snapshot. Synchronous — `watchStats` reads the local
    /// registry and never touches the network — so there is no loading state
    /// to carry and nothing to cancel.
    ///
    /// Called when the Stats section opens, and only there. The obvious other
    /// trigger, "after progress is recorded", would have to hook
    /// `recordProgress` inside the playback path; the numbers are a day's
    /// resolution in every panel but the streak, so reloading on open is what
    /// the page actually needs.
    public func loadWatchStats() {
        guard let engine else { return }
        if ScreenshotFixtures.isEnabled {
            // The registry is the owner's real watch log, shared with the
            // test bundle; the Stats page is fixture data like the shelves.
            let ids = watchingItems.map(\.id)
            watchStatsSnapshot = ScreenshotFixtures.watchStats(days: 365, topTitleIDs: ids)
            watchStatsRecentSnapshot = ScreenshotFixtures.watchStats(days: 30, topTitleIDs: Array(ids.dropFirst(2)) + Array(ids.prefix(2)))
            return
        }
        // Cinema mode asks about films and series alone. A Stats page
        // answering about anime while the app is showing films is not a
        // mixed view, it is a wrong one -- the registry holds both.
        let catalogs: [FfiCatalog] = appMode == .cinema ? [.tmdbMovie, .tmdbTv] : [.anilist]
        watchStatsSnapshot = try? engine.watchStats(days: 365, catalogs: catalogs)
        watchStatsRecentSnapshot = try? engine.watchStats(days: 30, catalogs: catalogs)
    }

    /// Fetches the title and cover of a registry row no shelf has loaded, so
    /// the Stats page can name it instead of printing "AniList #177552".
    /// One lookup per id per session; the detail call is cached by core.
    /// Chapters read, for the History log. Local like the watch log, and
    /// like it needing no token: the registry recorded it.
    @MainActor
    public func loadReadingActivity() {
        guard let engine else { return }
        let rows = (try? engine.readingActivity(limit: 120)) ?? []
        readingActivity = rows.map {
            HistoryView.ReadingEntry(
                catalogId: $0.catalogId,
                chapterId: $0.chapterId,
                chapterNumber: $0.chapterNumber,
                readAt: $0.readAt
            )
        }
        // The log names titles out of `knownTitles`, which is filled from
        // whatever shelves have loaded -- a manga read months ago may be on
        // none of them.
        for row in readingActivity where knownTitles[row.catalogId] == nil {
            ensureKnownTitle(row.catalogId)
        }
    }

    @MainActor
    public func ensureKnownTitle(_ id: Int64) {
        guard let engine, knownTitles[id] == nil, !pendingTitleLookups.contains(id) else { return }
        pendingTitleLookups.insert(id)
        Task { @MainActor [weak self] in
            guard let self else { return }
            guard let detail = try? await engine.mediaDetail(catalogId: id, isManga: false) else { return }
            self.resolvedTitles[id] = detail.title
            if let cover = URL(string: detail.coverImage) { self.resolvedCovers[id] = cover }
            self.syncKnownTitles()
        }
    }
}
