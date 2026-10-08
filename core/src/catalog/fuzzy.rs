//! Typo tolerance for the AniList title search.
//!
//! AniList matches whole words and word prefixes and nothing else (measured
//! 2026-10-08: "narutp", "one pice", "attak on titan" and "steinsgate" each
//! return zero rows, and "journeys end" misses "Journey's End" while
//! "journey's end" finds it). So when a search comes back thin, the engine
//! asks AniList again with a handful of rewritten queries, pools what comes
//! back, and ranks the pool by how close each title is to what was typed.

use super::anilist::types::MediaItem;

/// A title below this is a coincidence of the rewrite, not a match. Two edits
/// in a six-letter word ("naturo" for "naruto") still clear it.
const MIN_SCORE: f64 = 0.6;
/// How far below the best rewrite's title another may sit. This, not a higher
/// floor, keeps "Bloom Into You" (two edits from "narutp" through the word
/// "naru") out once Naruto (one edit) has been found, while a query with only
/// two-edit matches still shows them.
const BEST_MARGIN: f64 = 0.15;
/// Each rewrite is a request through AniList's rate limit (measured
/// 2026-10-08: six at once drew 429s and a 52 s wait on the next search).
const MAX_VARIANTS: usize = 5;
/// A title this close to the query ends the hunt for more rewrites.
const CLOSE: f64 = 0.8;

/// Latin letters with accents or macrons as plain letters. AniList matches
/// "Deja vu" to "Déjà vu" and not the other way round (measured 2026-10-08:
/// "Steins;Gate: Fuka Ryouiki no Déjà vu" finds nothing, the plain spelling
/// finds it), and nobody types "pokémon" with the accent on a plain keyboard.
pub fn fold(s: &str) -> String {
    s.chars()
        .map(|c| {
            let base = match c.to_lowercase().next().unwrap_or(c) {
                'à' | 'á' | 'â' | 'ä' | 'ã' | 'å' | 'ā' => 'a',
                'è' | 'é' | 'ê' | 'ë' | 'ē' => 'e',
                'ì' | 'í' | 'î' | 'ï' | 'ī' => 'i',
                'ò' | 'ó' | 'ô' | 'ö' | 'õ' | 'ō' => 'o',
                'ù' | 'ú' | 'û' | 'ü' | 'ū' => 'u',
                'ñ' => 'n',
                'ç' => 'c',
                _ => return c,
            };
            if c.is_uppercase() { base.to_ascii_uppercase() } else { base }
        })
        .collect()
}

/// Lowercase words, apostrophes removed so "journey's" and "journeys" agree.
fn tokens(s: &str) -> Vec<String> {
    let cleaned: String = fold(s)
        .chars()
        .filter(|c| !matches!(c, '\'' | '\u{2019}' | '\u{2018}' | '\u{02bc}'))
        .collect();
    cleaned
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(str::to_lowercase)
        .collect()
}

/// Edit distance where swapping two letters costs one, next to each other or
/// with one between: "naurto" and "naturo" are one slip of the fingers, not two.
fn distance(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    let mut d = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for (j, cell) in d[0].iter_mut().enumerate() {
        *cell = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            d[i][j] = (d[i - 1][j] + 1).min(d[i][j - 1] + 1).min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = d[i][j].min(d[i - 2][j - 2] + 1);
            }
            // "naturo" for "naruto": two letters traded across the one between.
            if i > 2 && j > 2 && a[i - 1] == b[j - 3] && a[i - 3] == b[j - 1] && a[i - 2] == b[j - 2] {
                d[i][j] = d[i][j].min(d[i - 3][j - 3] + 1);
            }
        }
    }
    d[n][m]
}

fn similarity(a: &[char], b: &[char]) -> f64 {
    let longest = a.len().max(b.len());
    if longest == 0 {
        return 1.0;
    }
    1.0 - distance(a, b) as f64 / longest as f64
}

/// How well one typed word is covered by one title word. A typed word that
/// is the start of the title word is a finished match (the viewer is still
/// typing), and a typo inside that start is forgiven at a small discount.
fn word_score(typed: &[char], title: &[char]) -> f64 {
    let whole = similarity(typed, title);
    if typed.len() >= title.len() {
        return whole;
    }
    whole.max(0.95 * similarity(typed, &title[..typed.len()]))
}

