//! Finding releases for films.
//!
//! A sibling of `search`, not a mode inside it. That module's matching is
//! dense with anime-specific reasoning — absolute episode numbering across
//! split cours, roman-numeral sequels, fansub-group segmentation — held in
//! place by a regression set of real release names. A film shares none of it,
//! and threading a third mode through `score_release` would put those tests at
//! risk to no benefit. What is genuinely shared — normalization, seeder
//! scoring, the browser codec check, `Candidate` itself — is imported.
//!
//! The discriminating constraint here is the **year**, which has no analogue
//! on the anime side. A search for "Dune" returns the 2021 film, the 1984 one,
//! and a 2024 documentary in one response; only the year separates them, and
//! playing the wrong film is a worse failure than playing nothing. So the year
//! is a hard requirement on the first pass, with a second pass that drops it
//! only when the first found nothing at all.

use serde::Deserialize;

use super::search::{
    browser_incompatible_codec, magnet_from_infohash, normalize, seeder_score, urlencoding_encode,
    Candidate, TRACKERS,
};

/// The Pirate Bay's JSON search. Chosen over the usual film indexers for two
/// concrete reasons found by testing rather than reputation: 1337x sits behind
/// Cloudflare and answers a plain client with 403 (it would need the Python
/// sidecar's TLS-fingerprint treatment, as anineko does), and yts.mx no longer
/// resolves at all. This returns infohashes inline, so a search costs one
/// request and no per-result detail fetch.
const APIBAY_URL: &str = "https://apibay.org/q.php";

/// apibay's category for video. Narrower ids exist (201 movies, 207 HD movies)
/// but releases are filed inconsistently between them, and the scoring below
/// discards anything that isn't the wanted film anyway.
const CAT_VIDEO: &str = "200";

/// apibay answers an empty search with one row rather than an empty array.
const NO_RESULTS_HASH: &str = "0000000000000000000000000000000000000000";

/// Knaben, used as the fallback source. apibay was the plan; measured live,
/// it turned out to be unreachable on at least one real network -- not
/// blocked at the ISP level (a VPN made no difference), which points to the
/// domain itself rather than anything local. Knaben already covers this: it
/// is the series source, general-purpose, and its results for a film query
/// are the same quality apibay's are when apibay actually answers. Tried
/// only when apibay does not, so a working apibay costs nothing extra.
const KNABEN_URL: &str = "https://api.knaben.org/v1";

#[derive(Debug, Clone, Copy)]
pub struct MovieCriteria {
    /// The release year TMDB reports. Releases are named with it, and it is
    /// the only thing separating two films of the same name.
    pub year: Option<i32>,
    /// The stream is bound for a browser `<video>` rather than mpv, which
    /// narrows acceptable codecs. Films skew far harder to x265 than anime
    /// does, so this rejects much more often here than it does there.
    pub browser_client: bool,
}

#[derive(Debug, Deserialize)]
struct ApibayRow {
    name: String,
    info_hash: String,
    seeders: String,
    #[allow(dead_code)]
    size: String,
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
}

#[derive(Debug, Deserialize)]
struct KnabenResponse {
    #[serde(default)]
    hits: Vec<KnabenHit>,
}

fn magnet_for(info_hash: &str, name: &str) -> String {
    let mut magnet = format!(
        "magnet:?xt=urn:btih:{}&dn={}",
        info_hash,
        urlencoding_encode(name)
    );
    for tracker in TRACKERS {
        magnet.push_str("&tr=");
        magnet.push_str(&urlencoding_encode(tracker));
    }
    magnet
}

/// Every four-digit year that reads as a release year in a name.
fn years_in(name_norm: &str) -> Vec<i32> {
    let bytes: Vec<char> = name_norm.chars().collect();
    let mut out = vec![];
    for w in bytes.windows(4) {
        if w.iter().all(|c| c.is_ascii_digit()) {
            let n: i32 = w.iter().collect::<String>().parse().unwrap_or(0);
            // Film years only. 2160 and 1080 are resolutions, not years, and
            // they appear in almost every release name.
            if (1900..=2100).contains(&n) && n != 1080 && n != 2160 {
                out.push(n);
            }
        }
    }
    out
}

