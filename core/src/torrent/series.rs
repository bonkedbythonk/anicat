//! Finding releases for episodes of a series.
//!
//! Sits beside `cinema` (films) and `search` (anime) rather than inside
//! either. A film has no episodes; anime numbers them absolutely and with
//! fansub conventions this shares none of. Western TV is named `Title.SxxEyy`
//! almost without exception, which makes the matching simpler than either —
//! but only once the season and episode are known, which is the work below.
//!
//! The source is Knaben rather than apibay. That was measured, not assumed:
//! apibay's per-episode TV results run to single-digit seeders and mostly
//! XviD, and season packs for recent shows are absent entirely, while the same
//! queries on Knaben return 1080p WEB-DL with 20-90 seeders. Films stay on
//! apibay, which is verified and serves them well.

use serde::Deserialize;

use super::search::{browser_incompatible_codec, normalize, seeder_score, Candidate};

const KNABEN_URL: &str = "https://api.knaben.org/v1";

/// Knaben's category tree puts television under 2000000, with 2001000 for HD.
/// Filtering here is cheaper than letting a film with a similar name reach the
/// scorer.
const CATEGORY_TV: i64 = 2_000_000;

#[derive(Debug, Clone, Copy)]
pub struct EpisodeCriteria {
    pub season: u32,
    pub episode: u32,
    /// The stream is bound for a browser `<video>` rather than mpv. Worth more
    /// here than anywhere else: TV releases skew heavily to x265, and the
    /// highest-seeded result for a given episode is frequently a MeGusta HEVC
    /// encode the browser cannot play.
    pub browser_client: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct KnabenHit {
    title: String,
    #[serde(default)]
    magnet_url: Option<String>,
    #[serde(default)]
    hash: Option<String>,
    #[serde(default)]
    seeders: Option<u64>,
    #[serde(default)]
    category_id: Vec<i64>,
}

#[derive(Debug, Deserialize)]
struct KnabenResponse {
    #[serde(default)]
    hits: Vec<KnabenHit>,
}

/// One season's episode count, in season order, skipping specials (season 0).
/// Enough to convert between the absolute numbering the app stores and the
/// SxxEyy that release names use.
pub type SeasonMap = Vec<(u32, u32)>;

/// Convert an absolute episode number into the season and episode a release
/// name would spell.
///
/// The app stores one integer per episode because everything downstream
/// assumes it: auto-next adds one, the preloader adds one, and the watched
/// check compares against a total. Encoding the season into that number
/// (`season * 1000 + episode`) would break each of those at every season
/// boundary, so the number stays absolute and the season is recovered here.
///
/// The tradeoff is that a stored number means "the Nth episode as TMDB
/// ordered them when it was stored". If TMDB later inserts an episode into an
/// earlier season, later numbers shift by one. Rare, and the same class of
/// drift the anime side already lives with.
pub fn absolute_to_season_episode(absolute: i64, seasons: &SeasonMap) -> Option<(u32, u32)> {
    if absolute < 1 {
        return None;
    }
    let mut remaining = absolute as u32;
    for (season, count) in seasons {
        if remaining <= *count {
            return Some((*season, remaining));
        }
        remaining -= count;
    }
    None
}

/// The inverse: where a given episode of a season falls in absolute order.
pub fn season_episode_to_absolute(season: u32, episode: u32, seasons: &SeasonMap) -> Option<i64> {
    let mut absolute = 0i64;
    for (s, count) in seasons {
        if *s == season {
            if episode == 0 || episode > *count {
                return None;
            }
            return Some(absolute + episode as i64);
        }
        absolute += *count as i64;
    }
    None
}

/// True when the release name opens with the wanted series title.
///
/// The same anchoring the film matcher uses, and for the same reason: a name
/// containing every word of the title somewhere can be a different show
/// entirely. "Breaking Bad" pulls back "The Bad Guys Breaking In" from a plain
/// word-containment check.
fn title_matches(title_norm: &str, name_norm: &str) -> bool {
    let strip_article = |s: &str| -> String {
        for article in ["the ", "a ", "an "] {
            if let Some(rest) = s.strip_prefix(article) {
                return rest.to_string();
            }
        }
        s.to_string()
    };
    let title = strip_article(title_norm);
    let name = strip_article(name_norm);
    if title.is_empty() {
        return false;
    }
    let Some(rest) = name.strip_prefix(&title) else {
        return false;
    };
    rest.is_empty() || rest.starts_with(' ')
}

/// Whether a name carries this exact season and episode.
///
/// `normalize` has already collapsed punctuation, so `S01E01`, `s01.e01` and
/// `S01 E01` all arrive as `s01e01` or `s01 e01`. Both spellings are checked;
/// `1x01`, which a minority of releases use, is checked too.
fn names_this_episode(name_norm: &str, season: u32, episode: u32) -> bool {
    let forms = [
        format!("s{:02}e{:02}", season, episode),
        format!("s{:02} e{:02}", season, episode),
        format!("{}x{:02}", season, episode),
    ];
    forms.iter().any(|f| name_norm.contains(f.as_str()))
}

/// Whether a name looks like a whole-season pack rather than one episode.
///
/// A pack is usable: the shared candidate loop already picks the right file
/// out of a multi-file torrent by filename. It is preferred *less* than an
/// exact episode match, because it is a far larger download for one episode.
fn names_this_season_pack(name_norm: &str, season: u32) -> bool {
    if names_any_episode(name_norm) {
        return false;
    }
    let forms = [
        format!("s{:02}", season),
        format!("season {}", season),
        format!("season {:02}", season),
    ];
    forms.iter().any(|f| name_norm.contains(f.as_str()))
}

/// Whether a name carries any SxxEyy marker at all, used to tell a season pack
/// apart from a single episode of that season.
fn names_any_episode(name_norm: &str) -> bool {
    let bytes: Vec<char> = name_norm.chars().collect();
    bytes.windows(6).any(|w| {
        w[0] == 's'
            && w[1].is_ascii_digit()
            && w[2].is_ascii_digit()
            && w[3] == 'e'
            && w[4].is_ascii_digit()
            && w[5].is_ascii_digit()
    })
}

/// Score a release for one episode. `None` rejects it.
fn score_episode(name: &str, title_norm: &str, criteria: EpisodeCriteria) -> Option<(i64, bool)> {
    let name_norm = normalize(name);
    if !title_matches(title_norm, &name_norm) {
        return None;
    }

    let exact = names_this_episode(&name_norm, criteria.season, criteria.episode);
    let pack = !exact && names_this_season_pack(&name_norm, criteria.season);
    if !exact && !pack {
        return None;
    }

    if criteria.browser_client && browser_incompatible_codec(&name_norm) {
        return None;
    }

    let mut score = if exact { 200 } else { 60 };

    if name_norm.contains("1080") {
        score += 100;
    } else if name_norm.contains("720") {
        score += 60;
    } else if name_norm.contains("2160") || name_norm.contains("4k") {
        score += 30;
    } else {
        // No resolution in the name is usually an old SD rip.
        score -= 40;
    }

    if name_norm.contains("web dl") || name_norm.contains("webdl") {
        score += 40;
    } else if name_norm.contains("bluray") || name_norm.contains("blu ray") {
        score += 35;
    } else if name_norm.contains("webrip") {
        score += 25;
    } else if name_norm.contains("hdtv") {
        score += 10;
    }

    // Ancient codecs that signal an old, small, low-quality rip even when the
    // name claims a resolution.
    if name_norm.contains("xvid") || name_norm.contains("divx") {
        score -= 120;
    }

    Some((score, pack))
}

/// `None` means the request itself failed and says nothing about whether the
/// episode has releases -- see the identical reasoning on `cinema::
/// query_apibay`. The caller only falls back to a season-pack query in the
/// `Some(vec)` case, so a dead Knaben doesn't cost two full timeouts.
async fn query_knaben(client: &reqwest::Client, query: &str) -> Option<Vec<KnabenHit>> {
    let body = serde_json::json!({
        "query": query,
        "order_by": "seeders",
        "order_direction": "desc",
        "size": 50,
        "hide_unsafe": true,
    });
    // Same reasoning as the apibay call in torrent/cinema.rs: this client is
    // the shared, deliberately-untimed streaming client, wrong for a search
    // a spinner is waiting on.
    let response = match client
        .post(KNABEN_URL)
        .json(&body)
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            log::warn!("series: knaben search failed for '{}': {}", query, e);
            return None;
        }
    };
    if !response.status().is_success() {
        log::warn!("series: knaben returned HTTP {} for '{}'", response.status(), query);
        return None;
    }
    match response.json::<KnabenResponse>().await {
        Ok(r) => Some(r.hits),
        Err(e) => {
            log::warn!("series: knaben response did not parse: {}", e);
            None
        }
    }
}

