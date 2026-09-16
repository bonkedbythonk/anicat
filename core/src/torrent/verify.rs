//! Checking a release against AniDB before it plays.
//!
//! Everything else in `torrent/` decides what a release is from its name, and
//! a name can say anything: AniList lists "GGO" as a synonym of Sword Art
//! Online II, a pack of the Gun Gale Online spin-off ends in "(GGO)", and three
//! episodes played the spin-off. AniDB identifies releases by their files'
//! hashes, not their names, and AnimeTosho carries its verdict for nearly
//! every Nyaa torrent (`anidb_aid`). arm.haglund.dev maps an AniList entry to
//! its AniDB id.
//!
//! The check is on the *show*, not the episode: AnimeTosho leaves `anidb_eid`
//! empty for packs, which are most releases. It is also franchise-wide rather
//! than exact, because a combined pack carries its first season's id (the
//! Shinmai Maou "Season 1+2+OVA" pack is AniDB 10529, while its second season
//! is 11680) and `layout` exists to serve exactly those packs. What it refuses
//! is a release AniDB places outside this entry's prequel/sequel chain: a
//! spin-off, or another show entirely. When either side has no AniDB id the
//! check says nothing and names decide, as they always did.

use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use super::search::Candidate;

/// The AniDB ids of an entry's prequel/sequel chain, arriving while the search
/// runs. The outer `None` is "not known yet"; `Some(None)` is "could not be
/// established", which is as good as no check.
pub type FranchiseAids = tokio::sync::watch::Receiver<Option<Option<Arc<HashSet<i64>>>>>;

/// How long a candidate waits for either side of the check. The AnimeTosho
/// lookup by Nyaa id answered in 0.12 s; the franchise set is usually ready
/// before the search is. Past this a release plays on its name, because a
/// slow third-party host must never be the reason a play is slow.
pub const VERIFY_BUDGET: Duration = Duration::from_millis(2500);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Verdict {
    Matches,
    /// AniDB places the release in this AniDB anime, outside the franchise.
    OtherAnime(i64),
    Unknown,
}

pub fn judge(release_aid: Option<i64>, franchise: Option<&HashSet<i64>>) -> Verdict {
    match (release_aid, franchise) {
        (Some(aid), Some(set)) if !set.is_empty() => {
            if set.contains(&aid) {
                Verdict::Matches
            } else {
                Verdict::OtherAnime(aid)
            }
        }
        _ => Verdict::Unknown,
    }
}

/// The Nyaa id in a `nyaa.si/download/<id>.torrent` URL.
pub fn nyaa_id(torrent_url: &str) -> Option<u64> {
    let rest = torrent_url.split("nyaa.si/download/").nth(1)?;
    rest.split('.').next()?.parse().ok()
}

/// The AniDB anime AnimeTosho assigns a release to. `None` when it has not
/// indexed the torrent, has not matched it, or did not answer in time.
pub async fn release_aid(client: &reqwest::Client, cand: &Candidate) -> Option<i64> {
    if cand.anidb_aid.is_some() {
        return cand.anidb_aid;
    }
    // Only by Nyaa id. The info-hash lookup works too but took 2.4 s against
    // 0.12 s, and a SubsPlease magnet is the only candidate without a Nyaa id.
    let id = cand.torrent_url.as_deref().and_then(nyaa_id)?;
    let url = format!("https://feed.animetosho.org/json?show=torrent&nyaa_id={}", id);
    let resp = client.get(&url).timeout(VERIFY_BUDGET).send().await.ok()?;
    let body: serde_json::Value = resp.json().await.ok()?;
    body.get("anidb_aid").and_then(|v| v.as_i64())
}

/// An AniList entry's AniDB id, from arm.haglund.dev. `Err` when the host did
/// not answer, so the caller does not store a failure as "no mapping".
pub async fn anidb_for_anilist(client: &reqwest::Client, anilist_id: i64) -> Result<Option<i64>, String> {
    let url = format!("https://arm.haglund.dev/api/v2/ids?source=anilist&id={}", anilist_id);
    let resp = client
        .get(&url)
        .timeout(Duration::from_secs(5))
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if resp.status() == reqwest::StatusCode::NOT_FOUND {
        return Ok(None);
    }
    let resp = resp.error_for_status().map_err(|e| e.to_string())?;
    // The API answers `null` for an id it has never heard of.
    let body: serde_json::Value = resp.json().await.map_err(|e| e.to_string())?;
    Ok(body.get("anidb").and_then(|v| v.as_i64()))
}

/// Relations that stay inside one show's run. A combined pack spans seasons
/// and their OVAs; a spin-off or an alternative version is a different show
/// even when it shares the name.
pub fn is_chain_relation(relation: &str) -> bool {
    matches!(relation, "PREQUEL" | "SEQUEL" | "PARENT" | "SIDE_STORY")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_spin_off_is_refused_and_a_combined_pack_is_not() {
        // Sword Art Online II (10376) and its chain: SAO (8692), Extra
        // Edition, Ordinal Scale. Gun Gale Online is 13939.
        let sao2: HashSet<i64> = [10376, 8692, 10918, 11681].into_iter().collect();
        assert_eq!(judge(Some(10376), Some(&sao2)), Verdict::Matches);
        assert_eq!(judge(Some(8692), Some(&sao2)), Verdict::Matches);
        assert_eq!(judge(Some(13939), Some(&sao2)), Verdict::OtherAnime(13939));
        assert_eq!(judge(None, Some(&sao2)), Verdict::Unknown);
        assert_eq!(judge(Some(13939), None), Verdict::Unknown);
        assert_eq!(judge(Some(13939), Some(&HashSet::new())), Verdict::Unknown);
    }

    #[test]
    fn nyaa_ids_come_out_of_download_urls() {
        assert_eq!(nyaa_id("https://nyaa.si/download/1193069.torrent"), Some(1193069));
        assert_eq!(nyaa_id("https://storage.animetosho.org/torrent/abc/x.torrent"), None);
    }
}