/// True when the release name opens with the wanted title.
///
/// Scene names put the title first and the metadata after
/// (`Title.Year.Quality.Source-GROUP`), so the title is a prefix rather than
/// something scattered through the name. Requiring only that every word
/// appears *somewhere* accepts a different title that happens to contain
/// them all: "Breaking Bad" matched "The Bad Guys Breaking In", observed
/// live. Anchoring at the start rejects that without needing the anime
/// module's segment machinery.
///
/// A leading article is dropped from both sides. Releases disagree about
/// whether to keep it ("The.Matrix" and "Matrix.1999" both occur), and it
/// carries no distinguishing information.
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
    // `normalize` collapses punctuation to spaces, so a prefix match here is
    // word-aligned: "matrix" cannot match "matrixreloaded", only "matrix
    // reloaded" — which the next check rejects.
    let Some(rest) = name.strip_prefix(&title) else {
        return false;
    };
    // What follows the title has to be metadata, not more title. A release of
    // "Dune: Part Two" is not a release of "Dune".
    rest.is_empty() || rest.starts_with(' ')
}

/// Score a release for a film. `None` rejects it.
fn score_movie(name: &str, title_norm: &str, criteria: MovieCriteria, require_year: bool) -> Option<i64> {
    let name_norm = normalize(name);
    if !title_matches(title_norm, &name_norm) {
        return None;
    }

    if let Some(year) = criteria.year {
        let found = years_in(&name_norm);
        if require_year {
            // A name carrying no year at all is not evidence of the wrong
            // film, so it survives the strict pass; a name carrying a
            // different year is, and does not.
            if !found.is_empty() && !found.contains(&year) {
                return None;
            }
        }
    }

    if criteria.browser_client && browser_incompatible_codec(&name_norm) {
        return None;
    }

    let mut score = 0i64;
    // Resolution. 2160p is downranked rather than rejected: it plays fine in
    // mpv, but it is a far larger download for a screen that rarely shows the
    // difference, and on the Pi it is bandwidth that is not there.
    if name_norm.contains("1080") {
        score += 100;
    } else if name_norm.contains("720") {
        score += 60;
    } else if name_norm.contains("2160") || name_norm.contains("4k") {
        score += 30;
    }

    // Source quality, in the order the scene names them.
    if name_norm.contains("remux") {
        score += 25;
    } else if name_norm.contains("bluray") || name_norm.contains("blu ray") {
        score += 40;
    } else if name_norm.contains("web dl") || name_norm.contains("webdl") {
        score += 35;
    } else if name_norm.contains("webrip") {
        score += 25;
    } else if name_norm.contains("hdrip") {
        score += 10;
    }

    // Recordings made in a cinema. Never outright rejected — for a film still
    // in theatres they may be all that exists — but they must lose to
    // anything else.
    if name_norm.contains("cam ") || name_norm.contains("hdcam") || name_norm.contains("telesync")
        || name_norm.contains(" ts ") || name_norm.contains("hdts")
    {
        score -= 200;
    }

    // An exact year match is worth more than any quality tier: the right film
    // at 720p beats the wrong film at 1080p.
    if let Some(year) = criteria.year {
        if years_in(&name_norm).contains(&year) {
            score += 300;
        }
    }

    Some(score)
}

