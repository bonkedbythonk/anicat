//! Picking seeds and ranking their recommendations: the two decisions behind
//! a "Because you watched" shelf, kept apart from the request that feeds them
//! so both can be tested without AniList.
//!
//! Neither function knows what a `MediaItem` is. `Recommendation` carries the
//! catalog record as an opaque payload, which is what lets the tests below
//! rank rows made of nothing.

use std::collections::{HashMap, HashSet};

/// A title the shelf can say "because you watched" about. Built from the
/// viewer's own list, so the score and the timestamp are theirs.
#[derive(Debug, Clone, PartialEq)]
pub struct Seed {
    pub catalog_id: i64,
    pub title: String,
    pub user_score: Option<f64>,
    /// Unix seconds of the last list update.
    pub updated_at: Option<i64>,
}

/// One recommendation with the seed it came from. `M` is the catalog record
/// the caller wants back.
#[derive(Debug, Clone, PartialEq)]
pub struct Recommendation<M> {
    pub media: M,
    pub media_id: i64,
    pub because_catalog_id: i64,
    pub because_title: String,
    pub rating: i32,
}

/// The strongest signals the viewer has given: what they rated highest, and
/// among equals what they touched last.
///
/// An unscored entry sorts as zero rather than being dropped — a viewer who
/// never scores anything would otherwise get no seeds at all and an empty
/// shelf forever.
pub fn pick_seeds(mut seeds: Vec<Seed>, max: usize) -> Vec<Seed> {
    seeds.sort_by(|a, b| {
        b.user_score
            .unwrap_or(0.0)
            .partial_cmp(&a.user_score.unwrap_or(0.0))
            .unwrap_or(std::cmp::Ordering::Equal)
            .then(b.updated_at.unwrap_or(0).cmp(&a.updated_at.unwrap_or(0)))
            // Two entries scored and updated identically must not swap places
            // between launches: the shelf would reshuffle for no reason the
            // viewer can see, and the cache key is the seed id set.
            .then(a.catalog_id.cmp(&b.catalog_id))
    });
    seeds.truncate(max);
    seeds
}

/// Drops what the viewer already has, collapses the same title recommended by
/// several seeds onto its best-rated edge, and sorts what is left.
///
/// The dedupe is what makes the shelf worth showing: six seeds from one taste
/// recommend each other's neighbours constantly, and without this the row is
/// the same four titles repeated with different captions.
pub fn rank<M>(
    candidates: Vec<Recommendation<M>>,
    on_list: &HashSet<i64>,
    limit: usize,
) -> Vec<Recommendation<M>> {
    let mut best: HashMap<i64, Recommendation<M>> = HashMap::new();
    for candidate in candidates {
        if on_list.contains(&candidate.media_id) {
            continue;
        }
        match best.get(&candidate.media_id) {
            Some(kept) if kept.rating >= candidate.rating => {}
            _ => {
                best.insert(candidate.media_id, candidate);
            }
        }
    }
    let mut out: Vec<Recommendation<M>> = best.into_values().collect();
    // `best` is a HashMap, so the vec arrives in whatever order the hasher
    // produced; the id tie-break is the only thing that keeps two equally
    // rated titles in the same order on the next call.
    out.sort_by(|a, b| b.rating.cmp(&a.rating).then(a.media_id.cmp(&b.media_id)));
    out.truncate(limit);
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn seed(id: i64, score: Option<f64>, updated: Option<i64>) -> Seed {
        Seed {
            catalog_id: id,
            title: format!("Title {id}"),
            user_score: score,
            updated_at: updated,
        }
    }

    fn rec(media_id: i64, rating: i32, because: i64) -> Recommendation<()> {
        Recommendation {
            media: (),
            media_id,
            because_catalog_id: because,
            because_title: format!("Title {because}"),
            rating,
        }
    }

    #[test]
    fn seeds_are_scored_first_and_recent_second() {
        let picked = pick_seeds(
            vec![
                seed(1, Some(7.0), Some(500)),
                seed(2, Some(9.0), Some(100)),
                seed(3, Some(9.0), Some(400)),
                seed(4, None, Some(900)),
            ],
            3,
        );
        assert_eq!(picked.iter().map(|s| s.catalog_id).collect::<Vec<_>>(), [3, 2, 1]);
    }

    #[test]
    fn an_unscored_list_still_yields_seeds() {
        // A viewer who never scores anything: without the zero fallback every
        // entry compares equal to every other and the shelf has no seeds.
        let picked = pick_seeds(
            vec![seed(1, None, Some(10)), seed(2, None, Some(30)), seed(3, None, Some(20))],
            2,
        );
        assert_eq!(picked.iter().map(|s| s.catalog_id).collect::<Vec<_>>(), [2, 3]);
    }

    #[test]
    fn a_title_recommended_by_two_seeds_appears_once_at_its_best_rating() {
        let out = rank(
            vec![rec(50, 30, 1), rec(50, 120, 2), rec(60, 80, 1)],
            &HashSet::new(),
            10,
        );
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].media_id, 50);
        assert_eq!(out[0].rating, 120);
        assert_eq!(out[0].because_catalog_id, 2);
        assert_eq!(out[1].media_id, 60);
    }

    #[test]
    fn anything_already_on_the_list_is_dropped_then_the_rest_is_capped() {
        let mut on_list = HashSet::new();
        on_list.insert(60);
        let out = rank(
            vec![rec(50, 30, 1), rec(60, 200, 1), rec(70, 90, 1)],
            &on_list,
            1,
        );
        assert_eq!(out.iter().map(|r| r.media_id).collect::<Vec<_>>(), [70]);
    }
}
