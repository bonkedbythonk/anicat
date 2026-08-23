//! Which file inside a torrent is the episode that was asked for.
//!
//! A franchise is one thing to a release group and many things to AniList.
//! "The Testament of Sister New Devil" is five AniList entries (two TV
//! seasons, two special collections, one OVA) and, on Nyaa, a single 24-file
//! torrent — or a flat 25-file one, or one with `Season 1/`, `Season 2/` and
//! `Special/` folders, or one with a folder per season *named after that
//! season's own title*. Every one of those layouts is in circulation for that
//! one show, and each hides the wanted episode somewhere different.
//!
//! Matching an episode number against filenames — which is all this used to do
//! — cannot tell them apart, because a combined-seasons pack contains several
//! files that legitimately answer to "episode 1". Picking the largest of them
//! is what played season 2's premiere for a season 1 request.
//!
//! So the pack is read as a structure rather than a bag of names: each file
//! carries what its own path states (season, episode, special index, whether
//! it sits among the extras, whether any part of its path names *this* entry),
//! and the episode is looked for inside the narrowest subset of files that the
//! evidence supports. When no narrowing is convincing and the pack spans more
//! than one season, this refuses to answer rather than guess — the caller then
//! moves on to the next candidate, which costs a few seconds, where guessing
//! costs the viewer the wrong episode.

use super::search::{self, normalize};

/// What kind of AniList entry the request is for. Decides where inside a pack
/// the episode is expected to live: a TV entry's episodes sit in the main
/// numbered run, while an OVA or specials entry's sit among the extras.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum EntryKind {
    #[default]
    Tv,
    /// OVA, ONA-as-extra, specials collections — anything a release group
    /// files under `Extras/`, `Specials/`, `SPxx` or `S00`.
    Extra,
    Movie,
}

/// What is known about where this AniList entry sits in its franchise.
/// Everything here is optional on purpose: an unknown season must never be
/// silently treated as season 1 (see `search::stated_season`).
#[derive(Debug, Clone, Copy, Default)]
pub struct EntryHint {
    pub kind: EntryKind,
    /// The season number this entry is, when it can be established.
    pub season: Option<u32>,
    /// A lower bound when the exact number can't be: an entry with a TV
    /// prequel is season 2 at the earliest, which is enough to rule out a
    /// pack's season-1 files even when nothing says which season it is.
    pub season_at_least: Option<u32>,
}

/// Everything `select` needs about the request, as opposed to about the files.
pub struct SelectRequest<'a> {
    /// This entry's titles (AniList romaji/english/synonyms, or the user's
    /// override), raw. Used to recognise a folder or filename that names this
    /// entry specifically.
    pub titles: &'a [String],
    /// The same titles normalized, as `search` uses them, so an alias inside a
    /// path is told apart from a title continuation.
    pub alts: &'a [String],
    pub hint: EntryHint,
    /// The episode as this AniList entry numbers it.
    pub episode: i64,
    /// How many episodes this entry has, when known.
    pub episode_count: Option<i64>,
    /// The release name, for the combined-seasons check.
    pub release_name: &'a str,
    /// The release name carries no episode number and legitimately shouldn't
    /// (a film, an OVA). Lets a lone unnumbered file answer episode 1.
    pub allow_episodeless: bool,
}

/// How a filename marks itself as not-a-regular-episode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SpecialMark {
    /// "SP01", "Special 3" — the numbered specials a BD ships alongside the
    /// episodes, which is what an AniList "Specials" entry lists.
    Sp,
    /// "OVA", "OVA2", "OAD" — a self-contained bonus episode.
    Ova,
    /// Creditless openings/endings, menus, PVs, trailers. Never playable
    /// content for any AniList entry, so these are only ever excluded.
    Creditless,
}

/// What one file inside a torrent states about itself.
#[derive(Debug, Clone)]
pub struct FileFacts {
    pub index: usize,
    pub season: Option<u32>,
    pub episode: Option<i64>,
    pub special: Option<(SpecialMark, i64)>,
    /// The file sits in an extras/specials folder, or names itself creditless.
    pub is_extra: bool,
    /// Some component of this file's path names the requested entry.
    pub title_match: bool,
    pub len: u64,
}

