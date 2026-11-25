//! SeaDex (seadex.moe) lookup: a community-curated "best release" per
//! AniList entry, backed by real torrent metadata (infohash, release group,
//! file list) rather than the release-name heuristics the rest of this module
//! relies on.
//!
//! Anicat is AniList-native, and AniList already splits a franchise into one
//! entry per season *and* per OVA/special/"Lite" short — so a lookup by that
//! id sidesteps title/season parsing entirely for exactly the shows where it
//! is most fragile: long-running chains with a scatter of specials that every
//! release group names differently. Scored above every regex-matched
//! candidate on purpose: a human already picked this release for this exact
//! entry, so there is nothing left to guess.
//!
//! Nyaa-tracked picks only. SeaDex also lists AnimeBytes releases, but AB is a
//! private tracker anicat has no account for and could never fetch from.

use std::collections::HashMap;

use serde_json::Value;

use super::search::{
    absolute_episode, filename_episode, filename_matches_episode, magnet_from_infohash, normalize,
    title_matches_with_alts, Candidate,
};

const SEADEX_SCORE: i64 = 5000;
const SEADEX_BEST_BONUS: i64 = 500;

/// One Nyaa-tracked torrent SeaDex links to an AniList entry, stripped down to
/// what episode-matching needs. Cached per `media_id` (see `find_candidates`)
/// since this — unlike everything else in a `resolve()` call — doesn't depend
/// on which episode is being played.
#[derive(Clone)]
pub(crate) struct SeadexRelease {
    info_hash: String,
    torrent_url: Option<String>,
    files: Vec<String>,
    group: String,
    is_best: bool,
}

/// One `seadex.moe` fetch + parse, filtered to the trackable (Nyaa) subset.
/// `None` means the fetch or parse itself failed — as opposed to a
/// successful fetch that just has nothing for this `media_id` — so the
/// caller knows not to cache it: a transient outage should be retried by the
/// next episode, not remembered as "no SeaDex entry" for the rest of the app
/// session.
async fn fetch_releases(client: &reqwest::Client, media_id: i64) -> Option<Vec<SeadexRelease>> {
    let url = format!(
        "https://{}/api/collections/entries/records?filter=alID%3D{}&expand=trs",
        HOST,
        media_id
    );
    // Per-request deadline: the shared client has none, and this lookup runs
    // inside the same wave as the indexers, so a SeaDex that accepts
    // the connection and never answers would hold every resolve open.
    let get = |client: &reqwest::Client| {
        client.get(&url).timeout(super::search::INDEX_TIMEOUT).send()
    };
    let mut sent = get(client).await;
    if matches!(&sent, Err(e) if e.is_connect()) {
        if let Some(direct) = direct_client().await {
            sent = get(direct).await;
        }
    }
    let resp = match sent.and_then(|r| r.error_for_status()) {
        Ok(r) => r,
        Err(e) => {
            log::warn!("torrent: seadex lookup failed for alID {}: {}", media_id, e);
            return None;
        }
    };
    let json: Value = match resp.json().await {
        Ok(j) => j,
        Err(e) => {
            log::warn!("torrent: seadex response unparsable for alID {}: {}", media_id, e);
            return None;
        }
    };

    Some(parse_releases(&json))
}

/// SeaDex moved from releases.moe, which now answers every request with a
/// 301 to here.
const HOST: &str = "seadex.moe";

/// A client that reaches SeaDex at an address from Cloudflare's
/// DNS-over-HTTPS, for when the system resolver cannot find it. The owner's
/// home DNS fails both releases.moe and seadex.moe (SERVFAIL) while 1.1.1.1
/// answers, and every
/// lookup failed with "error sending request" on the Mac and the TV alike,
/// so the SeaDex pick never reached a single resolve. Asked by IP, so the
/// resolver that failed is not in the way. Built once; a failed attempt is
/// not kept, so the next lookup tries again.
async fn direct_client() -> Option<&'static reqwest::Client> {
    static DIRECT: tokio::sync::OnceCell<reqwest::Client> = tokio::sync::OnceCell::const_new();
    DIRECT
        .get_or_try_init(|| async {
            let ip = doh_lookup(HOST).await.ok_or(())?;
            log::info!("torrent: seadex reached through DNS-over-HTTPS at {}", ip);
            reqwest::Client::builder()
                .resolve(HOST, std::net::SocketAddr::new(ip, 443))
                .build()
                .map_err(|_| ())
        })
        .await
        .ok()
}