fn collect(hits: Vec<KnabenHit>, title_norm: &str, criteria: EpisodeCriteria) -> Vec<Candidate> {
    let mut out = vec![];
    for hit in hits {
        // A film with a similar name can otherwise reach the scorer.
        if !hit.category_id.is_empty() && !hit.category_id.iter().any(|c| *c / 1_000_000 == CATEGORY_TV / 1_000_000) {
            continue;
        }
        let Some((score, pack)) = score_episode(&hit.title, title_norm, criteria) else {
            continue;
        };
        // Knaben omits `seeders` on some rows rather than sending zero, and a
        // release with no seeders is unplayable either way.
        let seeders = hit.seeders.unwrap_or(0);
        if seeders == 0 {
            continue;
        }
        let magnet = hit
            .magnet_url
            .or_else(|| hit.hash.as_ref().map(|h| super::search::magnet_from_infohash(h)));
        let Some(magnet) = magnet else { continue };
        out.push(Candidate {
            name: hit.title,
            magnet: Some(magnet),
            torrent_url: None,
            seeders,
            score: score + seeder_score(seeders),
            // A season pack holds many episodes, so the shared loop has to
            // pick the file by name rather than taking the only video.
            assume_batch: pack,
        });
    }
    out
}

/// Find releases for one episode of a series.
pub async fn find_episode_candidates(
    client: &reqwest::Client,
    titles: &[String],
    criteria: EpisodeCriteria,
) -> Vec<Candidate> {
    let mut all: Vec<Candidate> = vec![];

    for title in titles.iter().take(2) {
        let title_norm = normalize(title);
        if title_norm.is_empty() {
            continue;
        }

        // The episode marker belongs in the query: Knaben ranks by relevance
        // over a large corpus, and a bare series title returns every episode
        // of every season before the wanted one.
        let episode_query = format!("{} S{:02}E{:02}", title, criteria.season, criteria.episode);
        let first_pass = query_knaben(client, &episode_query).await;
        let reached_server = first_pass.is_some();
        if let Some(hits) = first_pass {
            all.extend(collect(hits, &title_norm, criteria));
        }

        // Season packs only if Knaben was reached and no single episode
        // turned up. Packs cost a much larger download for one episode, so
        // they are a fallback rather than a parallel source -- and not
        // retried after a network failure, for the same reason the film
        // search doesn't retry apibay.
        if all.is_empty() && reached_server {
            let pack_query = format!("{} S{:02}", title, criteria.season);
            if let Some(hits) = query_knaben(client, &pack_query).await {
                all.extend(collect(hits, &title_norm, criteria));
            }
        }

        if !all.is_empty() {
            break;
        }
    }

    all.sort_by(|a, b| b.score.cmp(&a.score).then(b.seeders.cmp(&a.seeders)));
    let mut seen = std::collections::HashSet::new();
    all.retain(|c| seen.insert(normalize(&c.name)));
    all
}

