//! A franchise's watch order, walked across AniList's relation graph.
//!
//! A title's own `relations` are one step deep: Sword Art Online lists
//! Extra Edition and SAO II as sequels, and nothing past them -- Ordinal
//! Scale, Alicization and War of Underworld are sequels of sequels, and the
//! Related tab's timeline never reached them. This follows the main line
//! (prequels, sequels, parents) level by level, one batched request per
//! level, then picks up the side stories and spin-offs hanging off it.

use std::collections::{HashMap, HashSet};
use std::future::Future;

use super::anilist::types::MediaItem;

/// Relation types that keep walking: the story's own chain. `PARENT` is on
/// it so that opening a side story still finds the series it belongs to.
const MAIN_LINE: [&str; 3] = ["PREQUEL", "SEQUEL", "PARENT"];

/// Watchable, but off the spine. Collected from main-line entries only and
/// never walked further: a spin-off's own sequels are that spin-off's line,
/// and the timeline is about the series that was opened.
const ASIDES: [&str; 5] = ["SIDE_STORY", "SPIN_OFF", "ALTERNATIVE", "SUMMARY", "COMPILATION"];

/// Bounds on the walk, not measurements of any franchise: the seen set
/// already stops a cycle, the depth cap stops a runaway chain of mislinked
/// entries, and the node cap keeps the whole walk to a handful of requests.
const MAX_DEPTH: usize = 40;
const MAX_NODES: usize = 100;
/// AniList's `Page.perPage` ceiling.
pub const BATCH: usize = 50;

#[derive(Debug, Clone)]
pub struct FranchiseEntry {
    pub media: MediaItem,
    /// `None` on the main line; the aside's own relation type otherwise.
    pub aside: Option<String>,
}

fn same_type(node: &MediaItem, media_type: &Option<String>) -> bool {
    media_type.is_none() || node.media_type == *media_type
}

