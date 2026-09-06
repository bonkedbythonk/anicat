//! MyAnimeList id lookup by title, through Jikan (`api.jikan.moe`).
//!
//! AniSkip's intro/outro timings are keyed by MAL id, and the only bridge
//! this app has to one is AniList's `idMal`. AniList leaves that null on a
//! newly added entry for weeks — which is exactly the population being
//! watched week to week, so AniSkip never fired for the shows that most
//! needed it. This resolves the id from the title instead, and is only ever
//! reached when `idMal` is missing.
//!
//! A *wrong* id here is strictly worse than none: AniSkip would answer with
//! another show's — or another season's — skip ranges and the player would
//! jump mid-scene, with nothing on screen saying why. So the match is exact
//! normalised title equality against every name both catalogs know, the year
//! has to agree when both sides state one, and the format is only ever a
//! tiebreak. Nothing here fuzzy-matches, and season and part markers are
//! deliberately left in the normalised string: collapsing "Season 2" onto
//! "Season 1" is the single most likely way to produce that wrong id.

use std::time::Duration;

use serde::Deserialize;

const SEARCH_URL: &str = "https://api.jikan.moe/v4/anime";

/// Jikan is a cache in front of MyAnimeList and answers in well under a
/// second when MAL is healthy, but it returns a 504 for as long as MAL
/// refuses it (observed for hours at a stretch) and can sit on a request
/// while it tries. This is enrichment on the detail page — an unbounded
/// call would hold up the page that does not need it, the way an untimed
/// AniZip call once did.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(3);

/// Ceiling on the whole lookup, second attempt included, so the worst case
/// is bounded by one number rather than by `MAX_QUERIES * REQUEST_TIMEOUT`.
/// This sits on the detail page's critical path for a title with no
/// `idMal`, so it is deliberately tighter than two full request timeouts: a
/// healthy Jikan answers in a few hundred ms and never comes near it.
const TOTAL_BUDGET: Duration = Duration::from_secs(4);

/// How many of `titles` are actually sent as queries. Jikan allows 3 req/s
/// and 60/min; two sequential round trips cannot breach either, so no sleep
/// is needed between them. Every title is still *matched* against — only
/// the querying is capped.
const MAX_QUERIES: usize = 2;

/// Why a lookup produced no id, which the caller has to know before it
/// caches the answer.
///
/// A plain `Option` collapses "MyAnimeList says no such title" into "we
/// could not ask", and the two want opposite handling: the first is worth
/// remembering for hours, the second must be retried on the next open. The
/// distinction is not hypothetical — Jikan answers 504 for as long as MAL
/// refuses it, and caching those as misses would keep AniSkip dark for the
/// whole negative TTL *after* MAL came back, on exactly the airing shows
/// this fallback was written for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MalLookup {
    Found(i64),
    /// Jikan answered and nothing matched confidently.
    NoMatch,
    /// Every attempt failed before an answer, or the budget ran out.
    Unavailable,
}

/// The MAL id for the title, when one matches confidently.
///
/// `titles` is the AniList name set in preference order — romaji first,
/// since MAL's own `title` is romanised and that is the highest-probability
/// exact hit, then english, then native and synonyms. The first
/// `MAX_QUERIES` distinct entries are sent as queries; all of them are used
/// to judge the answers.
pub async fn search_mal_id(
    http: &reqwest::Client,
    titles: &[String],
    year: Option<i32>,
    format: Option<&str>,
) -> MalLookup {
    tokio::time::timeout(TOTAL_BUDGET, resolve(http, titles, year, format))
        .await
        .unwrap_or_else(|_| {
            log::warn!("[jikan] lookup gave up after {}s", TOTAL_BUDGET.as_secs());
            MalLookup::Unavailable
        })
}

async fn resolve(
    http: &reqwest::Client,
    titles: &[String],
    year: Option<i32>,
    format: Option<&str>,
) -> MalLookup {
    let mut queried: Vec<String> = Vec::new();
    let mut answered = false;
    for title in titles {
        let trimmed = title.trim();
        // Two spellings of the same name are one query, not two: sending
        // both burns the second attempt on a result set already seen.
        if trimmed.is_empty() || queried.iter().any(|q| normalize(q) == normalize(trimmed)) {
            continue;
        }
        queried.push(trimmed.to_string());

        match fetch(http, trimmed).await {
            Ok(results) => {
                answered = true;
                if let Some(id) = pick_match(&results, titles, year, format) {
                    log::info!("[jikan] {trimmed:?} -> mal id {id}");
                    return MalLookup::Found(id);
                }
            }
            Err(e) => log::warn!("[jikan] search for {trimmed:?} failed: {e}"),
        }

        if queried.len() >= MAX_QUERIES {
            break;
        }
    }
    if answered {
        MalLookup::NoMatch
    } else {
        MalLookup::Unavailable
    }
}

async fn fetch(http: &reqwest::Client, query: &str) -> Result<Vec<AnimeEntity>, String> {
    let url = format!("{SEARCH_URL}?q={}&limit=5", urlencode(query));
    let res = http
        .get(&url)
        .timeout(REQUEST_TIMEOUT)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !res.status().is_success() {
        return Err(format!("jikan {} for {url}", res.status()));
    }
    let body: SearchResponse = res.json().await.map_err(|e| e.to_string())?;
    Ok(body.data)
}