#[cfg(test)]
mod tests {
    use super::*;

    fn crit(season: u32, episode: u32) -> EpisodeCriteria {
        EpisodeCriteria { season, episode, browser_client: false }
    }

    #[test]
    fn absolute_numbering_crosses_season_boundaries() {
        // Two seasons of 10, then one of 8.
        let seasons: SeasonMap = vec![(1, 10), (2, 10), (3, 8)];
        assert_eq!(absolute_to_season_episode(1, &seasons), Some((1, 1)));
        assert_eq!(absolute_to_season_episode(10, &seasons), Some((1, 10)));
        // The boundary auto-next walks over: +1 from the last of a season has
        // to land on the first of the next, which is why the stored number is
        // absolute rather than season-encoded.
        assert_eq!(absolute_to_season_episode(11, &seasons), Some((2, 1)));
        assert_eq!(absolute_to_season_episode(28, &seasons), Some((3, 8)));
        assert_eq!(absolute_to_season_episode(29, &seasons), None);
        assert_eq!(absolute_to_season_episode(0, &seasons), None);
    }

    #[test]
    fn season_and_episode_round_trip_through_absolute() {
        let seasons: SeasonMap = vec![(1, 10), (2, 10), (3, 8)];
        for (s, e) in [(1u32, 1u32), (1, 10), (2, 1), (3, 8)] {
            let abs = season_episode_to_absolute(s, e, &seasons).unwrap();
            assert_eq!(absolute_to_season_episode(abs, &seasons), Some((s, e)));
        }
        assert_eq!(season_episode_to_absolute(2, 11, &seasons), None);
        assert_eq!(season_episode_to_absolute(9, 1, &seasons), None);
    }