/// `None` means the request itself failed -- unreachable, timed out, bad
/// response -- and says nothing about whether the film has releases.
/// `Some(vec)` means apibay was reached and answered, possibly with zero
/// rows. The caller only retries with a different query wording in the
/// second case: retrying a *different query* against a server that just
/// timed out is guaranteed to time out again, and doubles the wait for a
/// spinner that was already taking too long.
async fn query_apibay(client: &reqwest::Client, query: &str) -> Option<Vec<ApibayRow>> {
    let url = format!(
        "{}?q={}&cat={}",
        APIBAY_URL,
        urlencoding_encode(query),
        CAT_VIDEO
    );
    // The passed-in client is the shared, deliberately-untimed streaming
    // client (state.rs) -- fine for an mpv download, wrong for a search that
    // has to return in time for a spinner to make sense. Per-request timeout
    // only, same as tmdb::client.
    let response = match client
        .get(&url)
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            log::warn!("cinema: apibay search failed for '{}': {}", query, e);
            return None;
        }
    };
    if !response.status().is_success() {
        log::warn!("cinema: apibay returned HTTP {} for '{}'", response.status(), query);
        return None;
    }
    match response.json::<Vec<ApibayRow>>().await {
        Ok(rows) => Some(
            rows.into_iter()
                .filter(|r| r.info_hash != NO_RESULTS_HASH)
                .collect(),
        ),
        Err(e) => {
            log::warn!("cinema: apibay response did not parse: {}", e);
            None
        }
    }
}

fn collect(rows: Vec<ApibayRow>, title_norm: &str, criteria: MovieCriteria, require_year: bool) -> Vec<Candidate> {
    let mut out = vec![];
    for row in rows {
        let Some(score) = score_movie(&row.name, title_norm, criteria, require_year) else {
            continue;
        };
        let seeders: u64 = row.seeders.parse().unwrap_or(0);
        if seeders == 0 {
            continue;
        }
        out.push(Candidate {
            magnet: Some(magnet_for(&row.info_hash, &row.name)),
            torrent_url: None,
            name: row.name,
            seeders,
            score: score + seeder_score(seeders),
            // A film is one file, not a series batch: `try_candidate` takes a
            // lone video directly rather than hunting for an episode number in
            // the filenames.
            assume_batch: false,
        });
    }
    out
}

/// `None` means the request failed outright, same distinction as
/// `query_apibay` and for the same reason -- see that function.
async fn query_knaben(client: &reqwest::Client, query: &str) -> Option<Vec<KnabenHit>> {
    let body = serde_json::json!({
        "query": query,
        "order_by": "seeders",
        "order_direction": "desc",
        "size": 50,
        "hide_unsafe": true,
    });
    let response = match client
        .post(KNABEN_URL)
        .json(&body)
        .timeout(std::time::Duration::from_secs(20))
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            log::warn!("cinema: knaben search failed for '{}': {}", query, e);
            return None;
        }
    };
    if !response.status().is_success() {
        log::warn!("cinema: knaben returned HTTP {} for '{}'", response.status(), query);
        return None;
    }
    match response.json::<KnabenResponse>().await {
        Ok(r) => Some(r.hits),
        Err(e) => {
            log::warn!("cinema: knaben response did not parse: {}", e);
            None
        }
    }
}

fn collect_knaben(
    hits: Vec<KnabenHit>,
    title_norm: &str,
    criteria: MovieCriteria,
    require_year: bool,
) -> Vec<Candidate> {
    let mut out = vec![];
    for hit in hits {
        let Some(score) = score_movie(&hit.title, title_norm, criteria, require_year) else {
            continue;
        };
        let seeders = hit.seeders.unwrap_or(0);
        if seeders == 0 {
            continue;
        }
        let magnet = hit.magnet_url.or_else(|| hit.hash.as_ref().map(|h| magnet_from_infohash(h)));
        let Some(magnet) = magnet else { continue };
        out.push(Candidate {
            magnet: Some(magnet),
            torrent_url: None,
            name: hit.title,
            seeders,
            score: score + seeder_score(seeders),
            assume_batch: false,
        });
    }
    out
}