// --- pure helpers, unit-tested against captured payload shapes ---------------

/// Case, punctuation and spacing only. Season and part markers survive on
/// purpose — see the module comment for what stripping them costs.
fn normalize(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut pending_space = false;
    for ch in s.chars() {
        if ch.is_alphanumeric() {
            if pending_space {
                out.push(' ');
                pending_space = false;
            }
            out.extend(ch.to_lowercase());
        } else if !out.is_empty() {
            pending_space = true;
        }
    }
    out
}

/// AniList's `format` in MAL's `type` vocabulary. None for a format MAL has
/// no counterpart for, which just means the tiebreak does not apply.
fn mal_type_for(format: &str) -> Option<&'static str> {
    match format {
        // MAL has no short-form TV category; a TV_SHORT is filed as TV.
        "TV" | "TV_SHORT" => Some("TV"),
        "MOVIE" => Some("Movie"),
        "OVA" => Some("OVA"),
        "ONA" => Some("ONA"),
        "SPECIAL" => Some("Special"),
        "MUSIC" => Some("Music"),
        _ => None,
    }
}

/// Every name Jikan gives for an entry. `titles[]` already repeats `title`
/// and the english/japanese pair on most entries, but not on all of them,
/// and a synonym only ever appears there.
fn names_of(e: &AnimeEntity) -> Vec<&str> {
    let mut out = Vec::with_capacity(4 + e.titles.len());
    for field in [&e.title, &e.title_english, &e.title_japanese] {
        if let Some(s) = field.as_deref() {
            out.push(s);
        }
    }
    for alt in &e.titles {
        if let Some(s) = alt.title.as_deref() {
            out.push(s);
        }
    }
    out
}

/// `year` is null on a great many entries — including currently airing ones,
/// which is the whole population this module exists for — while the aired
/// range still carries the start year. Reading only `year` would mean the
/// year preference silently never fires where it matters most.
fn entity_year(e: &AnimeEntity) -> Option<i32> {
    e.year.or_else(|| e.aired.as_ref()?.prop.as_ref()?.from.as_ref()?.year)
}

/// Higher is better; None rejects the candidate outright.
fn rank(e: &AnimeEntity, year: Option<i32>, want_type: Option<&str>) -> Option<i32> {
    let mut score = match (year, entity_year(e)) {
        (Some(a), Some(b)) if a == b => 4,
        (Some(a), Some(b)) if (a - b).abs() == 1 => 2,
        // A title that matches exactly but sits in a different year is a
        // different season, a remake, or a recap compilation. Rejecting it
        // is the asymmetry in the module comment: no skip times beats
        // another season's skip times.
        (Some(_), Some(_)) => return None,
        _ => 1,
    };
    if want_type.is_some() && e.kind.as_deref() == want_type {
        score += 1;
    }
    Some(score)
}

fn pick_match(
    results: &[AnimeEntity],
    wanted: &[String],
    year: Option<i32>,
    format: Option<&str>,
) -> Option<i64> {
    let want: Vec<String> = wanted
        .iter()
        .map(|t| normalize(t))
        .filter(|t| !t.is_empty())
        .collect();
    if want.is_empty() {
        return None;
    }
    let want_type = format.and_then(mal_type_for);

    let mut best: Option<(i32, i64)> = None;
    for e in results {
        if e.mal_id <= 0 {
            continue;
        }
        if !names_of(e).iter().any(|n| want.contains(&normalize(n))) {
            continue;
        }
        let Some(score) = rank(e, year, want_type) else { continue };
        // Strictly greater, so a tie keeps the earlier result — Jikan
        // returns them in its own relevance order and that is a better
        // guess than whichever happens to come last.
        if best.is_none_or(|(prev, _)| score > prev) {
            best = Some((score, e.mal_id));
        }
    }
    best.map(|(_, id)| id)
}

fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(*b as char),
            b' ' => out.push('+'),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

// --- wire types -------------------------------------------------------------

#[derive(Deserialize)]
struct SearchResponse {
    #[serde(default)]
    data: Vec<AnimeEntity>,
}

#[derive(Deserialize, Default)]
struct AnimeEntity {
    #[serde(default)]
    mal_id: i64,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    title_english: Option<String>,
    #[serde(default)]
    title_japanese: Option<String>,
    #[serde(default)]
    titles: Vec<AltTitle>,
    #[serde(rename = "type", default)]
    kind: Option<String>,
    #[serde(default)]
    year: Option<i32>,
    #[serde(default)]
    aired: Option<Aired>,
}

#[derive(Deserialize)]
struct AltTitle {
    #[serde(default)]
    title: Option<String>,
}

#[derive(Deserialize)]
struct Aired {
    #[serde(default)]
    prop: Option<AiredProp>,
}

#[derive(Deserialize)]
struct AiredProp {
    #[serde(default)]
    from: Option<AiredDate>,
}

#[derive(Deserialize)]
struct AiredDate {
    #[serde(default)]
    year: Option<i32>,
}

#[cfg(test)]
mod tests;