/// Folder names release groups use for material that isn't a numbered episode.
const EXTRA_DIRS: &[&str] = &[
    "extra", "extras", "special", "specials", "sp", "bonus", "nc", "ncop", "nced",
    "creditless", "menu", "menus", "scans", "ova", "ovas", "oad", "oads", "pv", "cm",
];

/// Does this path component name an extras folder?
fn is_extra_dir(component: &str) -> bool {
    let norm = normalize(component);
    let tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
    if tokens.is_empty() {
        return false;
    }
    // "OVA 1", "Special 2" — a bare number may trail the folder word.
    tokens
        .iter()
        .all(|t| EXTRA_DIRS.contains(t) || t.chars().all(|c| c.is_ascii_digit()))
        && tokens.iter().any(|t| EXTRA_DIRS.contains(t))
}

/// The special designation a filename carries, if any.
///
/// Read from the basename only. A folder called `Extras/` says the file is an
/// extra (which `is_extra` records) but not *which* one, and reading the
/// number out of a folder name is how "OVA 1/" turned every file under it into
/// special number one.
fn special_of(basename: &str) -> Option<(SpecialMark, i64)> {
    let norm = normalize(basename);
    let padded = format!(" {} ", norm);
    for marker in ["ncop", "nced", "nc op", "nc ed", "creditless", "clean opening", "clean ending", "menu", "trailer", "promo", "preview"] {
        if padded.contains(&format!(" {marker} ")) || norm.starts_with(&format!("{marker} ")) {
            return Some((SpecialMark::Creditless, 0));
        }
    }
    // "NCOP01"/"NCED02" glue the number on, so the whole-token check above
    // can't see them.
    if norm.split(' ').any(|t| {
        (t.starts_with("ncop") || t.starts_with("nced")) && t[4..].chars().all(|c| c.is_ascii_digit())
    }) {
        return Some((SpecialMark::Creditless, 0));
    }
    let numbered = |prefixes: &[&str]| -> Option<i64> {
        let tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
        for (i, t) in tokens.iter().enumerate() {
            for p in prefixes {
                if let Some(rest) = t.strip_prefix(p) {
                    // "SP01" — number glued to the marker.
                    if !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit()) {
                        return rest.parse().ok();
                    }
                    // "SP 01", "Special 3" — number in the next token. A bare
                    // marker ("OVA") means the only one there is.
                    if rest.is_empty() {
                        return match tokens.get(i + 1) {
                            Some(n) if n.chars().all(|c| c.is_ascii_digit()) && n.len() <= 2 => {
                                n.parse().ok()
                            }
                            _ => Some(1),
                        };
                    }
                }
            }
        }
        None
    };
    if let Some(n) = numbered(&["sp", "special", "specials"]) {
        return Some((SpecialMark::Sp, n));
    }
    if let Some(n) = numbered(&["ova", "oad", "ovas", "oads"]) {
        return Some((SpecialMark::Ova, n));
    }
    None
}

/// The episode number a file states, read from its basename first.
///
/// The full path is only consulted as a fallback because a folder named after
/// the release ("... S01+OVA 1080p Dual Audio ...") is full of numbers that
/// aren't episodes, and the basename is where the answer actually is.
fn episode_of(path: &str, basename: &str) -> Option<i64> {
    if let Some(e) = search::filename_episode(basename) {
        return Some(e);
    }
    // "Season 2/01.mkv" — a basename that is nothing but the number.
    let stem = basename.rsplit_once('.').map(|(s, _)| s).unwrap_or(basename);
    let stem = stem.trim();
    if !stem.is_empty() && stem.chars().all(|c| c.is_ascii_digit()) && stem.len() <= 4 {
        return stem.parse().ok();
    }
    search::filename_episode(path)
}