/// Find releases for one film.
///
/// `titles` is TMDB's title first, then the original-language title, so a film
/// released here under a different name still resolves.
pub async fn find_movie_candidates(
    client: &reqwest::Client,
    titles: &[String],
    criteria: MovieCriteria,
) -> Vec<Candidate> {
    let mut all: Vec<Candidate> = vec![];

    for title in titles.iter().take(2) {
        let title_norm = normalize(title);
        if title_norm.is_empty() {
            continue;
        }

        // The year belongs in the query as well as the filter: apibay's search
        // is a plain text match, and "dune 2021" returns the right film's
        // releases where a bare "dune" buries them among five other films.
        let query = match criteria.year {
            Some(y) => format!("{} {}", title, y),
            None => title.clone(),
        };
        let first_pass = query_apibay(client, &query).await;
        let reached_server = first_pass.is_some();
        if let Some(rows) = first_pass {
            all.extend(collect(rows, &title_norm, criteria, true));
        }

        // Only if apibay was reached and the year-qualified search genuinely
        // found nothing: some releases omit the year entirely, and a film
        // with no releases is worse than one matched on title alone. Not
        // retried after a network failure -- a different query against a
        // server that just timed out will time out again, and the picker's
        // spinner has already waited one full timeout by this point.
        if all.is_empty() && reached_server {
            if let Some(rows) = query_apibay(client, title).await {
                all.extend(collect(rows, &title_norm, criteria, false));
            }
        }

        // Knaben only when apibay is the problem, not when it answered and
        // genuinely has nothing: a working apibay costs nothing extra, and a
        // title truly absent from apibay is usually absent from Knaben too,
        // so this is reached almost only on the network-failure path.
        if all.is_empty() && !reached_server {
            if let Some(hits) = query_knaben(client, &query).await {
                all.extend(collect_knaben(hits, &title_norm, criteria, true));
            }
            if all.is_empty() {
                if let Some(hits) = query_knaben(client, title).await {
                    all.extend(collect_knaben(hits, &title_norm, criteria, false));
                }
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

    fn crit(year: i32) -> MovieCriteria {
        MovieCriteria { year: Some(year), browser_client: false }
    }

    #[test]
    fn a_resolution_is_never_read_as_a_release_year() {
        // Every release name contains 1080 or 2160; neither is a year.
        assert_eq!(years_in(&normalize("Dune.2021.1080p.BluRay")), vec![2021]);
        assert_eq!(years_in(&normalize("Movie.2160p.WEB-DL")), Vec::<i32>::new());
    }

    #[test]
    fn the_wrong_year_is_rejected_outright() {
        // Both are real releases of films called Dune. Playing the 1984 one
        // when the user picked the 2021 one is the failure this prevents.
        let t = normalize("Dune");
        assert!(score_movie("Dune.2021.1080p.BluRay.x264-GROUP", &t, crit(2021), true).is_some());
        assert!(score_movie("Dune.1984.1080p.BluRay.x264-GROUP", &t, crit(2021), true).is_none());
    }

    #[test]
    fn a_release_with_no_year_survives_the_strict_pass() {
        // Absence of a year is not evidence of the wrong film.
        let t = normalize("Dune");
        assert!(score_movie("Dune 1080p BluRay", &t, crit(2021), true).is_some());
    }

    #[test]
    fn the_right_film_at_a_lower_resolution_beats_the_wrong_film_at_a_higher_one() {
        let t = normalize("Dune");
        let right = score_movie("Dune.2021.720p.WEBRip", &t, crit(2021), false).unwrap();
        let wrong = score_movie("Dune.1984.2160p.BluRay.REMUX", &t, crit(2021), false).unwrap();
        assert!(right > wrong, "right={} wrong={}", right, wrong);
    }

    #[test]
    fn a_cinema_recording_loses_to_anything_else() {
        let t = normalize("Dune Part Two");
        let cam = score_movie("Dune.Part.Two.2024.HDCAM.x264", &t, crit(2024), true).unwrap();
        let web = score_movie("Dune.Part.Two.2024.1080p.WEBRip.x264", &t, crit(2024), true).unwrap();
        assert!(cam < web);
        // Still a candidate, for a film with nothing else out yet.
        assert!(score_movie("Dune.Part.Two.2024.HDCAM.x264", &t, crit(2024), true).is_some());
    }

    #[test]
    fn an_unrelated_film_sharing_one_word_is_not_a_match() {
        let t = normalize("Blade Runner 2049");
        assert!(score_movie("Blade.2.1080p.BluRay", &t, crit(2017), false).is_none());
        assert!(score_movie("Runner.Runner.2013.1080p", &t, crit(2017), false).is_none());
    }

    #[test]
    fn a_title_scattered_through_another_films_name_is_not_a_match() {
        // Observed live on a TV search: "Breaking Bad" pulled back "The Bad
        // Guys Breaking In", which contains both words and is a different
        // title entirely.
        let t = normalize("Breaking Bad");
        assert!(score_movie("The.Bad.Guys.Breaking.In.2024.1080p", &t, crit(2008), false).is_none());
    }

    #[test]
    fn a_sequel_is_not_a_release_of_the_film_it_follows() {
        // A sequel's release opens with the original's title, so the prefix
        // check alone cannot separate them -- the year does, which is why the
        // strict pass runs first and the year-less fallback only runs when it
        // found nothing at all.
        let t = normalize("Dune");
        assert!(score_movie("Dune.Part.Two.2024.1080p.WEBRip", &t, crit(2021), true).is_none());
        // ...but the sequel's own title still matches its own release.
        let t2 = normalize("Dune: Part Two");
        assert!(score_movie("Dune.Part.Two.2024.1080p.WEBRip", &t2, crit(2024), false).is_some());
    }

    #[test]
    fn a_leading_article_may_differ_between_title_and_release() {
        let t = normalize("The Matrix");
        assert!(score_movie("The.Matrix.1999.1080p.BluRay", &t, crit(1999), false).is_some());
        assert!(score_movie("Matrix.1999.1080p.BluRay", &t, crit(1999), false).is_some());
    }

    #[test]
    fn a_browser_client_refuses_a_codec_it_cannot_play() {
        let t = normalize("Dune");
        let browser = MovieCriteria { year: Some(2021), browser_client: true };
        assert!(score_movie("Dune.2021.1080p.BluRay.x265-GROUP", &t, browser, true).is_none());
        assert!(score_movie("Dune.2021.1080p.BluRay.x264-GROUP", &t, browser, true).is_some());
    }

    #[test]
    fn a_magnet_carries_the_hash_and_at_least_one_tracker() {
        let m = magnet_for("ED0DA850C273000000000000000000000000ABCD", "Dune (2021) [1080p]");
        assert!(m.starts_with("magnet:?xt=urn:btih:ED0DA850C273"));
        assert!(m.contains("&tr=udp%3A%2F%2Ftracker.opentrackr.org"));
    }

    #[test]
    fn the_empty_result_sentinel_is_not_a_candidate() {
        let rows = vec![ApibayRow {
            name: "No results returned".into(),
            info_hash: NO_RESULTS_HASH.into(),
            seeders: "0".into(),
            size: "0".into(),
        }];
        // Filtered at the query boundary; also has zero seeders, which the
        // collector drops independently.
        assert!(collect(rows, &normalize("No results returned"), crit(2021), false).is_empty());
    }

    /// Live. `cargo test --lib torrent -- --ignored`
    #[tokio::test]
    #[ignore]
    async fn a_real_search_finds_the_right_year_of_a_reused_title() {
        let client = reqwest::Client::builder().user_agent("Anicat/5.0").build().unwrap();
        let found = find_movie_candidates(
            &client,
            &["Dune".to_string()],
            MovieCriteria { year: Some(2021), browser_client: false },
        )
        .await;
        assert!(!found.is_empty(), "no candidates for Dune 2021");
        // The 1984 film is well seeded and would outrank on seeders alone.
        for c in found.iter().take(5) {
            let norm = normalize(&c.name);
            assert!(
                !years_in(&norm).contains(&1984),
                "1984 release ranked into the top 5: {}",
                c.name
            );
        }
    }

    /// Live. Confirms the fallback pass, and that a film with a punctuated
    /// title still resolves.
    #[tokio::test]
    #[ignore]
    async fn a_recent_film_resolves_with_seeded_releases() {
        let client = reqwest::Client::builder().user_agent("Anicat/5.0").build().unwrap();
        let found = find_movie_candidates(
            &client,
            &["Dune: Part Two".to_string()],
            MovieCriteria { year: Some(2024), browser_client: false },
        )
        .await;
        assert!(!found.is_empty(), "no candidates for Dune: Part Two");
        assert!(found[0].seeders > 0);
    }
}