async fn doh_lookup(host: &str) -> Option<std::net::IpAddr> {
    let json: Value = reqwest::Client::new()
        .get(format!("https://1.1.1.1/dns-query?name={}&type=A", host))
        .header("accept", "application/dns-json")
        .timeout(super::search::INDEX_TIMEOUT)
        .send()
        .await
        .ok()?
        .json()
        .await
        .ok()?;
    // Type 1 is an A record; a CNAME in the chain comes first and is skipped.
    json["Answer"]
        .as_array()?
        .iter()
        .filter(|a| a["type"] == 1)
        .find_map(|a| a["data"].as_str()?.parse().ok())
}

/// The Nyaa-tracked torrents in one `seadex.moe` records response.
fn parse_releases(json: &Value) -> Vec<SeadexRelease> {
    let mut releases = vec![];
    for item in json["items"].as_array().into_iter().flatten() {
        for tr in item["expand"]["trs"].as_array().into_iter().flatten() {
            // AB (AnimeBytes) entries are real, but a private tracker anicat
            // has no login for — the url/infoHash exist but nothing could
            // ever fetch them.
            if tr["tracker"].as_str() != Some("Nyaa") {
                continue;
            }
            let Some(info_hash) = tr["infoHash"].as_str().filter(|h| !h.is_empty()) else { continue };
            let files: Vec<String> = tr["files"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|f| f["name"].as_str().map(String::from))
                .collect();
            if files.is_empty() {
                continue;
            }
            let torrent_url = tr["url"].as_str().and_then(|u| {
                if u.contains("nyaa.si/view/") {
                    Some(format!("{}.torrent", u.replace("/view/", "/download/")))
                } else {
                    None
                }
            });
            releases.push(SeadexRelease {
                info_hash: info_hash.to_string(),
                torrent_url,
                files,
                group: tr["releaseGroup"].as_str().unwrap_or("?").to_string(),
                is_best: tr["isBest"].as_bool().unwrap_or(false),
            });
        }
    }
    releases
}