/// Read what every file states about itself.
pub fn facts(files: &[(usize, String, u64)], req: &SelectRequest) -> Vec<FileFacts> {
    // A folder is often named with the season's own title rather than a
    // number ("Shinmai Maou no Testament Burst/"), which is the only thing
    // telling that season's files apart from season 1's in the same pack. The
    // short forms are included for the same reason `find_candidates` searches
    // them: AniList carries the full official title while release groups write
    // the short one.
    let queries: Vec<String> = req
        .titles
        .iter()
        .flat_map(|t| {
            let short = search::short_title(t);
            std::iter::once(t.clone()).chain(short)
        })
        .map(|t| {
            let norm = normalize(&t);
            // For an OVA or specials entry, the kind marker is part of the
            // AniList title ("... Burst Specials") and never part of the
            // folder that holds it ("... Burst/Extras/"). Drop it so the two
            // still recognise each other.
            if req.hint.kind == EntryKind::Extra {
                search::strip_extras_marker(&norm)
            } else {
                norm
            }
        })
        .filter(|t| !t.is_empty())
        .collect();

    files
        .iter()
        .map(|(index, path, len)| {
            let basename = path.rsplit('/').next().unwrap_or(path);
            let components: Vec<&str> = path.split('/').collect();
            let dirs = &components[..components.len().saturating_sub(1)];
            let special = special_of(basename);
            let is_extra = dirs.iter().any(|d| is_extra_dir(d))
                || matches!(special, Some((SpecialMark::Creditless, _)));
            FileFacts {
                index: *index,
                // The whole path, so a `Season 2/` folder counts for a file
                // whose own name states nothing, and an `SxxEyy` filename
                // still wins over a folder that merely mentions a season.
                season: search::filename_season(path).or(if dirs.iter().any(|d| is_extra_dir(d)) {
                    // An extras folder is season 0 by every group's
                    // convention, stated or not.
                    Some(0)
                } else {
                    None
                }),
                episode: episode_of(path, basename),
                special,
                is_extra,
                title_match: components
                    .iter()
                    .any(|c| queries.iter().any(|q| search::title_matches_with_alts(q, c, req.alts))),
                len: *len,
            }
        })
        .collect()
}

/// Which kind of extra this entry *is*, when its own titles say.
///
/// AniList names an extras entry after the kind it belongs to ("... Specials",
/// "... OVA"), and a pack files each kind in its own numbered run. Reading the
/// entry's kind is what keeps a six-file `Special 1..6` run from answering a
/// one-episode OVA entry, in a pack where the OVA is not marked as one at all
/// (it is episode 13 of season 1) and so cannot outbid it.
fn entry_mark(titles: &[String]) -> Option<SpecialMark> {
    const SP: &[&str] = &["special", "specials", "sp"];
    const OVA: &[&str] = &["ova", "ovas", "oad", "oads"];
    for title in titles {
        let norm = normalize(title);
        let tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
        if tokens.iter().any(|t| SP.contains(t)) {
            return Some(SpecialMark::Sp);
        }
        if tokens.iter().any(|t| OVA.contains(t)) {
            return Some(SpecialMark::Ova);
        }
    }
    None
}

/// Why no file could be named.
#[derive(Debug, PartialEq, Eq)]
pub enum SelectError {
    /// The wanted episode isn't in this torrent.
    NotFound,
    /// The torrent holds several seasons and nothing in the request or the
    /// paths says which one is wanted. Refusing is deliberate: the caller
    /// falls through to another candidate rather than play a coin flip.
    Ambiguous,
}

impl std::fmt::Display for SelectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SelectError::NotFound => write!(f, "episode not found inside torrent"),
            SelectError::Ambiguous => write!(
                f,
                "torrent spans several seasons and none could be matched to this entry"
            ),
        }
    }
}