/// 0.0 to 1.0: how close the title is to the query, weighting longer typed
/// words more so a stray "my" or "the" cannot decide the order.
fn title_score(query: &[Vec<char>], title: &str) -> f64 {
    let words: Vec<Vec<char>> = tokens(title).iter().map(|t| t.chars().collect()).collect();
    if words.is_empty() || query.is_empty() {
        return 0.0;
    }
    // "steinsgate" for "Steins;Gate": the title with its gaps closed.
    let joined: Vec<char> = words.iter().flatten().copied().collect();
    let (mut sum, mut weight) = (0.0, 0.0);
    for typed in query {
        let best = words
            .iter()
            .chain(std::iter::once(&joined))
            .map(|w| word_score(typed, w))
            .fold(0.0, f64::max);
        sum += best * typed.len() as f64;
        weight += typed.len() as f64;
    }
    sum / weight
}

fn item_score(query: &[Vec<char>], item: &MediaItem) -> f64 {
    let mut names: Vec<&str> = Vec::new();
    if let Some(t) = &item.title {
        names.extend([&t.romaji, &t.english, &t.native].into_iter().flatten().map(String::as_str));
    }
    if let Some(s) = &item.synonyms {
        names.extend(s.iter().map(String::as_str));
    }
    names.into_iter().map(|n| title_score(query, n)).fold(0.0, f64::max)
}

/// Pages of 50 in the index of popular titles. Beyond these the shows are
/// ones a viewer types in full, or that AniList's own prefix match finds.
pub const INDEX_PAGES: i32 = 10;

/// Held while the index is built so two thin searches do not both pay for it.
pub static INDEX_BUILD: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

/// The names of each indexed show (romaji, English, synonyms).
pub fn index_entry(item: &MediaItem) -> Vec<String> {
    let mut names: Vec<String> = Vec::new();
    if let Some(t) = &item.title {
        names.extend([&t.romaji, &t.english].into_iter().flatten().cloned());
    }
    names.extend(item.synonyms.iter().flatten().cloned());
    names
}

/// The `n` indexed titles closest to the query, as a name AniList can be asked
/// for. This is what reaches "naruto" from "narutp", where cutting words short
/// cannot: AniList answers "narut" with nothing at all.
pub fn closest(query: &str, index: &[Vec<String>], n: usize) -> Vec<String> {
    let typed: Vec<Vec<char>> = tokens(query).iter().map(|t| t.chars().collect()).collect();
    let mut best: Vec<(f64, &str)> = index
        .iter()
        .filter_map(|names| {
            names
                .iter()
                .map(|name| (title_score(&typed, name), name.as_str()))
                .max_by(|a, b| a.0.total_cmp(&b.0))
        })
        .filter(|(score, _)| *score >= MIN_SCORE)
        .collect();
    best.sort_by(|a, b| b.0.total_cmp(&a.0));
    best.into_iter().take(n).map(|(_, name)| fold(name)).collect()
}