/// `anilist_id` is `None` for a TMDB title. SeaDex is a curated list of anime
/// releases indexed by AniList id and has no entry for a film or a live-action
/// series at all, so there is nothing to ask it — asking anyway with some
/// other catalog's integer would look up an unrelated anime and hand the
/// resolver a curated release for the wrong show.
pub(crate) async fn find_candidates(
    client: &reqwest::Client,
    cache: &tokio::sync::Mutex<HashMap<i64, Vec<SeadexRelease>>>,
    anilist_id: Option<i64>,
    titles: &[String],
    episode: i64,
    allow_episodeless: bool,
    episode_count: Option<i64>,
) -> Vec<Candidate> {
    let Some(media_id) = anilist_id else {
        return vec![];
    };
    if titles.is_empty() {
        return vec![];
    }

    // SeaDex's picks for a `media_id` don't change between episodes — a
    // curated release is a long-lived community decision, not something that
    // gets re-judged per episode — so binge-watching a show used to mean
    // every episode after the first re-fetched byte-identical JSON from
    // SeaDex for no reason. Cache the parsed releases per `media_id`
    // and only re-run the (cheap, local) episode-matching below on repeat
    // calls.
    let releases = {
        let cached = cache.lock().await.get(&media_id).cloned();
        match cached {
            Some(r) => r,
            None => {
                let Some(fetched) = fetch_releases(client, media_id).await else {
                    return vec![];
                };
                cache.lock().await.insert(media_id, fetched.clone());
                fetched
            }
        }
    };

    let alts: Vec<String> = titles.iter().map(|t| normalize(t)).collect();
    let mut out = vec![];
    for rel in &releases {
        let files: Vec<&str> = rel.files.iter().map(String::as_str).collect();

        // A single file linked to this alID is, by construction of
        // SeaDex's per-entry curation, this entry's whole content — there
        // is nothing else in the torrent it could be confused with.
        //
        // A torrent with more than one file is a different story: SeaDex
        // "torrents" records can be franchise-wide box sets — season 1,
        // season 2, OVAs, and this entry's shorts all bundled into one
        // release — cross-linked to every alID whose files it happens to
        // satisfy. Measured live on Chuunibyou's "Ren Lite" (alID 20582):
        // the record backing it is a 22-file YURI box set whose *other*
        // files are season 2's "S02E01".."S02E12", and matching "episode
        // 2" against any file in the torrent, title be damned, picked
        // "S02E02" and played the wrong season entirely.
        //
        // Title-matching every file only catches half of this: MTBB's
        // box set for the *other* "Lite" entry (alID 15687) numbers its
        // season-1 files as bare "- 01" .. "- 12" with no season marker
        // at all, so the title check alone cannot tell those apart from a
        // same-named Lite episode — nothing in the text does. What does
        // give it away is the count: that torrent has 14 files for a
        // 6-episode entry. So a batch is only trusted when every file
        // title-matches under some candidate title *and* the file count
        // equals this entry's own episode count — a mismatch on either
        // means the torrent is bundling more than this entry, and no
        // per-file text can be trusted to sort out which files are ours.
        let matches = if files.len() == 1 {
            allow_episodeless || filename_matches_episode(files[0], episode)
        } else {
            let title_ok = alts
                .iter()
                .any(|qn| files.iter().all(|f| title_matches_with_alts(qn, f, &alts)));
            let count_ok = episode_count.is_none_or(|c| c == files.len() as i64);
            if !title_ok || !count_ok {
                false
            } else {
                let file_eps: Vec<i64> = files.iter().filter_map(|f| filename_episode(f)).collect();
                files.iter().any(|f| filename_matches_episode(f, episode))
                    || absolute_episode(&file_eps, episode, episode_count).is_some()
            }
        };
        if !matches {
            continue;
        }

        let mut score = SEADEX_SCORE;
        if rel.is_best {
            score += SEADEX_BEST_BONUS;
        }
        out.push(Candidate {
            name: format!("[SeaDex{}] {}", if rel.is_best { " Best" } else { "" }, rel.group),
            magnet: Some(magnet_from_infohash(&rel.info_hash)),
            torrent_url: rel.torrent_url.clone(),
            // Not reported by the API. SeaDex entries are long-lived
            // community picks on a public tracker, not fresh uploads, so
            // treating them as healthy is the same bet already made for
            // SubsPlease's API results just below in the ranking.
            seeders: 50,
            seeders_known: false,
            size_bytes: None,
            score,
            assume_batch: files.len() > 1,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The shape `seadex.moe/api/collections/entries/records?expand=trs`
    /// answers with, cut to the fields `parse_releases` reads.
    const FIXTURE: &str = r#"{
        "items": [{
            "alID": 20582,
            "expand": {"trs": [
                {"tracker": "Nyaa", "infoHash": "aaaa", "url": "https://nyaa.si/view/123",
                 "releaseGroup": "YURI", "isBest": true,
                 "files": [{"name": "[YURI] Show Lite - 02.mkv", "length": 1}]},
                {"tracker": "AB", "infoHash": "bbbb", "url": "/torrents.php?id=1",
                 "releaseGroup": "Private", "isBest": true,
                 "files": [{"name": "Show Lite - 02.mkv", "length": 1}]},
                {"tracker": "Nyaa", "infoHash": "", "url": "https://nyaa.si/view/9",
                 "releaseGroup": "NoHash", "files": [{"name": "x.mkv"}]},
                {"tracker": "Nyaa", "infoHash": "cccc", "url": "https://example.org/x",
                 "releaseGroup": "NoFiles", "files": []}
            ]}
        }]
    }"#;

    #[test]
    fn only_nyaa_releases_with_a_hash_and_files_are_kept() {
        let json: Value = serde_json::from_str(FIXTURE).unwrap();
        let releases = parse_releases(&json);
        assert_eq!(releases.len(), 1);
        let r = &releases[0];
        assert_eq!(r.info_hash, "aaaa");
        assert_eq!(r.group, "YURI");
        assert!(r.is_best);
        assert_eq!(r.files, vec!["[YURI] Show Lite - 02.mkv".to_string()]);
        assert_eq!(r.torrent_url.as_deref(), Some("https://nyaa.si/download/123.torrent"));
    }

    #[tokio::test]
    async fn a_cached_pick_becomes_a_candidate_without_a_fetch() {
        let json: Value = serde_json::from_str(FIXTURE).unwrap();
        let cache = tokio::sync::Mutex::new(HashMap::from([(20582, parse_releases(&json))]));
        let titles = vec!["Show Lite".to_string()];
        let found =
            find_candidates(&reqwest::Client::new(), &cache, Some(20582), &titles, 2, false, Some(6)).await;
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "[SeaDex Best] YURI");
        assert_eq!(found[0].score, SEADEX_SCORE + SEADEX_BEST_BONUS);
        assert!(!found[0].assume_batch);
    }
}