/// Pick the file holding the requested episode, or say why none does.
///
/// `files` is `(file index, path relative to the torrent root, length)` for
/// the video files only.
pub fn select(files: &[(usize, String, u64)], req: &SelectRequest) -> Result<usize, SelectError> {
    let all = facts(files, req);
    if all.is_empty() {
        return Err(SelectError::NotFound);
    }

    // Creditless openings, menus and trailers are never the episode anyone
    // asked for, whatever kind of entry this is.
    let pool: Vec<&FileFacts> = all
        .iter()
        .filter(|f| !matches!(f.special, Some((SpecialMark::Creditless, _))))
        .collect();
    let pool = if pool.is_empty() { all.iter().collect() } else { pool };

    // A TV entry's episodes are never in the extras folder; an OVA/specials
    // entry's usually are. Narrowing here rather than later keeps a pack's
    // `Extras/SP01` from competing with its `- 01` for a TV episode 1.
    let pool: Vec<&FileFacts> = match req.hint.kind {
        EntryKind::Tv => {
            let main: Vec<&FileFacts> = pool.iter().copied().filter(|f| !f.is_extra).collect();
            if main.is_empty() { pool } else { main }
        }
        EntryKind::Extra | EntryKind::Movie => pool,
    };

    let subset = narrow(&pool, req)?;
    pick_within(&subset, req).ok_or(SelectError::NotFound)
}

/// How many distinct seasons the files in a set actually state.
fn stated_seasons(files: &[&FileFacts]) -> Vec<u32> {
    let mut seasons: Vec<u32> = files.iter().filter_map(|f| f.season).collect();
    seasons.sort_unstable();
    seasons.dedup();
    seasons
}

/// Cut the pool down to the files that could belong to this entry.
///
/// The passes are tried in order of how much they actually prove, and the
/// first one that keeps anything wins. Title evidence comes first because it
/// is the only signal that survives a pack which numbers nothing — a flat
/// batch whose two seasons are told apart solely by the title inside each
/// filename ("Show - 01" against "Show Burst - 01").
fn narrow<'a>(pool: &[&'a FileFacts], req: &SelectRequest) -> Result<Vec<&'a FileFacts>, SelectError> {
    let season_agrees = |f: &FileFacts| match (req.hint.season, f.season) {
        (Some(want), Some(stated)) => want == stated,
        _ => true,
    };

    // 1. The path names this entry, and states nothing that contradicts it.
    let by_title: Vec<&FileFacts> = pool
        .iter()
        .copied()
        .filter(|f| f.title_match && season_agrees(f))
        .collect();
    if !by_title.is_empty() {
        return Ok(by_title);
    }

    // 2. The path states exactly the season asked for.
    if let Some(want) = req.hint.season {
        let by_season: Vec<&FileFacts> =
            pool.iter().copied().filter(|f| f.season == Some(want)).collect();
        if !by_season.is_empty() {
            return Ok(by_season);
        }
    }

    // 3. Exactly one season inside the pack has as many episodes as this entry
    //    does. Title-independent, which is what makes it the answer for a
    //    named sequel ("Burst", 10 episodes) inside a pack that numbers its
    //    folders (`Season 1/` 12 files, `Season 2/` 10).
    if let Some(count) = req.episode_count.filter(|c| *c > 1) {
        let seasons = stated_seasons(pool);
        if seasons.len() > 1 {
            let mut matching = seasons.iter().filter(|s| {
                pool.iter().filter(|f| f.season == Some(**s)).count() as i64 == count
            });
            if let (Some(&only), None) = (matching.next(), matching.next()) {
                return Ok(pool.iter().copied().filter(|f| f.season == Some(only)).collect());
            }
        }
    }

    // 4. The entry has a prequel, so anything below that season is not it.
    //    Only conclusive when one season is left standing.
    if let Some(min) = req.hint.season_at_least {
        let above: Vec<&FileFacts> = pool
            .iter()
            .copied()
            .filter(|f| f.season.map(|s| s >= min).unwrap_or(false))
            .collect();
        if stated_seasons(&above).len() == 1 {
            return Ok(above);
        }
    }

    // 5. Nothing to disambiguate: the pack is one season, or states none.
    if stated_seasons(pool).len() <= 1 {
        return Ok(pool.to_vec());
    }

    Err(SelectError::Ambiguous)
}