/// Rewrites of `query` that AniList might understand where the original
/// failed, most likely first, never the original itself.
pub fn variants(query: &str) -> Vec<String> {
    let straight = query.replace(['\u{2019}', '\u{2018}', '\u{02bc}'], "'");
    let words: Vec<&str> = straight.split_whitespace().collect();
    let mut out: Vec<String> = Vec::new();
    let mut push = |v: String| {
        let v = v.trim().to_string();
        if !v.is_empty() && v != query && !out.contains(&v) {
            out.push(v);
        }
    };

    // A curly apostrophe is what an iPhone keyboard types.
    push(straight.clone());

    // The apostrophe nobody types: "dont" for "don't". Only the contractions
    // that are not also words ("giant" must not become "gian't"). A possessive
    // ("journeys" for "journey's") needs no repair of its own: the cut-short
    // rewrite below turns it into "journey", which AniList accepts.
    const CONTRACTIONS: [&str; 13] = [
        "dont", "cant", "wont", "isnt", "arent", "wasnt", "werent", "didnt", "doesnt", "hasnt",
        "havent", "couldnt", "wouldnt",
    ];
    let contracted: Vec<String> = words
        .iter()
        .map(|w| {
            if CONTRACTIONS.contains(&w.to_lowercase().as_str()) {
                format!("{}'t", &w[..w.len() - 1])
            } else {
                w.to_string()
            }
        })
        .collect();
    push(contracted.join(" "));

    // AniList matches word starts, so cutting words short steps over a slip
    // near their end. A typed word that was right is only shortened, which a
    // prefix match still accepts.
    let trimmed = |keep: &dyn Fn(usize) -> usize| -> String {
        words
            .iter()
            .map(|w| {
                let chars: Vec<char> = w.chars().collect();
                if chars.len() >= 4 {
                    chars[..keep(chars.len())].iter().collect::<String>()
                } else {
                    w.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join(" ")
    };
    push(trimmed(&|n| n - 1));
    push(trimmed(&|n| (n * 3).div_ceil(5).max(3)));

    // A long query where only the opening is trusted.
    if words.len() >= 3 {
        push(contracted[..2].join(" "));
    }

    // One word that is simply wrong: drop each in turn.
    if (2..=4).contains(&words.len()) {
        for skip in 0..words.len() {
            let rest: Vec<&str> =
                words.iter().enumerate().filter(|(i, _)| *i != skip).map(|(_, w)| *w).collect();
            push(rest.join(" "));
        }
    }

    out.truncate(MAX_VARIANTS);
    out
}

/// Whether the rewrites have already found a title worth showing, so the
/// remaining ones need not be asked.
pub fn has_close_match(query: &str, found: &[MediaItem]) -> bool {
    let typed: Vec<Vec<char>> = tokens(query).iter().map(|t| t.chars().collect()).collect();
    found.iter().any(|m| item_score(&typed, m) >= CLOSE)
}

/// What AniList matched for the query itself and what the rewrites found,
/// closest title first, with the rewrites' strays gone. AniList's own matches
/// are never dropped: it may have matched on a name this file cannot see.
/// Equal scores go to the more popular. A show reached twice is kept once.
pub fn rank(query: &str, matched: Vec<MediaItem>, rewritten: Vec<MediaItem>) -> Vec<MediaItem> {
    let typed: Vec<Vec<char>> = tokens(query).iter().map(|t| t.chars().collect()).collect();
    let mut seen = std::collections::HashSet::new();
    let mut scored: Vec<(f64, MediaItem)> = Vec::new();
    for m in matched.into_iter().filter(|m| seen.insert(m.id)) {
        scored.push((item_score(&typed, &m).max(MIN_SCORE), m));
    }
    let found: Vec<(f64, MediaItem)> = rewritten
        .into_iter()
        .filter(|m| seen.insert(m.id))
        .map(|m| (item_score(&typed, &m), m))
        .collect();
    let best = found.iter().map(|(s, _)| *s).fold(0.0, f64::max);
    scored.extend(found.into_iter().filter(|(s, _)| *s >= MIN_SCORE && *s >= best - BEST_MARGIN));
    // "THE ONE PIECE" and "ONE PIECE" tie for "one pice"; the show people
    // mean is the popular one.
    scored.sort_by(|a, b| {
        b.0.total_cmp(&a.0).then(b.1.popularity.unwrap_or(0).cmp(&a.1.popularity.unwrap_or(0)))
    });
    scored.into_iter().map(|(_, m)| m).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: i64, romaji: &str, english: Option<&str>) -> MediaItem {
        serde_json::from_value(serde_json::json!({
            "id": id,
            "title": { "romaji": romaji, "english": english },
        }))
        .unwrap()
    }

    fn first(query: &str, pool: Vec<MediaItem>) -> Option<i64> {
        rank(query, Vec::new(), pool).first().map(|m| m.id)
    }

    #[test]
    fn variants_repair_the_missing_apostrophe_of_a_contraction_only() {
        assert!(variants("dont toy with me").contains(&"don't toy with me".to_string()));
        assert!(!variants("giant robo").iter().any(|v| v.contains("'")));
    }

    #[test]
    fn variants_turn_a_possessive_into_a_word_anilist_accepts() {
        assert!(variants("frieren beyond journeys end").contains(&"friere beyon journey end".to_string()));
    }

    #[test]
    fn variants_keep_the_opening_of_a_long_query() {
        assert!(variants("dont toy with me miss nagatoro").contains(&"don't toy".to_string()));
    }

    #[test]
    fn a_close_title_ends_the_hunt() {
        assert!(has_close_match("narutp", &[item(1, "NARUTO", None)]));
        assert!(!has_close_match("narutp", &[item(1, "Narudoma", None)]));
    }

    #[test]
    fn variants_straighten_a_phone_keyboards_apostrophe() {
        assert_eq!(variants("don\u{2019}t toy")[0], "don't toy");
    }

    #[test]
    fn variants_cut_words_short_to_step_over_a_late_typo() {
        let v = variants("attak on titan");
        assert!(v.contains(&"atta on tita".to_string()));
        assert!(variants("narutp").contains(&"narut".to_string()));
    }

    #[test]
    fn variants_skip_the_query_itself_and_stay_few() {
        let v = variants("one piece");
        assert!(!v.contains(&"one piece".to_string()));
        assert!(v.len() <= MAX_VARIANTS);
        assert!(variants("a").is_empty());
    }

    #[test]
    fn one_slip_still_ranks_the_right_title_first() {
        let pool = vec![
            item(1, "Ane Naru Mono", None),
            item(2, "NARUTO", None),
            item(3, "Narudoma", None),
        ];
        assert_eq!(first("narutp", pool.clone()), Some(2));
        assert_eq!(first("naurto", pool), Some(2));
    }

    #[test]
    fn english_title_beats_a_romaji_that_shares_only_some_words() {
        let pool = vec![
            item(1, "My Home Hero", None),
            item(2, "Boku no Hero Academia", Some("My Hero Academia")),
        ];
        assert_eq!(first("my hero acadmia", pool), Some(2));
    }

    #[test]
    fn a_tie_goes_to_the_more_popular_show() {
        let mut obscure = item(1, "The One Piece", None);
        obscure.popularity = Some(10);
        let mut famous = item(2, "One Piece", None);
        famous.popularity = Some(500_000);
        assert_eq!(first("one pice", vec![obscure, famous]), Some(2));
    }

    #[test]
    fn the_index_reaches_a_title_that_word_cutting_cannot() {
        let index = vec![
            vec!["Bloom Into You".to_string(), "Yagate Kimi ni Naru".to_string()],
            vec!["NARUTO".to_string()],
            vec!["Bleach".to_string()],
        ];
        assert_eq!(closest("narutp", &index, 2)[0], "NARUTO");
        assert!(closest("zzzzzz", &index, 2).is_empty());
    }

    #[test]
    fn a_closed_up_title_matches() {
        let pool = vec![item(1, "Steins;Gate", None), item(2, "Gate", None)];
        assert_eq!(first("steinsgate", pool), Some(1));
    }

    #[test]
    fn apostrophes_do_not_count_against_a_title() {
        let pool = vec![item(1, "Sousou no Frieren", Some("Frieren: Beyond Journey's End"))];
        assert_eq!(first("frieren beyond journeys end", pool), Some(1));
    }

    #[test]
    fn two_letters_swapped_across_a_letter_still_finds_it() {
        let index = vec![vec!["NARUTO".to_string()], vec!["Bleach".to_string()]];
        assert_eq!(closest("naturo", &index, 2), vec!["NARUTO".to_string()]);
        assert_eq!(first("naturo", vec![item(1, "NARUTO", None)]), Some(1));
    }

    #[test]
    fn accents_do_not_stand_between_a_query_and_a_title() {
        assert_eq!(fold("Steins;Gate: Déjà vu, Ōkami, ÉCOLE"), "Steins;Gate: Deja vu, Okami, ECOLE");
        assert_eq!(fold("ハンター"), "ハンター");
        let index = vec![vec!["Pokémon".to_string()]];
        assert_eq!(closest("pokemon", &index, 1), vec!["Pokemon".to_string()]);
    }

    #[test]
    fn a_swap_across_one_letter_costs_a_single_edit() {
        let chars = |s: &str| s.chars().collect::<Vec<_>>();
        assert_eq!(distance(&chars("buko"), &chars("boku")), 1);
        assert_eq!(distance(&chars("naturo"), &chars("naruto")), 1);
        assert_eq!(distance(&chars("naruot"), &chars("naruto")), 1);
    }

    #[test]
    fn a_coincidental_word_match_is_dropped_once_a_better_title_is_found() {
        let pool = vec![item(1, "Yagate Kimi ni Naru", Some("Bloom Into You")), item(2, "NARUTO", None)];
        let ranked = rank("narutp", Vec::new(), pool);
        assert_eq!(ranked.iter().map(|m| m.id).collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn a_title_nothing_like_the_query_is_dropped_and_duplicates_collapse() {
        let pool = vec![item(1, "Bleach", None), item(2, "Naruto", None), item(2, "Naruto", None)];
        let ranked = rank("narutp", Vec::new(), pool);
        assert_eq!(ranked.iter().map(|m| m.id).collect::<Vec<_>>(), vec![2]);
    }

    #[test]
    fn what_anilist_matched_itself_is_never_dropped() {
        let ranked = rank("kimi no na wa", vec![item(1, "Your Name.", None)], vec![item(2, "Bleach", None)]);
        assert_eq!(ranked.iter().map(|m| m.id).collect::<Vec<_>>(), vec![1]);
    }
}
