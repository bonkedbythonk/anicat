import Foundation
import AnicatCoreKit

/// Stand-in personal data for screenshots, on when `ANICAT_SCREENSHOT_MODE`
/// is set in the environment. Catalog data stays real (trending titles,
/// covers, synopses, episode counts); everything that would say what the
/// owner actually watches is replaced: the watching list, the library, the
/// reading shelves, the profile, the watch log, and the list entry on an
/// open detail page. Nothing is written back: `persistHomeCache` skips a
/// snapshot while this is on, and no list mutation is issued by any view
/// under it, so the real account is untouched.
///
/// Built from the trending list rather than a hard-coded set of titles so
/// the covers and counts are whatever AniList has this week and the
/// screenshots do not date.
enum ScreenshotFixtures {
    static let isEnabled = ProcessInfo.processInfo.environment["ANICAT_SCREENSHOT_MODE"] != nil

    private static let now = Int64(Date().timeIntervalSince1970)

    /// Eight titles in progress, staggered from "2h ago" to a few weeks.
    static func watching(from trending: [MediaSummary]) -> [MediaSummary] {
        let fractions: [Double] = [0.3, 0.55, 0.15, 0.8, 0.45, 0.08, 0.65, 0.25]
        let hoursAgo: [Int64] = [2, 5, 26, 30, 50, 75, 120, 200]
        return Array(trending.prefix(8)).enumerated().map { index, summary in
            var s = summary
            let total = s.episodes ?? s.chapters ?? 12
            s.listStatus = "CURRENT"
            s.progress = max(1, Int32((Double(total) * fractions[index]).rounded()))
            s.userScore = nil
            s.updatedAt = now - hoursAgo[index] * 3600
            return s
        }
    }

    /// One AniList list by status, carved out of the same trending order so
    /// no title appears under two statuses.
    static func list(status: String?, from trending: [MediaSummary]) -> [MediaSummary] {
        func slice(_ range: Range<Int>, status: String, progress: (MediaSummary) -> Int32?, score: (Int) -> Double?) -> [MediaSummary] {
            let lower = min(range.lowerBound, trending.count), upper = min(range.upperBound, trending.count)
            return Array(trending[lower..<upper]).enumerated().map { index, summary in
                var s = summary
                s.listStatus = status
                s.progress = progress(s)
                s.userScore = score(index)
                s.updatedAt = now - Int64(range.lowerBound + index) * 40 * 3600
                return s
            }
        }
        switch status {
        case "CURRENT":
            return watching(from: trending)
        case "COMPLETED":
            return slice(8..<18, status: "COMPLETED", progress: { $0.episodes ?? $0.chapters }, score: { [8, 9, 7, 8, 10, 7, 9, 8, 6, 8][$0 % 10] })
        case "PLANNING":
            return slice(18..<24, status: "PLANNING", progress: { _ in 0 }, score: { _ in nil })
        case "PAUSED":
            return slice(6..<8, status: "PAUSED", progress: { ($0.episodes ?? 12) / 3 }, score: { _ in nil })
        case "REPEATING":
            return slice(8..<9, status: "REPEATING", progress: { _ in 3 }, score: { _ in 9 })
        case "DROPPED":
            return []
        default:
            return ["CURRENT", "COMPLETED", "PLANNING", "PAUSED"].flatMap { list(status: $0, from: trending) }
        }
    }

    static func profile(favourites: [MediaSummary], favouriteManga: [MediaSummary]) -> ViewerProfile {
        ViewerProfile(
            name: "Yuki",
            avatarUrl: nil,
            bannerUrl: nil,
            animeCount: 142,
            episodesWatched: 2318,
            minutesWatched: 55_632,
            animeMeanScore: 7.8,
            mangaCount: 31,
            chaptersRead: 1904,
            mangaMeanScore: 7.5,
            topGenres: ["Action", "Fantasy", "Slice of Life", "Comedy", "Drama"],
            favouriteAnime: Array(favourites.prefix(4)),
            favouriteManga: Array(favouriteManga.prefix(2))
        )
    }

    /// A watch log to match the watching list: the last three episodes of
    /// each title, most recent first, in the `YYYY-MM-DD HH:MM:SS` UTC form
    /// the registry writes.
    static func activity(for watching: [MediaSummary]) -> [ActivityRow] {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        var rows: [ActivityRow] = []
        for summary in watching {
            let latest = Int64(summary.progress ?? 1)
            let watchedAt = summary.updatedAt ?? now
            for back in 0..<3 where latest - Int64(back) >= 1 {
                rows.append(ActivityRow(
                    catalog: .anilist,
                    catalogId: summary.catalogId,
                    episodeNumber: latest - Int64(back),
                    watchedAt: formatter.string(from: Date(timeIntervalSince1970: TimeInterval(watchedAt - Int64(back) * 86_400)))
                ))
            }
        }
        return rows.sorted { $0.watchedAt > $1.watchedAt }
    }

    /// A year of watch statistics with a believable rhythm: most evenings
    /// one or two episodes, weekends more, a few gaps. Deterministic, so two
    /// screenshots taken a day apart agree.
    static func watchStats(days: Int, topTitleIDs: [Int64]) -> FfiWatchStats {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        var perDay: [FfiDayCount] = []
        var episodes: Int32 = 0
        var seconds: Int64 = 0
        var streak = 0, longest = 0
        for back in stride(from: days - 1, through: 0, by: -1) {
            let date = calendar.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            let weekday = calendar.component(.weekday, from: date)
            // A cheap hash of the day index picks the count; weekends lean
            // higher and one week in five is skipped entirely.
            let hash = (back * 2654435761) % 97
            var count: Int32 = hash < 30 ? 0 : hash < 70 ? 1 : hash < 88 ? 2 : 3
            if weekday == 1 || weekday == 7, count > 0 { count += 1 }
            if (back / 7) % 5 == 3 { count = 0 }
            if count > 0 { streak += 1; longest = max(longest, streak) } else { streak = 0 }
            episodes += count
            seconds += Int64(count) * 1_420
            perDay.append(FfiDayCount(date: formatter.string(from: date), episodes: count, seconds: Int64(count) * 1_420))
        }
        let counts: [Int32] = [14, 11, 9, 7, 6, 4, 3, 2]
        let topTitles = topTitleIDs.prefix(8).enumerated().map { index, id in
            FfiTitleCount(catalog: .anilist, catalogId: id, episodes: counts[index], seconds: Int64(counts[index]) * 1_420)
        }
        let first = calendar.date(byAdding: .day, value: -(days - 1), to: Date()) ?? Date()
        return FfiWatchStats(
            totalWatchSeconds: seconds,
            episodesWatched: episodes,
            titlesStarted: Int32(min(topTitleIDs.count, 8) + days / 30),
            perDay: perDay,
            currentStreakDays: Int32(streak),
            longestStreakDays: Int32(longest),
            topTitles: topTitles,
            busiestHour: 21,
            firstWatchAt: ISO8601DateFormatter().string(from: first)
        )
    }

    /// The list entry an open detail page shows: partway through, unscored.
    static func listEntry(episodeCount: Int?) -> (status: String, progress: Int, resumeEpisode: Int, resumeSeconds: Int) {
        let progress = max(1, min(7, (episodeCount ?? 12) - 1))
        return ("CURRENT", progress, progress + 1, 412)
    }
}
