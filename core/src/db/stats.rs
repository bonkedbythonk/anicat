//! Watch statistics, aggregated out of the local registry.
//!
//! Nothing here touches the network: AniList counts whole episodes and knows
//! nothing about when in the day they were watched, so a calendar, a streak
//! and an hour histogram can only come from `watch_history`.
//!
//! `aggregate` is generic over the timezone rather than reaching for
//! `chrono::Local` itself. Every boundary that matters here is a *local*
//! midnight — a streak, a per-day bucket, a busiest hour — so a function that
//! read the host's zone could only be tested in the zone the test machine
//! happens to be in, and the month-boundary case below would pass or fail by
//! geography.

use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Datelike, Days, NaiveDate, TimeZone, Timelike};

/// The share of an episode that counts as having watched it. The same 85% the
/// player uses to advance AniList progress and the detail page uses to tick an
/// episode off, so "watched" means one thing across the app.
pub const WATCHED_FRACTION: f64 = 0.85;

/// The widest window `aggregate` will build day buckets for. A caller asking
/// for a decade gets five years of rows rather than 3650 allocations of
/// nothing.
const MAX_DAYS: i32 = 1826;

const TOP_TITLES: usize = 10;

/// One row of `watch_history`, with its timestamp already parsed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProgressRow {
    pub catalog: String,
    pub catalog_id: i64,
    pub episode_number: i64,
    pub stop_time: i64,
    pub duration: i64,
    /// Migration 5's sticky flag. A rewatch resets `stop_time`, so the
    /// percentage alone stopped counting episodes that had genuinely been
    /// finished.
    pub completed: bool,
    pub watched_at: DateTime<chrono::Utc>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DayCount {
    /// `YYYY-MM-DD` in the caller's timezone.
    pub date: String,
    pub episodes: i32,
    pub seconds: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TitleCount {
    pub catalog: String,
    pub catalog_id: i64,
    pub episodes: i32,
    pub seconds: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WatchStats {
    pub total_watch_seconds: i64,
    pub episodes_watched: i32,
    /// Distinct titles with any playback recorded at all. A title opened for
    /// four seconds and abandoned counts — "started" is meant literally, and
    /// unlike `episodes_watched` there is no 85% gate here.
    pub titles_started: i32,
    /// Oldest first, ending on the day `now` falls in, with the days nothing
    /// was watched on present and zeroed — a calendar strip has to draw the
    /// gaps.
    ///
    /// `episodes` here counts every episode touched that day, not only the
    /// ones passed 85%: a day spent half-watching three episodes is a day the
    /// viewer watched anime, and it must not read as empty or break a streak.
    /// `episodes_watched` above is the 85% count and is deliberately smaller.
    pub per_day: Vec<DayCount>,
    pub current_streak_days: i32,
    pub longest_streak_days: i32,
    pub top_titles: Vec<TitleCount>,
    /// 0-23, in the caller's timezone. 0 when there is no history at all.
    pub busiest_hour: i32,
    pub first_watch_at: Option<String>,
}

/// Seconds this row is worth.
///
/// Capped at the episode's own length because `stop_time` is the last position
/// the player reported, and a position is not a guarantee of a runtime: the
/// duration is the denominator every watched-percentage in the app is computed
/// against, so a row must never be able to contribute more time than the
/// episode runs. A row whose duration was never reported (the player had not
/// read it yet) has no cap to apply and keeps its raw position rather than
/// counting as zero.
fn row_seconds(row: &ProgressRow) -> i64 {
    let stop = row.stop_time.max(0);
    if row.duration > 0 {
        stop.min(row.duration)
    } else {
        stop
    }
}

fn is_watched(row: &ProgressRow) -> bool {
    row.completed
        || (row.duration > 0 && (row.stop_time as f64 / row.duration as f64) >= WATCHED_FRACTION)
}

/// Longest run of consecutive dates in `active`.
fn longest_run(active: &HashSet<NaiveDate>) -> i32 {
    let mut longest = 0i32;
    for day in active {
        // Only count from the start of a run, so a run of n days is walked
        // once instead of once per day it contains.
        if day.checked_sub_days(Days::new(1)).is_some_and(|d| active.contains(&d)) {
            continue;
        }
        let mut run = 0i32;
        let mut cursor = *day;
        while active.contains(&cursor) {
            run += 1;
            match cursor.checked_add_days(Days::new(1)) {
                Some(next) => cursor = next,
                None => break,
            }
        }
        longest = longest.max(run);
    }
    longest
}

/// Run of consecutive days ending today, or ending yesterday when today has
/// nothing yet.
///
/// The grace day is the point: without it a streak the viewer has kept for
/// three weeks reads as zero every morning until they watch something, which
/// is exactly the moment the number is supposed to be encouraging.
fn current_run(active: &HashSet<NaiveDate>, today: NaiveDate) -> i32 {
    let mut cursor = if active.contains(&today) {
        today
    } else {
        match today.checked_sub_days(Days::new(1)) {
            Some(yesterday) if active.contains(&yesterday) => yesterday,
            _ => return 0,
        }
    };
    let mut run = 0i32;
    while active.contains(&cursor) {
        run += 1;
        match cursor.checked_sub_days(Days::new(1)) {
            Some(prev) => cursor = prev,
            None => break,
        }
    }
    run
}

pub fn aggregate<Tz>(rows: &[ProgressRow], days: i32, now: &DateTime<Tz>) -> WatchStats
where
    Tz: TimeZone,
    Tz::Offset: std::fmt::Display,
{
    let tz = now.timezone();
    let today = now.date_naive();

    let mut total_watch_seconds = 0i64;
    let mut episodes_watched = 0i32;
    let mut titles: HashSet<(&str, i64)> = HashSet::new();
    let mut per_title: HashMap<(&str, i64), TitleCount> = HashMap::new();
    let mut by_day: HashMap<NaiveDate, (i32, i64)> = HashMap::new();
    let mut by_hour = [0i32; 24];
    let mut first_watch: Option<DateTime<chrono::Utc>> = None;

    for row in rows {
        let seconds = row_seconds(row);
        total_watch_seconds += seconds;
        if is_watched(row) {
            episodes_watched += 1;
        }
        let title_key = (row.catalog.as_str(), row.catalog_id);
        titles.insert(title_key);
        let entry = per_title.entry(title_key).or_insert_with(|| TitleCount {
            catalog: row.catalog.clone(),
            catalog_id: row.catalog_id,
            episodes: 0,
            seconds: 0,
        });
        entry.episodes += 1;
        entry.seconds += seconds;

        let local = row.watched_at.with_timezone(&tz);
        let day = by_day.entry(local.date_naive()).or_insert((0, 0));
        day.0 += 1;
        day.1 += seconds;
        by_hour[local.hour() as usize] += 1;

        if first_watch.is_none_or(|f| row.watched_at < f) {
            first_watch = Some(row.watched_at);
        }
    }

    let window = days.clamp(1, MAX_DAYS);
    let mut per_day = Vec::with_capacity(window as usize);
    for back in (0..window).rev() {
        let Some(date) = today.checked_sub_days(Days::new(back as u64)) else {
            continue;
        };
        let (episodes, seconds) = by_day.get(&date).copied().unwrap_or((0, 0));
        per_day.push(DayCount {
            date: format!("{:04}-{:02}-{:02}", date.year(), date.month(), date.day()),
            episodes,
            seconds,
        });
    }

    // Streaks read the whole history, not the window: a 40-day streak is
    // still 40 days when the caller only asked to draw the last week.
    let active: HashSet<NaiveDate> = by_day.keys().copied().collect();

    let mut top_titles: Vec<TitleCount> = per_title.into_values().collect();
    // The id tie-break is what keeps two titles with identical totals from
    // swapping rows on every call — `per_title` is a HashMap and hands them
    // over in hash order.
    top_titles.sort_by(|a, b| {
        b.seconds
            .cmp(&a.seconds)
            .then(b.episodes.cmp(&a.episodes))
            .then(a.catalog_id.cmp(&b.catalog_id))
    });
    top_titles.truncate(TOP_TITLES);

    let busiest_hour = by_hour
        .iter()
        .enumerate()
        .max_by_key(|(hour, count)| (**count, std::cmp::Reverse(*hour)))
        .map(|(hour, _)| hour as i32)
        .unwrap_or(0);

    WatchStats {
        total_watch_seconds,
        episodes_watched,
        titles_started: titles.len() as i32,
        per_day,
        current_streak_days: current_run(&active, today),
        longest_streak_days: longest_run(&active),
        top_titles,
        busiest_hour,
        first_watch_at: first_watch.map(|f| f.with_timezone(&tz).to_rfc3339()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::FixedOffset;

    /// UTC+9. Every test runs in a zone that is not the machine's, so a
    /// regression that reads the host's clock cannot pass by accident.
    fn tz() -> FixedOffset {
        FixedOffset::east_opt(9 * 3600).unwrap()
    }

    fn at(local: &str) -> DateTime<chrono::Utc> {
        DateTime::parse_from_rfc3339(local).unwrap().with_timezone(&chrono::Utc)
    }

    fn now(local: &str) -> DateTime<FixedOffset> {
        DateTime::parse_from_rfc3339(local).unwrap().with_timezone(&tz())
    }

    fn row(catalog_id: i64, episode: i64, stop: i64, duration: i64, when: &str) -> ProgressRow {
        ProgressRow {
            catalog: "anilist".into(),
            catalog_id,
            episode_number: episode,
            stop_time: stop,
            duration,
            // The fixtures set positions, not the sticky flag: `is_watched`
            // must still read the percentage for rows written before
            // migration 5 added the column.
            completed: false,
            watched_at: at(when),
        }
    }

    #[test]
    fn a_streak_runs_across_a_month_boundary() {
        // Jan 30, 31, Feb 1 in UTC+9. Written as UTC instants an hour before
        // local midnight would flip them, which is the whole reason the
        // aggregation converts before bucketing.
        let rows = vec![
            row(1, 1, 1400, 1400, "2026-01-29T20:00:00Z"),
            row(1, 2, 1400, 1400, "2026-01-30T20:00:00Z"),
            row(1, 3, 1400, 1400, "2026-01-31T20:00:00Z"),
        ];
        let stats = aggregate(&rows, 7, &now("2026-02-01T12:00:00+09:00"));
        assert_eq!(stats.current_streak_days, 3);
        assert_eq!(stats.longest_streak_days, 3);
    }

    #[test]
    fn two_episodes_in_one_day_are_one_day_of_streak() {
        let rows = vec![
            row(1, 1, 1400, 1400, "2026-03-09T22:00:00Z"),
            row(1, 2, 1400, 1400, "2026-03-09T23:30:00Z"),
        ];
        let stats = aggregate(&rows, 3, &now("2026-03-10T20:00:00+09:00"));
        // Both instants are 2026-03-10 in UTC+9.
        assert_eq!(stats.current_streak_days, 1);
        assert_eq!(stats.longest_streak_days, 1);
        assert_eq!(stats.per_day.last().unwrap().episodes, 2);
    }

    #[test]
    fn a_gap_ends_the_streak_but_not_the_longest() {
        let rows = vec![
            row(1, 1, 1400, 1400, "2026-05-01T03:00:00Z"),
            row(1, 2, 1400, 1400, "2026-05-02T03:00:00Z"),
            row(1, 3, 1400, 1400, "2026-05-03T03:00:00Z"),
            // Four days later, one lone watch.
            row(1, 4, 1400, 1400, "2026-05-07T03:00:00Z"),
        ];
        let stats = aggregate(&rows, 14, &now("2026-05-07T23:00:00+09:00"));
        assert_eq!(stats.current_streak_days, 1);
        assert_eq!(stats.longest_streak_days, 3);
    }

    #[test]
    fn yesterday_still_counts_as_a_live_streak() {
        // Nothing watched today yet. A streak that reads zero every morning
        // is the bug the grace day exists for.
        let rows = vec![
            row(1, 1, 1400, 1400, "2026-05-01T03:00:00Z"),
            row(1, 2, 1400, 1400, "2026-05-02T03:00:00Z"),
        ];
        let stats = aggregate(&rows, 7, &now("2026-05-03T09:00:00+09:00"));
        assert_eq!(stats.current_streak_days, 2);
        // A second missed day does end it.
        let stats = aggregate(&rows, 7, &now("2026-05-04T09:00:00+09:00"));
        assert_eq!(stats.current_streak_days, 0);
    }

    #[test]
    fn totals_cap_at_the_episode_length_and_count_the_watched_ones() {
        let rows = vec![
            // A position past the reported runtime contributes the runtime.
            row(1, 1, 1600, 1400, "2026-05-01T03:00:00Z"),
            // Abandoned at 20%: real seconds, but not a watched episode.
            row(1, 2, 280, 1400, "2026-05-01T04:00:00Z"),
            // No duration reported yet: the position is all there is.
            row(2, 1, 300, 0, "2026-05-01T05:00:00Z"),
        ];
        let stats = aggregate(&rows, 3, &now("2026-05-01T20:00:00+09:00"));
        assert_eq!(stats.total_watch_seconds, 1400 + 280 + 300);
        assert_eq!(stats.episodes_watched, 1);
        assert_eq!(stats.titles_started, 2);
    }

    #[test]
    fn the_window_includes_empty_days_and_ends_today() {
        let rows = vec![row(1, 1, 1400, 1400, "2026-05-02T03:00:00Z")];
        let stats = aggregate(&rows, 4, &now("2026-05-04T09:00:00+09:00"));
        assert_eq!(
            stats.per_day.iter().map(|d| d.date.as_str()).collect::<Vec<_>>(),
            ["2026-05-01", "2026-05-02", "2026-05-03", "2026-05-04"]
        );
        assert_eq!(stats.per_day.iter().map(|d| d.episodes).collect::<Vec<_>>(), [0, 1, 0, 0]);
    }

    #[test]
    fn top_titles_rank_by_time_and_the_busiest_hour_is_local() {
        let rows = vec![
            row(1, 1, 1400, 1400, "2026-05-01T14:00:00Z"),
            row(1, 2, 1400, 1400, "2026-05-01T14:30:00Z"),
            row(2, 1, 600, 1400, "2026-05-01T02:00:00Z"),
        ];
        let stats = aggregate(&rows, 3, &now("2026-05-02T09:00:00+09:00"));
        assert_eq!(stats.top_titles.len(), 2);
        assert_eq!(stats.top_titles[0].catalog_id, 1);
        assert_eq!(stats.top_titles[0].episodes, 2);
        assert_eq!(stats.top_titles[1].catalog_id, 2);
        // 14:00 and 14:30 UTC are both 23:00 local.
        assert_eq!(stats.busiest_hour, 23);
    }

    #[test]
    fn an_empty_history_aggregates_rather_than_panicking() {
        let stats = aggregate(&[], 7, &now("2026-05-04T09:00:00+09:00"));
        assert_eq!(stats.total_watch_seconds, 0);
        assert_eq!(stats.current_streak_days, 0);
        assert_eq!(stats.longest_streak_days, 0);
        assert_eq!(stats.busiest_hour, 0);
        assert_eq!(stats.first_watch_at, None);
        assert_eq!(stats.per_day.len(), 7);
    }

    #[test]
    fn first_watch_is_the_oldest_row_in_local_time() {
        let rows = vec![
            row(1, 2, 1400, 1400, "2026-05-03T03:00:00Z"),
            row(1, 1, 1400, 1400, "2026-05-01T03:00:00Z"),
        ];
        let stats = aggregate(&rows, 7, &now("2026-05-04T09:00:00+09:00"));
        assert_eq!(stats.first_watch_at.as_deref(), Some("2026-05-01T12:00:00+09:00"));
    }
}