    #[test]
    fn a_different_show_containing_the_title_words_is_rejected() {
        // Observed live: this is what a "Breaking Bad" search returns first.
        let t = normalize("Breaking Bad");
        assert!(score_episode("The Bad Guys Breaking In S01E01 XviD-AFG", &t, crit(1, 1)).is_none());
        assert!(score_episode("Breaking.Bad.S01E01.Pilot.1080p.BluRay", &t, crit(1, 1)).is_some());
    }

    #[test]
    fn only_the_wanted_episode_matches() {
        let t = normalize("Silo");
        assert!(score_episode("Silo S01E01 1080p WEB-DL", &t, crit(1, 1)).is_some());
        assert!(score_episode("Silo S01E02 1080p WEB-DL", &t, crit(1, 1)).is_none());
        assert!(score_episode("Silo S02E01 1080p WEB-DL", &t, crit(1, 1)).is_none());
    }

    #[test]
    fn the_other_episode_spellings_are_understood() {
        let t = normalize("Silo");
        assert!(score_episode("Silo.S01.E01.1080p.WEB-DL", &t, crit(1, 1)).is_some());
        assert!(score_episode("Silo 1x01 1080p", &t, crit(1, 1)).is_some());
    }

    #[test]
    fn a_season_pack_is_usable_but_loses_to_the_episode_itself() {
        let t = normalize("Silo");
        let (pack_score, is_pack) = score_episode("Silo S01 1080p WEB-DL", &t, crit(1, 3)).unwrap();
        let (exact_score, exact_is_pack) =
            score_episode("Silo S01E03 1080p WEB-DL", &t, crit(1, 3)).unwrap();
        assert!(is_pack);
        assert!(!exact_is_pack);
        assert!(exact_score > pack_score);
    }

    #[test]
    fn a_pack_for_another_season_is_not_a_match() {
        let t = normalize("Silo");
        assert!(score_episode("Silo S02 1080p WEB-DL", &t, crit(1, 3)).is_none());
    }

    #[test]
    fn an_ancient_rip_loses_to_a_modern_one() {
        let t = normalize("Silo");
        let (xvid, _) = score_episode("Silo S01E01 XviD-AFG", &t, crit(1, 1)).unwrap();
        let (web, _) = score_episode("Silo S01E01 1080p WEB-DL", &t, crit(1, 1)).unwrap();
        assert!(web > xvid);
    }

    #[test]
    fn a_browser_client_refuses_the_hevc_encode_that_usually_ranks_first() {
        let t = normalize("Silo");
        let browser = EpisodeCriteria { season: 1, episode: 1, browser_client: true };
        // The highest-seeded result for many episodes is exactly this shape.
        assert!(score_episode("Silo S01E01 1080p HEVC x265-MeGusta", &t, browser).is_none());
        assert!(score_episode("Silo S01E01 1080p WEB-DL H 264-NTb", &t, browser).is_some());
    }

    /// Live. `cargo test --lib torrent -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn a_real_episode_search_returns_the_right_show_at_hd() {
        let client = reqwest::Client::builder().user_agent("Anicat/5.0").build().unwrap();
        let found =
            find_episode_candidates(&client, &["Silo".to_string()], crit(1, 1)).await;
        assert!(!found.is_empty(), "no candidates for Silo S01E01");
        let best = normalize(&found[0].name);
        assert!(best.starts_with("silo"), "best is not Silo: {}", found[0].name);
        assert!(
            names_this_episode(&best, 1, 1) || names_this_season_pack(&best, 1),
            "best carries neither the episode nor the season: {}",
            found[0].name
        );
    }

    /// Live. The case that motivated anchoring the title match.
    #[tokio::test]
    #[ignore]
    async fn a_real_search_does_not_return_a_different_show() {
        let client = reqwest::Client::builder().user_agent("Anicat/5.0").build().unwrap();
        let found =
            find_episode_candidates(&client, &["Breaking Bad".to_string()], crit(1, 1)).await;
        assert!(!found.is_empty(), "no candidates for Breaking Bad S01E01");
        for c in found.iter().take(5) {
            assert!(
                normalize(&c.name).starts_with("breaking bad"),
                "wrong show in the top 5: {}",
                c.name
            );
        }
    }
}
