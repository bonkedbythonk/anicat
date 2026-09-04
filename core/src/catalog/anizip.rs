//! Per-episode metadata from AniZip (`api.ani.zip`), keyed by AniList id.
//!
//! AniList's own `streamingEpisodes` is a positional array scraped from
//! streaming sites — it drifts on shows with specials or numbering gaps, and
//! carries no synopsis or air date at all. AniZip maps AniList/TVDB/TMDB ids
//! against a proper per-episode table (title, still frame, overview, air
//! date, runtime), so it wins over `streamingEpisodes` wherever both have an
//! answer for the same episode number. There is no Rust client crate for it;
//! the response shape is loosely documented, so this parses defensively
//! through `serde_json::Value` rather than a strict typed schema — an
//! unexpected field is skipped, not a parse failure for the whole title.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::time::Duration;

/// AniZip is a small JSON payload and normally answers in well under a
/// second (measured against the live API: 50-150ms). This bounds the rare
/// slow/hanging case rather than leaving it unbounded like a plain
/// `.send()` would — every other network client in this codebase sets a
/// request timeout for exactly this reason (see `anilist/client.rs`'s
/// comment on why an untimed call can wedge the whole request queue behind
/// it). Without one here, a degraded AniZip host turned "open an anime" into
/// an indefinite spinner even though the episode list it enriches doesn't
/// need it to load at all.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(5);

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AniZipEpisode {
    pub title: Option<String>,
    pub thumbnail: Option<String>,
    pub overview: Option<String>,
    pub air_date: Option<String>,
    pub runtime_minutes: Option<i32>,
}

/// Episode number -> metadata. Empty on any failure (unmapped id, network
/// error, unexpected shape) — this is enrichment, never the reason an
/// episode list fails to load.
pub async fn fetch(http: &reqwest::Client, anilist_id: i64) -> HashMap<i32, AniZipEpisode> {
    let url = format!("https://api.ani.zip/mappings?anilist_id={anilist_id}");
    let Ok(res) = http.get(&url).timeout(REQUEST_TIMEOUT).send().await else {
        return HashMap::new();
    };
    if !res.status().is_success() {
        return HashMap::new();
    }
    let Ok(data) = res.json::<serde_json::Value>().await else {
        return HashMap::new();
    };
    parse(&data)
}

fn parse(data: &serde_json::Value) -> HashMap<i32, AniZipEpisode> {
    let mut out = HashMap::new();
    let Some(episodes) = data.get("episodes").and_then(|v| v.as_object()) else {
        return out;
    };
    for (key, ep) in episodes {
        // Specials use non-numeric keys ("S1") and are skipped: the episode
        // list this enriches is indexed 1..=episode_count, with no slot for
        // them.
        let Ok(num) = key.parse::<i32>() else { continue };
        if num < 1 {
            continue;
        }

        let title = ep
            .get("title")
            .and_then(|t| {
                t.get("en")
                    .and_then(|v| v.as_str())
                    .or_else(|| t.get("x-jat").and_then(|v| v.as_str()))
                    .or_else(|| t.get("ja").and_then(|v| v.as_str()))
            })
            .map(str::trim)
            .filter(|s| {
                !s.is_empty() && !s.starts_with("Episode ") && !s.starts_with("EPISODE ")
            })
            .map(String::from);

        let thumbnail = ep.get("image").and_then(|v| v.as_str()).map(String::from);

        let overview = ep
            .get("overview")
            .and_then(|v| v.as_str())
            .or_else(|| ep.get("summary").and_then(|v| v.as_str()))
            .map(String::from);

        let air_date = ep.get("airdate").and_then(|v| v.as_str()).map(String::from);

        let runtime_minutes = ep
            .get("runtime")
            .and_then(|v| v.as_i64())
            .or_else(|| ep.get("length").and_then(|v| v.as_i64()))
            .filter(|&v| v > 0)
            .map(|v| v as i32);

        out.insert(
            num,
            AniZipEpisode {
                title,
                thumbnail,
                overview,
                air_date,
                runtime_minutes,
            },
        );
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_titled_episodes_and_skips_specials() {
        let data = serde_json::json!({
            "episodes": {
                "1": {
                    "title": { "en": "The Beginning", "ja": "はじまり" },
                    "image": "https://thetvdb.example/1.jpg",
                    "overview": "Yuuta meets Rikka.",
                    "airdate": "2014-01-08",
                    "runtime": 24
                },
                "2": {
                    "title": { "en": "Episode 2" },
                    "runtime": 0
                },
                "S1": {
                    "title": { "en": "OVA" }
                }
            }
        });
        let out = parse(&data);
        assert_eq!(out.len(), 2);

        let ep1 = &out[&1];
        assert_eq!(ep1.title.as_deref(), Some("The Beginning"));
        assert_eq!(ep1.overview.as_deref(), Some("Yuuta meets Rikka."));
        assert_eq!(ep1.air_date.as_deref(), Some("2014-01-08"));
        assert_eq!(ep1.runtime_minutes, Some(24));

        // A generic "Episode N" title is filtered out — it would only
        // overwrite AniList's own already-generic fallback with itself.
        let ep2 = &out[&2];
        assert_eq!(ep2.title, None);
        // A zero/absent runtime does not masquerade as a real one.
        assert_eq!(ep2.runtime_minutes, None);
    }

    #[test]
    fn missing_episodes_object_is_empty_not_an_error() {
        let data = serde_json::json!({ "unrelated": true });
        assert!(parse(&data).is_empty());
    }
}