/// Walks from `root`. `fetch` loads full entries for up to `BATCH` ids at a
/// time. Adult entries are dropped wherever they turn up, the same rule
/// every other AniList list in the engine applies.
pub async fn walk<F, Fut>(root: i64, mut fetch: F) -> Result<Vec<FranchiseEntry>, String>
where
    F: FnMut(Vec<i64>) -> Fut,
    Fut: Future<Output = Result<Vec<MediaItem>, String>>,
{
    let mut main: Vec<MediaItem> = Vec::new();
    let mut seen: HashSet<i64> = HashSet::from([root]);
    let mut asides: HashMap<i64, String> = HashMap::new();
    let mut media_type: Option<String> = None;
    let mut frontier = vec![root];

    for _ in 0..MAX_DEPTH {
        if frontier.is_empty() || main.len() >= MAX_NODES {
            break;
        }
        let mut next = Vec::new();
        for chunk in frontier.chunks(BATCH) {
            for node in fetch(chunk.to_vec()).await? {
                if node.is_adult.unwrap_or(false) {
                    continue;
                }
                if node.id == root {
                    media_type = node.media_type.clone();
                }
                let edges = node
                    .relations
                    .as_ref()
                    .and_then(|r| r.edges.as_ref())
                    .cloned()
                    .unwrap_or_default();
                for edge in edges {
                    let (Some(kind), Some(target)) = (edge.relation_type.as_deref(), edge.node.as_deref()) else {
                        continue;
                    };
                    if target.is_adult.unwrap_or(false) || !same_type(target, &media_type) {
                        continue;
                    }
                    if MAIN_LINE.contains(&kind) {
                        if seen.insert(target.id) {
                            next.push(target.id);
                        }
                    } else if ASIDES.contains(&kind) {
                        asides.entry(target.id).or_insert_with(|| kind.to_string());
                    }
                }
                main.push(node);
            }
        }
        frontier = next;
    }

    let main_ids: HashSet<i64> = main.iter().map(|m| m.id).collect();
    let mut aside_ids: Vec<i64> = asides.keys().copied().filter(|id| !main_ids.contains(id)).collect();
    aside_ids.sort_unstable();
    aside_ids.truncate(MAX_NODES.saturating_sub(main.len()));

    let mut entries: Vec<FranchiseEntry> =
        main.into_iter().map(|media| FranchiseEntry { media, aside: None }).collect();
    for chunk in aside_ids.chunks(BATCH) {
        for media in fetch(chunk.to_vec()).await? {
            if media.is_adult.unwrap_or(false) || !same_type(&media, &media_type) {
                continue;
            }
            let aside = asides.get(&media.id).cloned();
            entries.push(FranchiseEntry { media, aside });
        }
    }
    Ok(entries)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::catalog::anilist::types::{MediaConnection, MediaEdge};

    fn node(id: i64, edges: &[(&str, i64)]) -> MediaItem {
        let mut item: MediaItem = serde_json::from_value(serde_json::json!({ "id": id, "type": "ANIME" })).unwrap();
        item.relations = Some(MediaConnection {
            edges: Some(
                edges
                    .iter()
                    .map(|(kind, target)| MediaEdge {
                        relation_type: Some(kind.to_string()),
                        node: Some(Box::new(
                            serde_json::from_value(serde_json::json!({ "id": target, "type": "ANIME" })).unwrap(),
                        )),
                        character_role: None,
                        staff_role: None,
                        characters: None,
                        voice_actors: None,
                    })
                    .collect(),
            ),
        });
        item
    }

    /// Sword Art Online's shape: season 1 knows only its direct sequels,
    /// the rest of the line is two and three steps away.
    fn sao() -> HashMap<i64, MediaItem> {
        [
            node(1, &[("SEQUEL", 2), ("SEQUEL", 3), ("CHARACTER", 90)]),
            node(2, &[("PREQUEL", 1)]),
            node(3, &[("PREQUEL", 1), ("SEQUEL", 4), ("SPIN_OFF", 7)]),
            node(4, &[("PREQUEL", 3), ("SEQUEL", 5)]),
            node(5, &[("PREQUEL", 4)]),
            node(7, &[("PARENT", 3), ("SEQUEL", 8)]),
            node(8, &[("PREQUEL", 7)]),
            node(90, &[]),
        ]
        .into_iter()
        .map(|m| (m.id, m))
        .collect()
    }

    async fn run(root: i64, graph: &HashMap<i64, MediaItem>) -> (Vec<i64>, Vec<(i64, String)>, usize) {
        let mut calls = 0;
        let entries = walk(root, |ids| {
            calls += 1;
            let found: Vec<MediaItem> = ids.iter().filter_map(|id| graph.get(id).cloned()).collect();
            async move { Ok(found) }
        })
        .await
        .unwrap();
        let mut main: Vec<i64> = entries.iter().filter(|e| e.aside.is_none()).map(|e| e.media.id).collect();
        main.sort_unstable();
        let asides = entries.iter().filter_map(|e| e.aside.clone().map(|a| (e.media.id, a))).collect();
        (main, asides, calls)
    }

    #[tokio::test]
    async fn walks_past_the_direct_sequels() {
        let (main, asides, calls) = run(1, &sao()).await;
        assert_eq!(main, vec![1, 2, 3, 4, 5]);
        // The spin-off is collected but its own sequel is not followed, and
        // the shared-character link is not part of the watch order at all.
        assert_eq!(asides, vec![(7, "SPIN_OFF".to_string())]);
        // One request per level of the main line (1; 2,3; 4; 5) plus one
        // for the asides -- never one per title.
        assert_eq!(calls, 5);
    }

    #[tokio::test]
    async fn a_side_story_finds_its_series_through_its_parent() {
        let (main, _, _) = run(7, &sao()).await;
        assert!(main.contains(&3) && main.contains(&1) && main.contains(&5));
    }

    #[tokio::test]
    async fn a_cycle_ends() {
        let graph: HashMap<i64, MediaItem> =
            [node(1, &[("SEQUEL", 2)]), node(2, &[("SEQUEL", 1)])].into_iter().map(|m| (m.id, m)).collect();
        let (main, _, calls) = run(1, &graph).await;
        assert_eq!(main, vec![1, 2]);
        assert_eq!(calls, 2);
    }
}