/// Find the requested episode inside an already-narrowed set of files.
fn pick_within(subset: &[&FileFacts], req: &SelectRequest) -> Option<usize> {
    if req.hint.kind == EntryKind::Extra {
        // Specials are numbered in their own sequence, and a pack that has
        // both ("SP01".."SP06" plus a single "OVA") lists them as separate
        // runs. Try the numbered specials first, then the OVAs, so an OVA
        // file's implicit index 1 can't outrank a real "SP01" — unless one of
        // the runs is exactly as long as this entry, which says outright which
        // run the entry *is*. The same folder answers both the six-episode
        // "Specials" entry and the one-episode OVA entry, and the run length
        // is what tells those two requests apart.
        let own_mark = entry_mark(req.titles);
        let mut tiers: Vec<(SpecialMark, Vec<&FileFacts>)> = [SpecialMark::Sp, SpecialMark::Ova]
            .into_iter()
            .map(|mark| {
                let tier: Vec<&FileFacts> = subset
                    .iter()
                    .copied()
                    .filter(|f| matches!(f.special, Some((m, _)) if m == mark))
                    .collect();
                (mark, tier)
            })
            .collect();
        if let Some(count) = req.episode_count {
            tiers.sort_by_key(|(_, tier)| {
                std::cmp::Reverse(!tier.is_empty() && tier.len() as i64 == count)
            });
        }
        for (mark, tier) in tiers {
            if tier.is_empty() {
                continue;
            }
            // A run of a different length than this entry is only this
            // entry's run if the entry says it is that kind of thing. Six
            // numbered specials are not the one-episode OVA entry's run even
            // when they are the only numbered run in the pack, and a lone OVA
            // is not the six-episode specials entry's.
            if req
                .episode_count
                .is_some_and(|c| tier.len() as i64 != c && own_mark != Some(mark))
            {
                continue;
            }
            if let Some(f) = tier
                .iter()
                .filter(|f| matches!(f.special, Some((_, n)) if n == req.episode))
                .max_by_key(|f| f.len)
            {
                return Some(f.index);
            }
            // A lone OVA answers "episode 1" however it numbers itself.
            if tier.len() == 1 && req.episode == 1 {
                return Some(tier[0].index);
            }
        }
    }

    // For an extras entry, a plain episode number is only its own when every
    // file still in the running is extras material. Otherwise the number
    // belongs to the TV run sitting in the same pack, and answering "special
    // 1" with "episode 1" is exactly the wrong-content mistake this module
    // exists to stop — the caller is better served by the next candidate.
    if req.hint.kind == EntryKind::Extra
        && !subset.iter().all(|f| f.is_extra || f.special.is_some())
    {
        return None;
    }

    // A release that numbers a split cour absolutely (files 12-23 for an
    // AniList entry of 1-12) needs its offset applied — but only within one
    // season. Across a combined-seasons pack the same reasoning is unsound: a
    // run starting above 1 is as likely to be the other season as a
    // continuation of this one.
    let numbered: Vec<i64> = subset.iter().filter_map(|f| f.episode).collect();
    let spans_seasons =
        stated_seasons(subset).len() > 1 || search::multi_season_batch(&normalize(req.release_name));
    let wanted = if spans_seasons {
        req.episode
    } else {
        match search::absolute_episode(&numbered, req.episode, req.episode_count) {
            Some(absolute) => {
                log::info!(
                    "torrent: '{}' numbers episodes absolutely; episode {} is file {}",
                    req.release_name,
                    req.episode,
                    absolute
                );
                absolute
            }
            None => req.episode,
        }
    };

    if let Some(f) = subset
        .iter()
        .filter(|f| f.episode == Some(wanted))
        .max_by_key(|f| f.len)
    {
        return Some(f.index);
    }

    // Nothing states an episode number and nothing was supposed to — a film or
    // a single-episode OVA, whose release names carry no number by convention.
    if req.allow_episodeless && req.episode == 1 && numbered.is_empty() {
        return subset.iter().max_by_key(|f| f.len).map(|f| f.index);
    }
    None
}

#[cfg(test)]
mod tests;
