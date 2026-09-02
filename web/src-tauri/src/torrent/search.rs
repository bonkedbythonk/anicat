//! Torrent candidate search: SubsPlease's JSON API first (curated, always
//! 1080p softsub simulcasts), then Nyaa's RSS feed (English-translated
//! category) for everything SubsPlease doesn't cover — batches, older shows,
//! dual-audio releases.

use serde_json::Value;

#[derive(Debug, Clone)]
pub struct Candidate {
    pub name: String,
    /// Magnet link (SubsPlease API) — used when `torrent_url` is absent.
    pub magnet: Option<String>,
    /// Direct .torrent download URL (Nyaa) — preferred: metadata is instant,
    /// no DHT round-trip.
    pub torrent_url: Option<String>,
    pub seeders: u64,
    pub score: i64,
    /// The release name carries no episode number or range at all, and it was
    /// accepted on the assumption that it is a complete-series batch — which is
    /// how most back-catalog BD releases are named ("[Sokudo] Toradora!
    /// [1080p BD AV1][dual audio]" covers all 25 episodes and says so nowhere).
    ///
    /// The assumption is verified later rather than trusted: `try_candidate`
    /// requires a file inside the torrent whose *filename* carries the wanted
    /// episode before it will play one of these, so an untagged single-episode
    /// release can't be mistaken for a batch and played as the wrong episode.
    pub assume_batch: bool,
}

/// Standard open trackers appended to infohash-only magnets so peers are
/// found even before DHT bootstraps.
pub(crate) const TRACKERS: &[&str] = &[
    "http://nyaa.tracker.wf:7777/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.torrent.eu.org:451/announce",
];

/// A title as it should be typed into Nyaa's search box: punctuation dropped,
/// words and separators kept.
///
/// Unlike `normalize`, this preserves case and internal hyphens — the query is
/// read by Nyaa's search engine, not by our matcher, and the hyphen carries
/// meaning in the "Title - 05" episode convention.
fn search_query_form(title: &str) -> String {
    title
        .chars()
        .map(|c| if c.is_alphanumeric() || c == '-' { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// The part of a title before its subtitle, when there is one.
///
/// AniList carries the full official title — "Rich Girl Caretaker: I'm Secretly
/// the Caregiver of the Most Popular Girl in This Rich Kid School", 95
/// characters — while release groups name the file after the short form.
/// Nyaa's search ANDs its terms, so querying the full title returns literally
/// nothing: 0 results against 34 for "Rich Girl Caretaker". Splitting on the
/// colon is conservative on purpose; it is where AniList puts the boundary, and
/// it leaves titles that merely contain punctuation ("Fate/stay night") alone.
///
/// `None` when there is no subtitle, when the short form would be a single
/// token (too weak a query to be worth a round-trip), or when the subtitle is
/// short enough to be a sequel or arc identifier rather than a descriptive
/// tail. That last one is the load-bearing condition: a colon separates two
/// very different things, and dropping the wrong one hands back the wrong
/// season.
///
///   "Kaguya-sama wa Kokurasetai: Ultra Romantic"  -> season 3, kept by groups
///   "Kimetsu no Yaiba: Yuukaku-hen"               -> an arc, kept by groups
///   "Sword Art Online: Alicization"               -> a cour, kept by groups
///
/// Truncating those produces a query that matches the *first* season, which
/// has an episode 6 as well, so nothing downstream catches it -- measured live,
/// `Kaguya-sama wa Kokurasetai - 06` (season 1) outranked the Ultra Romantic
/// release the query was actually for. Every one of those identifiers is one to
/// three words, while the descriptive light-novel tails groups do drop run to a
/// dozen and up, so the length of the subtitle separates them cleanly.
const MIN_DROPPABLE_SUBTITLE_WORDS: usize = 6;

pub(crate) fn short_title(title: &str) -> Option<String> {
    let (head, subtitle) = title.split_once(':')?;
    let head = head.trim();
    if head.split_whitespace().count() < 2 {
        return None;
    }
    if subtitle.split_whitespace().count() < MIN_DROPPABLE_SUBTITLE_WORDS {
        return None;
    }
    Some(head.to_string())
}

/// Whether a (normalized) release name actually carries an English dub
/// track, judged from the name itself rather than from what the caller
/// asked for. Used both to score `prefer_dub` matches and to label
/// candidates so a sub-only release never gets tagged "dub" just because
/// dub was the requested preference.
pub fn is_dub_release(name_norm: &str) -> bool {
    name_norm.contains("dual audio")
        || name_norm.contains("english dub")
        || name_norm.contains(" eng dub")
        || name_norm.contains(" dub ")
        || name_norm.ends_with(" dub")
        || name_norm.contains("dubbed")
}

/// How far a dub outranks the same show's subs when a dub was asked for.
const DUB_BONUS: i64 = 350;
/// How far every non-dub release sinks when a dub was asked for *and one
/// exists* -- see `find_candidates`, which refunds this when none does.
const NON_DUB_PENALTY: i64 = 500;
/// How far an English-audio-only release sinks when subs were asked for.
/// Larger than the pair above because this one is not a preference between
/// two ways of watching: the wrong one is unwatchable for the viewer who
/// picked subs, so it should surface only when nothing else matched at all.
const DUB_ONLY_PENALTY: i64 = 1000;

/// A release carrying an English audio track and *nothing else* -- dual-audio
/// and multi-audio releases are excluded, since they still contain the
/// Japanese track a sub viewer wants.
pub fn is_dub_only_release(name_norm: &str) -> bool {
    (name_norm.contains("english dub")
        || name_norm.contains(" eng dub")
        || name_norm.contains(" dub ")
        || name_norm.ends_with(" dub")
        || name_norm.contains("dubbed"))
        && !name_norm.contains("dual audio")
        && !name_norm.contains("multi audio")
        && !name_norm.contains("multiple subtitle")
}

pub fn normalize(s: &str) -> String {
    s.to_lowercase()
        .chars()
        .map(|c| if c.is_alphanumeric() { c } else { ' ' })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Season-naming variants so "2nd Season" (AniList) still matches "S2"
/// (SubsPlease/most release groups) and vice versa.
fn title_variants(title: &str) -> Vec<String> {
    let mut out = vec![title.to_string()];
    let lower = title.to_lowercase();
    for n in 1..=9u32 {
        for pat in [
            format!("{}nd season", n),
            format!("{}rd season", n),
            format!("{}th season", n),
            format!("{}st season", n),
            format!("season {}", n),
        ] {
            if let Some(pos) = lower.find(&pat) {
                let mut v = title.to_string();
                v.replace_range(pos..pos + pat.len(), &format!("S{}", n));
                out.push(v);
            }
        }
    }
    out
}

/// Split a release name into the chunks release groups actually separate with
/// punctuation: `[group]`, `(notes)`, `alt | title`, `Title - 05`, `A + B`.
///
/// Matching has to happen per-chunk. A release name is not one string of words
/// — it is a title next to a group tag, an episode number, a resolution, and
/// often a second title in another language. Flattening all of that into one
/// token bag (which is what `normalize` alone does) is why a query for
/// "Monster" matched "Re Monster", "Pocket Monsters", "S-Rank Monster no
/// Behemoth" and "Monogatari Series - Off & Monster Season": the word is
/// present in each, just not as the show's name.
fn segments(name: &str, alts: &[String]) -> Vec<String> {
    let mut out = Vec::new();
    for part in name.split(['[', ']', '(', ')', '|', '+', '~']) {
        let chunks: Vec<String> = part.split(" - ").map(normalize).filter(|s| !s.is_empty()).collect();
        // " - " separates a title from its episode number, but release groups
        // also use it *inside* a title: "Sword Art Online - Alicization - War
        // of Underworld - 06". Splitting blindly on it produced both halves of
        // one bug. The correct release for a query was missed, because the
        // title it was looking for ("Sword Art Online Alicization") existed
        // only as two adjacent chunks and never as a segment. And a *longer*
        // titled entry was accepted, because "Sword Art Online Alicization" was
        // a whole segment of the War of Underworld release — a different
        // AniList entry, a different cour, with an episode 6 of its own. Same
        // shape for "Kimetsu no Yaiba", which matched both the Yuukaku-hen and
        // the Hashira Geiko-hen arcs.
        //
        // So rejoin the leading chunks that are title material into the one
        // segment the title actually is, and keep the rest as they were. The
        // query then has to account for the whole title, not a prefix of it
        // that happens to land on a dash.
        //
        // Except when the chunk is one of *this media's own* other titles.
        // "[35mm] Koe no Katachi - A Silent Voice" uses the same separator for
        // an alias rather than a continuation, and no property of the text
        // tells the two apart — "A Silent Voice" and "War of Underworld" are
        // both plain title-shaped phrases after a dash. What tells them apart
        // is AniList: the first is this entry's English title, the second
        // belongs to a different entry. So the alias stays its own segment and
        // keeps matching, while an unrecognised continuation is joined.
        let title_len = chunks
            .iter()
            .enumerate()
            .take_while(|(i, c)| is_title_material(c) && (*i == 0 || !alts.iter().any(|a| a == *c)))
            .count();
        if title_len > 1 {
            out.push(chunks[..title_len].join(" "));
            out.extend(chunks[title_len..].iter().cloned());
        } else {
            out.extend(chunks);
        }
    }
    out
}

/// Could this dash-separated chunk be part of the show's name, rather than the
/// episode number, season or format tags that follow it?
///
/// Resolution and codec tags live inside brackets in every naming convention in
/// circulation, so by the time a chunk reaches here the realistic alternatives
/// to "more title" are an episode number, a season, or nothing but noise words.
fn is_title_material(chunk: &str) -> bool {
    let tokens: Vec<&str> = chunk.split(' ').filter(|t| !t.is_empty()).collect();
    if tokens.is_empty() {
        return false;
    }
    if is_pure_season_segment(chunk) {
        return false;
    }
    let first = tokens[0];
    if is_episode_marker(first) || first.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    // Resolution reaches here on the rare unbracketed name.
    if first.len() >= 4 && first.ends_with('p') && first[..first.len() - 1].chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    tokens.iter().any(|t| !is_ignorable_suffix_token(t))
}

/// Tokens that may trail a title without changing which show it is: season and
/// part markers, extras, format and source tags.
///
/// Being generous here is safe. The prefix requirement in `segment_matches` is
/// what rejects an unrelated show, and it does so on the *leading* tokens — a
/// wrong show never fails only on its suffix.
fn is_ignorable_suffix_token(t: &str) -> bool {
    const WORDS: &[&str] = &[
        "s", "season", "seasons", "cour", "part", "pt", "final",
        "ova", "ovas", "oad", "oads", "ona", "onas", "sp", "special", "specials",
        "extra", "extras", "movie", "movies", "film", "gekijouban", "the",
        "short", "shorts", "complete", "series", "collection", "batch", "tv", "bd", "bdrip", "bluray",
        "remastered", "uncensored", "dual", "audio", "multi", "subs", "subbed", "dubbed",
        // Container, codec and source tags. Present for the same reason the
        // format words above are: they trail a title in filenames written
        // without brackets ("Show - OAD_BD720p_10bit.mkv"), where `segments`
        // has no punctuation to split on and so hands the whole tail over as
        // part of the title.
        "mkv", "mp4", "avi", "webm", "m4v", "web", "dl", "webrip", "webdl", "hdtv", "dvd", "dvdrip",
        "x264", "x265", "h264", "h265", "hevc", "avc", "av1", "hi10", "hi10p",
        "flac", "aac", "ac3", "eac3", "opus", "ddp", "truehd", "raw", "eng", "engsub",
    ];
    // Bare numbers and "s01"-style markers: part of how a season is written,
    // never part of which show it is.
    if t.chars().all(|c| c.is_ascii_digit())
        || (t.starts_with('s') && t.len() <= 3 && t[1..].chars().all(|c| c.is_ascii_digit()))
        || WORDS.contains(&t)
    {
        return true;
    }
    // A resolution, with or without a source glued to the front of it:
    // "1080p", "bd720p". Bracketed in most naming conventions, bare in the
    // underscore-separated ones.
    let resolution = |t: &str| {
        t.len() >= 4
            && t.ends_with('p')
            && t[..t.len() - 1].chars().all(|c| c.is_ascii_digit())
    };
    if resolution(t) {
        return true;
    }
    for prefix in ["bd", "hd", "sd"] {
        if let Some(rest) = t.strip_prefix(prefix) {
            if resolution(rest) {
                return true;
            }
        }
    }
    // Bit depth: "10bit", "8bit".
    if let Some(depth) = t.strip_suffix("bit") {
        if !depth.is_empty() && depth.chars().all(|c| c.is_ascii_digit()) {
            return true;
        }
    }
    false
}

/// Does one segment name the queried show? The query must be the segment's
/// complete leading token run, and whatever follows must be season/format
/// noise.
///
/// Anchoring at the start is the whole point: "Re Monster" and "Pocket
/// Monsters" contain "monster" but do not *begin* with it, while every genuine
/// match in the wild does — including the ones that put an alternate title
/// first, since that alternate lands in its own segment.
fn segment_matches(query_norm: &str, segment_norm: &str) -> bool {
    // Compare the titles with their season markers removed, and let
    // `season_of` reconcile the seasons separately. The two sides spell the
    // same season differently — AniList's "Mob Psycho 100 II" against a
    // release's "Mob Psycho 100 S2" — so leaving the marker in the tokens
    // being prefix-compared makes those two look like different shows.
    let query_base = strip_season_marker(query_norm);
    let segment_base = strip_season_marker(segment_norm);
    let q: Vec<&str> = query_base.split(' ').filter(|t| !t.is_empty()).collect();
    let mut s: Vec<&str> = segment_base.split(' ').filter(|t| !t.is_empty()).collect();
    // A title never resumes after its episode number, so everything from the
    // first episode marker on is release metadata by definition.
    //
    // This is what makes the `Title S01E06 1080p CR WEB-DL AAC2.0 H.264` naming
    // convention matchable at all. Groups using it write no separator between
    // the title and the tags, so the whole thing arrives as one segment and the
    // suffix rule below sees "s01e06", "cr", "web", "dl" — none of them
    // ignorable, so the release was rejected outright. The " - " convention was
    // unaffected because `segments` had already split the tags off, which is
    // why this only ever failed for some shows.
    //
    // It cannot loosen the prefix guard: a wrong show fails on the title tokens
    // sitting *before* the episode marker ("Monster" against "Monster Hunter
    // S01E06" still rejects on "hunter").
    if let Some(cut) = s.iter().position(|t| is_episode_marker(t)) {
        if cut < q.len() {
            return false;
        }
        s.truncate(cut);
    }
    if q.is_empty() || s.len() < q.len() || s[..q.len()] != q[..] {
        return false;
    }
    let rest = &s[q.len()..];
    // A run of two or more numbers is an episode range ("Toradora 01 25") and
    // says nothing about which show this is. A *lone* trailing number is part
    // of the title — "Steins;Gate 0" is a different series from "Steins;Gate",
    // and treating every bare number as noise let the sequel outrank the show
    // that was actually asked for.
    let digits = |t: &str| !t.is_empty() && t.chars().all(|c| c.is_ascii_digit());
    let digit_tokens = rest.iter().filter(|t| digits(t)).count();
    rest.iter().all(|t| {
        if digits(t) {
            digit_tokens >= 2
        } else {
            is_ignorable_suffix_token(t)
        }
    })
}

/// Is this token an episode number in one of the glued forms — "s01e06",
/// "e06", "ep06"? A bare number is deliberately excluded: it is ambiguous with
/// a title's own number ("Steins;Gate 0") and `segment_matches` already has a
/// rule for those.
fn is_episode_marker(t: &str) -> bool {
    let digits_after = |rest: &str| !rest.is_empty() && rest.chars().all(|c| c.is_ascii_digit());
    if let Some(rest) = t.strip_prefix("ep") {
        if digits_after(rest) {
            return true;
        }
    }
    if let Some(rest) = t.strip_prefix('e') {
        if digits_after(rest) {
            return true;
        }
    }
    season_episode(t).is_some()
}

/// The (season, episode) pair in an "s01e06" token, if that is what this is.
fn season_episode(t: &str) -> Option<(u32, u32)> {
    let rest = t.strip_prefix('s')?;
    let (season, episode) = rest.split_once('e')?;
    if season.is_empty() || episode.is_empty() {
        return None;
    }
    if !season.chars().all(|c| c.is_ascii_digit()) || !episode.chars().all(|c| c.is_ascii_digit()) {
        return None;
    }
    Some((season.parse().ok()?, episode.parse().ok()?))
}

/// Is this token a season marker in any of the forms in circulation?
fn is_season_marker(t: &str) -> bool {
    if t == "season" || t == "seasons" || roman_numeral(t).is_some() {
        return true;
    }
    // "s2"/"s02", and Code Geass-style "r2".
    if (t.starts_with('s') || t.starts_with('r'))
        && t.len() <= 3
        && t.len() > 1
        && t[1..].chars().all(|c| c.is_ascii_digit())
    {
        return true;
    }
    // "2nd", "3rd" — normalize keeps the ordinal as one token.
    let digits: String = t.chars().take_while(|c| c.is_ascii_digit()).collect();
    if !digits.is_empty() && digits.len() <= 2 {
        let rest = &t[digits.len()..];
        if matches!(rest, "st" | "nd" | "rd" | "th") {
            return true;
        }
        // A bare trailing number, as in "Ashita no Joe 2". Season 1 and 0 are
        // not markers — absent already means season 1.
        if rest.is_empty() {
            return digits.parse::<u32>().is_ok_and(|n| n >= 2);
        }
    }
    false
}

/// The title with any trailing season marker removed, so two spellings of the
/// same season compare equal.
fn strip_season_marker(norm: &str) -> String {
    let mut tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
    // Never strip down to nothing: a show really can be named "86".
    while tokens.len() > 1 && is_season_marker(tokens[tokens.len() - 1]) {
        // A bare trailing number preceded by another bare number is an episode
        // range or list ("Chunibyo Lite 1 6", from "1-6"), not a season marker
        // — a real trailing season number stands alone. Popping it left a lone
        // "1" behind, which the caller's "a lone trailing number is part of the
        // title" rule then rejects, so an alias segment naming an OVA/shorts
        // entry by its relative episode range never matched its own title.
        let last = tokens[tokens.len() - 1];
        let prev_is_digit = last.chars().all(|c| c.is_ascii_digit())
            && tokens[tokens.len() - 2].chars().all(|c| c.is_ascii_digit());
        if prev_is_digit {
            break;
        }
        tokens.pop();
    }
    tokens.join(" ")
}

/// Does this release name the queried show, in the queried season?
///
/// The *first* segment naming the show decides the season, rather than any
/// segment that happens to agree. Release groups put the primary title first
/// and alternates after, so the first match is the one that describes this
/// release — checking "does any segment agree" let "[MTBB] K-ON! S2 (BD 1080p)
/// | K-ON!!" answer a season-1 query, because its alternate title normalizes
/// to the season-1 name once punctuation is stripped. That is a wrong-content
/// bug the episode-file check cannot catch: season 2 has an episode 5 too.
#[cfg(test)]
fn title_matches(query_norm: &str, name: &str) -> bool {
    title_matches_with_alts(query_norm, name, &[])
}

/// As `title_matches`, told which other titles belong to the same AniList
/// entry (normalized) so `segments` can recognise an alias.
pub(crate) fn title_matches_with_alts(query_norm: &str, name: &str, alts: &[String]) -> bool {
    let query_season = season_of(query_norm);
    let segs = segments(name, alts);
    let Some(matched) = segs.iter().find(|seg| segment_matches(query_norm, seg)) else {
        return false;
    };

    // Season comes from the matched segment when it states one. When it
    // doesn't, a segment that is *nothing but* a season marker may supply it —
    // "[derp] Mob Psycho 100 - Season 2 (S02) (BD 1080p)" puts the title and
    // the season in different segments, and reading only the matched one
    // called that release season 1.
    //
    // Only a segment carrying an explicit "season"/"S02" word counts. A bare
    // number is an episode ("[G] Show - 25 [1080p]"), and letting that stand in
    // as a season would reject every episode past the first.
    let season = explicit_season(matched)
        .or_else(|| segs.iter().filter(|s| is_pure_season_segment(s)).find_map(|s| explicit_season(s)))
        .unwrap_or(1);
    season == query_season
}

/// The season this text actually states, or `None` when it states none.
///
/// Distinct from `season_of`, which answers 1 for "no marker" — a default that
/// is right for comparing two titles but hides whether anything was said.
pub(crate) fn explicit_season(norm: &str) -> Option<u32> {
    // "s02e06" states its season as plainly as "S2" does, but no word boundary
    // follows the number so none of the patterns below can see it. Reading it
    // is not optional: `segment_matches` now matches this naming, and without
    // this a season-2 release would default to season 1 and satisfy a season-1
    // query — the wrong-content bug the whole season check exists to stop.
    if let Some((season, _)) = norm.split(' ').find_map(season_episode) {
        return Some(season);
    }
    let stated = season_of(norm);
    if stated != 1 {
        return Some(stated);
    }
    // Season 1 stated outright, rather than merely unmarked.
    let re = regex_lite::Regex::new(r"\bs0*1\b|\bseason 0*1\b|\b1st season\b").unwrap();
    re.is_match(norm).then_some(1)
}

/// Words that name a *kind* of release rather than a particular one. Shared
/// by the extras-marker stripping and the sibling check: "OVA" tells you what
/// something is, never which one it is, and a franchise's entries are told
/// apart by the words that are left.
const KIND_WORDS: &[&str] = &[
    "special", "specials", "ova", "ovas", "oad", "oads", "ona", "sp", "extra", "extras",
    "movie", "movies", "film", "season", "seasons", "part",
];

/// Does this release name a *different* entry of the same franchise?
///
/// A franchise's extras all share a title. "Shinmai Maou no Testament
/// Departures" contains "Shinmai Maou no Testament" outright, so a release of
/// Departures matches the OVA entry's title exactly as well as the OVA's own
/// release does — and both are single-file, one-episode releases, so nothing
/// downstream can tell them apart either. Every signal that separates them is
/// in the words the two entries *don't* share.
///
/// So: a release is disowned when it spells out everything that makes a
/// sibling that sibling, and nothing of what makes this entry itself. Kind
/// words are excluded from both sides — "OVA" is what an entry is, never
/// which one — and a sibling whose title adds nothing to this one's (a
/// parent series, say) can't disown anything.
///
/// Best-effort, and silent when it cannot help: AniList's `relations` are one
/// hop, so a franchise's OVAs are often not related to *each other* — the
/// season 1 OVA of this franchise names the two TV seasons and nothing else,
/// which leaves Departures three hops away and invisible here. That is what
/// `names_an_unrelated_extra` covers instead, from the release name alone.
/// Neither is a guarantee; together they cover the shapes seen in the wild.
///
/// `titles` and `siblings` arrive raw; both are normalized here.
pub(crate) fn names_a_sibling(name_norm: &str, titles: &[String], siblings: &[String]) -> bool {
    let content = |t: &str| -> Vec<String> {
        normalize(t)
            .split(' ')
            .filter(|w| !w.is_empty() && !KIND_WORDS.contains(w))
            .map(|w| w.to_string())
            .collect()
    };
    let has = |word: &str| {
        format!(" {} ", name_norm).contains(&format!(" {} ", word))
    };
    let own: Vec<String> = titles.iter().flat_map(|t| content(t)).collect();
    for sibling in siblings {
        let sib = content(sibling);
        let sibling_only: Vec<&String> = sib.iter().filter(|w| !own.contains(w)).collect();
        if sibling_only.is_empty() || !sibling_only.iter().all(|w| has(w)) {
            continue;
        }
        let ours_only: Vec<&String> = own.iter().filter(|w| !sib.contains(w)).collect();
        if !ours_only.iter().any(|w| has(w)) {
            return true;
        }
    }
    false
}

/// Does this release name an extra that isn't this one, judged from the name
/// alone?
///
/// The companion to `names_a_sibling`, for the (common) case where AniList
/// doesn't relate two OVAs of the same franchise closely enough to know they
/// are different things. A release that qualifies its kind — "- OVA
/// Departures", "Burst Specials" — is naming *which* extra it is, and if that
/// qualifier is a word this entry's own titles never use, it is naming a
/// different one.
///
/// Deliberately narrow. Only a short chunk carrying a kind word counts, and
/// only one unknown word in it: a longer chunk is a title or a tag run
/// ("OAD BD720p 10bit SmoodFlamez" is a group signing its work, not a
/// qualifier), and a chunk that is all kind words and numbers is a pack
/// listing its contents ("Complete Series+OVAs+Specials"), which says nothing
/// about which entry it is.
fn names_an_unrelated_extra(name: &str, titles: &[String]) -> bool {
    const MAX_QUALIFIER_TOKENS: usize = 3;
    // Words that join a pack's contents together rather than naming any of it.
    const GLUE: &[&str] = &["with", "and", "plus", "all", "full", "incl", "including", "only"];
    let own: Vec<String> = titles
        .iter()
        .flat_map(|t| normalize(t).split(' ').map(|w| w.to_string()).collect::<Vec<_>>())
        .filter(|w| !w.is_empty())
        .collect();
    for segment in segments(name, &[]) {
        let tokens: Vec<&str> = segment.split(' ').filter(|t| !t.is_empty()).collect();
        if tokens.len() > MAX_QUALIFIER_TOKENS || !tokens.iter().any(|t| KIND_WORDS.contains(t)) {
            continue;
        }
        let unknown: Vec<&&str> = tokens
            .iter()
            .filter(|t| {
                !KIND_WORDS.contains(*t)
                    && !GLUE.contains(*t)
                    && !is_ignorable_suffix_token(t)
                    && !own.iter().any(|w| w == *t)
            })
            .collect();
        if unknown.len() == 1 {
            return true;
        }
    }
    false
}

/// A normalized title with any trailing "Specials"/"OVA"/"OAD" removed.
///
/// AniList names an extras entry by appending the kind to the parent series
/// ("Shinmai Maou no Testament Burst Specials"). Release groups never do —
/// the word appears in a folder name or a release's own description, not as
/// part of the title they match on — so the two spellings can only recognise
/// each other with the marker gone.
pub(crate) fn strip_extras_marker(norm: &str) -> String {
    const MARKERS: &[&str] = &[
        "special", "specials", "ova", "ovas", "oad", "oads", "sp", "extras", "extra",
    ];
    let mut tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
    while tokens.len() > 1 && MARKERS.contains(tokens.last().unwrap()) {
        tokens.pop();
    }
    tokens.join(" ")
}

/// The season number this entry's own titles state, if any of them state one.
///
/// AniList spells a sequel's season in the title or not at all — "Mob Psycho
/// 100 II" says 2, "Shinmai Maou no Testament Burst" says nothing even though
/// it is season 2. Only the first answer is usable as a season number, which
/// is why this returns `Option` and the caller treats `None` as "unknown"
/// rather than as season 1: inside a combined-seasons batch, guessing 1 for a
/// named sequel selects the previous season's files.
pub fn stated_season(titles: &[String]) -> Option<u32> {
    // A title that is itself a number reads as a season number: "86" parses
    // as season 86, and AniList carries plenty of such titles and synonyms.
    // Nothing in circulation has more than a handful of seasons, so a number
    // out of that range is a title, not a season.
    const MAX_PLAUSIBLE_SEASON: u32 = 20;
    titles
        .iter()
        .find_map(|t| explicit_season(&normalize(t)))
        .filter(|n| *n <= MAX_PLAUSIBLE_SEASON)
}

/// Is this segment purely a season marker, carrying no title of its own?
fn is_pure_season_segment(norm: &str) -> bool {
    let tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
    if tokens.is_empty() {
        return false;
    }
    // Any bare number is allowed *here* — "Season 01" states season one, and
    // the "numbers below 2 aren't season markers" rule exists to stop a
    // trailing title number being read as a season, which is a different
    // question from what follows the word "season".
    let season_word = |t: &str| {
        t == "season"
            || t == "seasons"
            || ((t.starts_with('s') || t.starts_with('r'))
                && t.len() > 1
                && t[1..].chars().all(|c| c.is_ascii_digit()))
    };
    let all_seasonish = tokens
        .iter()
        .all(|t| is_season_marker(t) || t.chars().all(|c| c.is_ascii_digit()));
    // A real season word is required, so a lone episode number can never pass.
    all_seasonish && tokens.iter().any(|t| season_word(t))
}

/// Season number expressed in a normalized title: "s2", "season 2",
/// "2nd season", "r2" (Code Geass-style sequel marker, "R2" = "Rebellion 2").
/// Absent marker means season 1.
pub fn season_of(norm: &str) -> u32 {
    for re in [
        r"\bs(\d{1,2})\b",
        r"\bseason (\d{1,2})\b",
        r"\b(\d{1,2})(?:st|nd|rd|th) season\b",
        r"\br(\d{1,2})\b",
    ] {
        if let Some(c) = regex_lite::Regex::new(re).unwrap().captures(norm) {
            if let Ok(n) = c[1].parse() {
                return n;
            }
        }
    }

    // AniList writes sequels the way the official title does — "Mob Psycho 100
    // II", "Ashita no Joe 2" — while release groups write "S2". Reading only
    // the release convention meant the query parsed as season 1 and the
    // release as season 2, so they were rejected as different shows and such a
    // series returned almost no candidates at all.
    //
    // Only the final token counts, and only in a title segment. That is what
    // makes this safe: an episode number ("Toradora - 05") is a segment of its
    // own by the time this sees it, so it can never be read as a season. The
    // two-digit cap keeps "Mob Psycho 100" from claiming season 100.
    let tokens: Vec<&str> = norm.split(' ').filter(|t| !t.is_empty()).collect();
    if let Some(&last) = tokens.last() {
        if let Some(n) = roman_numeral(last) {
            return n;
        }
        // A bare number preceded by another bare number is an episode range or
        // list ("Chunibyo Lite 1 6", from "1-6"), not a season marker — a real
        // trailing season number stands alone. Without this guard, an alias
        // segment naming an OVA/shorts entry by its relative episode range got
        // read as "season 6" and rejected against the query's season 1.
        let prev_is_digit = tokens.len() >= 2 && tokens[tokens.len() - 2].chars().all(|c| c.is_ascii_digit());
        if !prev_is_digit && last.len() <= 2 {
            if let Ok(n) = last.parse::<u32>() {
                // A leading-zero form ("Show 02") is a season the same as "2";
                // a bare 0 is neither.
                if n >= 2 {
                    return n;
                }
            }
        }
    }
    1
}

/// Sequel numbering written as a roman numeral, II through X.
///
/// Deliberately excludes "I": it is a common word and a common initial, and a
/// season-1 marker changes nothing anyway (absent marker already means 1).
fn roman_numeral(t: &str) -> Option<u32> {
    match t {
        "ii" => Some(2),
        "iii" => Some(3),
        "iv" => Some(4),
        "v" => Some(5),
        "vi" => Some(6),
        "vii" => Some(7),
        "viii" => Some(8),
        "ix" => Some(9),
        "x" => Some(10),
        _ => None,
    }
}

/// Does a bracketed chunk contain nothing but an episode range ("01-25")?
///
/// Used to decide whether dropping it would destroy the very thing we're about
/// to look for.
fn is_range_only(inner: &str) -> bool {
    regex_lite::Regex::new(r"^\s*\d{1,4}(?:\.\d)?\s*[-~]\s*\d{1,4}(?:\.\d)?\s*$")
        .unwrap()
        .is_match(inner)
}

/// Strip tokens that look like episode numbers but aren't (resolution, codec,
/// bit depth, years, CRC groups) before trying to parse an episode number.
fn strip_noise(name: &str) -> String {
    let mut s = String::with_capacity(name.len());
    // Drop bracketed groups: [SubsPlease], [B7F32C9A]. Parenthesized chunks
    // stay because episode ranges like (01-28) live in them.
    //
    // Except when the bracket holds a bare range. Release naming doesn't agree
    // on which punctuation wraps the range — "(01-25)" survived while the
    // equally common "[01-25]" was deleted before parse_episode ever saw it,
    // so those releases parsed as having no episode information at all and
    // were rejected. Keep a bracket whose entire contents is a range; drop
    // every other one exactly as before, so group tags and CRC hashes still
    // can't be misread as episode numbers.
    let mut depth: i32 = 0;
    let mut buf = String::new();
    for c in name.chars() {
        match c {
            '[' => {
                depth += 1;
                if depth == 1 {
                    buf.clear();
                }
            }
            ']' => {
                depth = (depth - 1).max(0);
                if depth == 0 && is_range_only(&buf) {
                    s.push(' ');
                    s.push_str(&buf);
                    s.push(' ');
                }
            }
            _ if depth == 0 => s.push(c),
            _ => buf.push(c),
        }
    }
    for pat in [
        r"\d{3,4}[pP]", r"[xXhH]\.?26[45]", r"10.?[bB]it", r"8.?[bB]it",
        r"\b(19|20)\d{2}\b", r"[fF][lL][aA][cC]", r"[aA][aA][cC]2?\.?0?",
        r"[hH][eE][vV][cC]", r"[aA][vV]1\b",
    ] {
        let re = regex_lite::Regex::new(pat).unwrap();
        s = re.replace_all(&s, " ").to_string();
    }
    s
}

/// Parse an episode designation out of a (noise-stripped) release name.
/// Returns (exact_episode, batch_range).
fn parse_episode(name: &str) -> (Option<f64>, Option<(f64, f64)>) {
    // "E039-E058", "EP01-EP12". Checked before everything else: the plain
    // range pattern below can't see it (a letter sits between the dash and the
    // second number), and the single-episode "E05" pattern matches its first
    // half — so a batch covering episodes 39-58 was read as *exactly* episode
    // 39 and rejected for every other episode in its own range.
    // Batch range: "01-28", "01 ~ 28", "(01-10)", "E039-E058".
    //
    // Checked over every adjacent pair of numbers rather than with a single
    // regex sweep. A regex consumes what it matches, so in "86 Eighty-Six Part
    // 2 - 01 ~ 12" it matched "2 - 01" first, failed the a<b test, and then
    // resumed *past* the "01" — leaving the real "01 ~ 12" unreachable. That
    // release fell through to the single-episode rule below, was read as
    // exactly episode 1, and a 49-seeder batch of the whole cour was rejected
    // for every other episode it contains.
    let num_re = regex_lite::Regex::new(r"\d{1,4}(?:\.\d)?").unwrap();
    let nums: Vec<(usize, usize, f64)> = num_re
        .find_iter(name)
        .map(|m| (m.start(), m.end(), m.as_str().parse().unwrap_or(0.0)))
        .collect();
    for pair in nums.windows(2) {
        let (_, end_a, a) = pair[0];
        let (start_b, _, b) = pair[1];
        let between = &name[end_a..start_b];
        // Only separator characters may sit between the two numbers; the
        // optional letters cover the "E039-E058" / "EP01-EP12" form.
        if !between
            .chars()
            .all(|c| c.is_whitespace() || matches!(c, '-' | '~' | 'e' | 'E' | 'p' | 'P'))
            || !between.contains(['-', '~'])
        {
            continue;
        }
        // A dash with space on both sides is the title/episode separator, not
        // a range: "Ashita no Joe 2 - 07" is episode 7 of season 2, and reading
        // it as the range 2-7 would match five episodes the release lacks.
        // Ranges are written "01-25" or with a tilde.
        let spaced_dash = !between.contains('~')
            && between.starts_with(char::is_whitespace)
            && between.ends_with(char::is_whitespace);
        // `a >= 1` keeps "Steins Gate 0 - 12" from reading as the range 0-12.
        if !spaced_dash && a >= 1.0 && a < b && b - a <= 600.0 && b <= 3000.0 {
            return (None, Some((a, b)));
        }
    }
    // "S01E05"
    if let Some(c) = regex_lite::Regex::new(r"[sS]\d{1,2}[eE](\d{1,4})").unwrap().captures(name) {
        return (c[1].parse().ok(), None);
    }
    // "Title - 05", "Title - 05v2", "Title - 05.5"
    if let Some(c) = regex_lite::Regex::new(r"\s-\s(\d{1,4}(?:\.\d)?)(?:[vV]\d)?\b").unwrap().captures(name) {
        return (c[1].parse().ok(), None);
    }
    // "E05", "EP05", "Episode 5"
    if let Some(c) = regex_lite::Regex::new(r"\b[eE][pP]?(?:isode)?\.?\s?(\d{1,4})\b").unwrap().captures(name) {
        return (c[1].parse().ok(), None);
    }
    (None, None)
}

/// Does a filename inside a (batch) torrent carry this episode number?
pub fn filename_matches_episode(name: &str, episode: i64) -> bool {
    filename_episode(name) == Some(episode)
}

/// The episode number a filename states, if it states one.
pub fn filename_episode(name: &str) -> Option<i64> {
    // Underscore is a separator to a good half of the release groups
    // ("Show_-_01_(BD1080p).mkv", "Show - 01_BD720p_10bit.mkv") and a word
    // character to a regex, so the episode patterns below — which all end at a
    // word boundary — could not see a number with one glued to it. Whole packs
    // parsed as having no episode numbers at all because of it.
    let stripped = strip_noise(&name.replace('_', " "));
    match parse_episode(&stripped) {
        (Some(e), _) if e >= 0.0 && e.fract() == 0.0 => Some(e as i64),
        _ => None,
    }
}

/// The season a filename (or, for a batch, its full in-torrent path) states
/// explicitly, if any — "Season 2/[EMBER] ... S02E01 ....mkv" is season 2,
/// "[SubsPlease] Show - 05.mkv" states none. Distinct from `filename_episode`
/// in that an unmarked file means "unknown", not "season 1": a combined
/// "Season 1+2" batch can hold two files that both literally match the same
/// episode number (one per season, differing only by this marker), and
/// treating "no marker" as season 1 would make an actually-season-2 file
/// that happens to lack a tag look like a false conflict with a season-1
/// request instead of the "don't know" it really is.
pub fn filename_season(name: &str) -> Option<u32> {
    explicit_season(&normalize(name))
}

/// Translate a relative episode number into the absolute one a release uses.
///
/// Split cours are numbered two different ways at once. AniList gives "86
/// EIGHTY-SIX Part 2" its own entry with episodes 1-11, while releases continue
/// the series count and ship files 12-23 — so asking a batch for "episode 2"
/// finds nothing and a perfectly good release is discarded.
///
/// Only fires when the evidence is unambiguous. The filenames must state a
/// contiguous run starting above 1 (a release numbering from 1 has no offset,
/// and a genuinely missing episode must stay missing), and that run must be
/// exactly as long as this AniList entry's season.
///
/// The length check is what makes this safe rather than a guess, because a
/// literal filename match is not proof on its own: for a Part 2 numbered 12-23,
/// relative episode 12 *and* absolute file 12 both exist, and they are
/// different episodes. Requiring `episode_count` to equal the run length tells
/// the two apart — a 12-file run answers a 12-episode entry (remap) but not the
/// 23-episode entry for the whole series (don't). An unknown count never
/// remaps.
/// Whether a release name announces multiple seasons bundled into one pack
/// ("Season 1+2+OVA", "S1+S2 Batch"). `absolute_episode`'s split-cour
/// heuristic assumes every file in a numbered run belongs to *this* AniList
/// entry's own season — a combined-seasons pack violates that outright (a
/// 12-file run starting past episode 1 is just as likely to be the *other*
/// season's episodes as a split-cour continuation), so it must never be
/// trusted to remap episode numbers for one.
pub fn multi_season_batch(name_norm: &str) -> bool {
    regex_lite::Regex::new(r"\bseasons?\s+\d{1,2}(?:\s+\d{1,2}){1,}\b")
        .unwrap()
        .is_match(name_norm)
        || regex_lite::Regex::new(r"\bs\d{1,2}\s+s\d{1,2}\b")
            .unwrap()
            .is_match(name_norm)
}

pub fn absolute_episode(
    filename_episodes: &[i64],
    episode: i64,
    episode_count: Option<i64>,
) -> Option<i64> {
    if filename_episodes.len() < 2 {
        return None;
    }
    let lo = *filename_episodes.iter().min()?;
    let hi = *filename_episodes.iter().max()?;
    let count = hi - lo + 1;
    if count != filename_episodes.len() as i64
        || lo <= 1
        || episode_count != Some(count)
        || episode < 1
        || episode > count
    {
        return None;
    }
    Some(lo + episode - 1)
}

fn minimal_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// Seeder count above which extra seeders stop improving the score.
const SEEDER_SATURATION: u64 = 400;
/// Scales the seeder curve. Chosen so the maximum bonus stays under
/// `SD_PENALTY`, keeping "1080p beats the same release in 720p" true.
const SEEDER_WEIGHT: f64 = 18.0;
/// At or below this many seeders a swarm is treated as probably dead.
const LOW_SEEDER_THRESHOLD: u64 = 5;
/// Penalty applied below `LOW_SEEDER_THRESHOLD`. Large enough to sink a
/// near-dead release below a healthy one a whole confidence tier down.
const DEAD_SWARM_PENALTY: i64 = 350;
/// Nyaa's "trusted" moderation flag. Worth something, but it speaks to a
/// release's legitimacy, not to whether anyone is still seeding it — it used to
/// be +300, the size of an entire confidence tier, which is how a 2-seeder
/// release outranked one with 52.
const TRUSTED_BONUS: i64 = 100;

/// Build a magnet from a bare infohash, with the standard open trackers
/// appended so peers are found before DHT bootstraps.
pub(crate) fn magnet_from_infohash(infohash: &str) -> String {
    let trackers: String = TRACKERS
        .iter()
        .map(|t| format!("&tr={}", urlencoding_encode(t)))
        .collect();
    format!("magnet:?xt=urn:btih:{}{}", infohash, trackers)
}

/// Score contribution from a swarm's seeder count.
///
/// Square-root rather than linear: the difference between 2 and 20 seeders
/// decides whether a stream plays at all, while the difference between 200 and
/// 400 is invisible to the viewer. A linear `seeders/3` (capped at 100) got
/// this backwards — it was too flat at the low end to separate a dead swarm
/// from a live one, and seeder count is the single strongest predictor of
/// whether a torrent actually starts.
pub(crate) fn seeder_score(seeders: u64) -> i64 {
    ((seeders.min(SEEDER_SATURATION) as f64).sqrt() * SEEDER_WEIGHT) as i64
}

/// Penalty for a film when a numbered series episode was requested.
const FILM_MISMATCH_PENALTY: i64 = 300;

/// A 720p release scores this far below the equivalent 1080p one.
///
/// Large enough that the seeder bonus (capped at 100) can never flip the
/// ordering: 1080p is always preferred when it exists, and 720p only surfaces
/// when nothing better matched. Worth having at all because a lot of the back
/// catalog was broadcast in SD — for those shows the 720p BD is the real
/// source and the 1080p is an upscale of it — and because rejecting 720p
/// outright threw away well-seeded releases when the 1080p alternatives were
/// nearly dead.
const SD_PENALTY: i64 = 400;

/// How far a release whose name advertises a codec no browser can decode is
/// pushed down when the stream is bound for a `<video>` element.
///
/// Sized to dominate every other term rather than merely compete with them: an
/// incompatible release does not play *at all*, so even the best-cased one
/// (exact episode 1000 + trusted 100 + saturated seeders 360 = 1460) must land
/// below the worst-cased compatible alternative that still scores (a bare
/// untagged batch at 300 with no seeder bonus). Anything smaller leaves an
/// inversion where a heavily-seeded AV1 exact match outranks a thin but
/// playable batch.
///
/// Deliberately a penalty and not a rejection. Codec detection is name-based
/// guesswork — `[SubsPlease] Show - 05 (1080p)` states no codec at all — so a
/// false positive must cost a release its rank, never its existence. When
/// nothing compatible matched, a negative-scoring candidate is still the best
/// on offer and still gets tried; scores are only ever compared, never
/// thresholded.
const BROWSER_INCOMPATIBLE_PENALTY: i64 = 1200;

/// Whether a release name advertises a video or audio codec that browsers
/// cannot decode in a `<video>` element.
///
/// Video: HEVC and AV1 have no reliable browser support in Matroska, and
/// 10-bit H.264 (Hi10P — endemic in anime) has none anywhere at all.
/// Audio: E-AC-3, FLAC and DTS all ride along in otherwise-fine H.264 releases
/// and fail on their own.
///
/// Matched against `normalize`d text, which lowercases and turns *every*
/// non-alphanumeric character into a space. So a marker may never contain a dot
/// or a hyphen — `H.265` arrives as `h 265` and `E-AC-3` as `e ac 3`, which is
/// why both spellings appear here as space-separated phrases. (The neighbouring
/// dub check's "dual-audio" is unreachable for exactly this reason.)
///
/// Matched on whole tokens rather than as substrings: `dts` and `av1` are short
/// enough to appear inside unrelated words, and a false positive here costs a
/// release its rank.
pub fn browser_incompatible_codec(name_norm: &str) -> bool {
    const PHRASES: &[&str] = &[
        // Video
        "hevc", "x265", "h265", "h 265", "x 265", "av1",
        "10bit", "10 bit", "hi10", "hi10p",
        // Audio
        "eac3", "eac 3", "e ac 3", "flac", "dts",
    ];
    let padded = format!(" {} ", name_norm);
    if PHRASES.iter().any(|p| padded.contains(&format!(" {p} "))) {
        return true;
    }
    // Dolby Digital Plus carries its channel layout in the same token —
    // "DDP5.1" normalizes to "ddp5 1", so an exact-token match misses it.
    name_norm.split(' ').any(|t| t.starts_with("ddp"))
}

/// This entry's own titles alongside those of the franchise's other AniList
/// entries. Only read for an extras entry, where the two are the difference
/// between "the OVA" and "the other OVA" — see `names_a_sibling`.
#[derive(Clone, Copy)]
pub struct SiblingTitles<'a> {
    pub own: &'a [String],
    pub related: &'a [String],
}

/// What a release is being scored against. Bundled rather than passed as a
/// fourth and fifth positional `bool`, which had already made call sites read
/// as `(name, q, 13, false, false)`.
#[derive(Debug, Clone, Copy)]
pub struct ReleaseCriteria {
    pub episode: i64,
    pub allow_episodeless: bool,
    pub prefer_dub: bool,
    /// The stream is bound for a browser `<video>` element rather than mpv.
    /// mpv plays everything here, so this is only ever set for the mobile PWA.
    pub browser_client: bool,
    /// This AniList entry is an OVA or a specials collection rather than a
    /// TV run. Two things follow: the entry's title carries a kind marker
    /// release names never do, and its episodes are numbered from 1 while a
    /// release numbers the same files as part of one continuous specials
    /// sequence ("S00E03-E08" for the six specials AniList calls 1-6).
    pub extras: bool,
    /// How many episodes this entry has, when known. Only read for `extras`,
    /// where it is what tells a range covering *this* entry apart from one
    /// covering the franchise's other specials.
    pub episode_count: Option<i64>,
}

/// Score a release name against the wanted episode. None = reject.
fn score_release(
    name: &str,
    query_norm: &str,
    alts: &[String],
    siblings: &SiblingTitles<'_>,
    criteria: ReleaseCriteria,
) -> Option<(i64, bool)> {
    let ReleaseCriteria { episode, allow_episodeless, prefer_dub, browser_client, extras, episode_count } = criteria;
    let name_norm = normalize(name);
    // An extras entry is matched with its kind marker dropped — see
    // `strip_extras_marker`. The Nyaa query itself keeps the word, so this
    // loosens what counts as a hit without widening what is searched for.
    let stripped_query;
    let query_norm = if extras {
        stripped_query = strip_extras_marker(query_norm);
        stripped_query.as_str()
    } else {
        query_norm
    };
    if !title_matches_with_alts(query_norm, name, alts) {
        return None;
    }
    // For an extras entry only: the franchise's other entries share this
    // one's title, so a release of any of them matches it. See
    // `names_a_sibling`.
    if extras
        && (names_a_sibling(&name_norm, siblings.own, siblings.related)
            || names_an_unrelated_extra(name, siblings.own))
    {
        return None;
    }
    let hd = name_norm.contains("1080");
    if !hd && !name_norm.contains("720") {
        return None;
    }
    let stripped = strip_noise(name);
    let (exact, range) = parse_episode(&stripped);
    let ep = episode as f64;
    let mut assume_batch = false;
    let mut score = match (exact, range) {
        (Some(e), _) if (e - ep).abs() < 0.01 => 1000,
        (None, Some((a, b))) if ep >= a && ep <= b => 600,
        // A specials release states the range the *franchise* numbers those
        // files, not the range AniList does: "S00E03-E08" is the six specials
        // this entry calls 1 through 6. Length is what makes the two the same
        // set — a run exactly as long as the entry, holding the episode
        // asked for once it is counted from its own start. Same reasoning as
        // `absolute_episode`, applied to the release name instead of the
        // files inside it, and only where the mismatch is structural.
        (None, Some((a, b)))
            if extras
                && episode_count == Some((b - a + 1.0) as i64)
                && ep >= 1.0
                && ep <= b - a + 1.0 =>
        {
            600
        }
        (None, None) if allow_episodeless => 400,
        // No episode information anywhere in the name. Nearly every
        // complete-series BD release is named this way, and rejecting them
        // outright is why a finished show could surface three candidates when
        // the site had a dozen — including its best-seeded ones. Rank them
        // below every release that actually states its episode, and let
        // try_candidate confirm the episode really is inside before playing.
        (None, None) => {
            assume_batch = true;
            300
        }
        _ => return None,
    };
    if !hd {
        score -= SD_PENALTY;
    }
    // A film shares its series' name and so matches it legitimately, but it
    // cannot contain "episode 7". Accepting untagged releases brought these
    // into range ("Ashita no Joe Movie 2", "K-ON! the Movie" for a numbered
    // episode), where they cost a candidate slot before try_candidate's
    // filename check rejects them. Rank them last instead. Only when a
    // numbered episode was actually asked for — for a film, allow_episodeless
    // is set and this is exactly the release wanted.
    let looks_like_film = name_norm.contains("movie")
        || name_norm.contains("gekijouban")
        || name_norm.contains(" film");
    if looks_like_film && !allow_episodeless && exact.is_none() {
        score -= FILM_MISMATCH_PENALTY;
    }
    if prefer_dub {
        if is_dub_release(&name_norm) {
            score += DUB_BONUS;
        } else {
            // Decisive rather than a nudge: the old +250 bonus was routinely
            // outweighed by a sub-only release with a healthier swarm or a
            // tighter title match, so asking for a dub got one only when the
            // dub happened to be the best release anyway. `find_candidates`
            // gives this back when no dub exists at all, so a dub-less show
            // is ranked as if the preference had never been expressed.
            score -= NON_DUB_PENALTY;
        }
    } else if is_dub_only_release(&name_norm) {
        // The mirror of the above, and the more common complaint: a release
        // that is English-audio-only is not a substitute for the sub that was
        // asked for -- unlike a dual-audio release, which satisfies either
        // preference and is deliberately not penalized here.
        score -= DUB_ONLY_PENALTY;
    }
    if browser_client && browser_incompatible_codec(&name_norm) {
        score -= BROWSER_INCOMPATIBLE_PENALTY;
    }
    Some((score, assume_batch))
}

async fn search_subsplease(
    client: &reqwest::Client,
    title: &str,
    alts: &[String],
    episode: i64,
    prefer_dub: bool,
) -> Vec<Candidate> {
    let mut out = vec![];
    let url = format!(
        "https://subsplease.org/api/?f=search&tz=UTC&s={}",
        urlencoding_encode(title)
    );
    let resp = match client.get(&url).send().await.and_then(|r| r.error_for_status()) {
        Ok(r) => r,
        Err(e) => {
            log::warn!("torrent: subsplease search failed: {}", e);
            return out;
        }
    };
    let json: Value = match resp.json().await {
        Ok(j) => j,
        Err(_) => return out,
    };
    let Some(map) = json.as_object() else { return out };
    let query_norm = normalize(title);
    for (_key, item) in map {
        let show = item.get("show").and_then(|v| v.as_str()).unwrap_or("");
        let ep_str = item.get("episode").and_then(|v| v.as_str()).unwrap_or("");
        let show_norm = normalize(show);
        // SubsPlease search is fuzzy; require the whole query in the show name.
        if !title_matches_with_alts(&query_norm, &show_norm, alts) {
            continue;
        }
        // Batch entries look like "01-28", singles like "10" or "10.5".
        let ep = episode as f64;
        let mut score = if let Some((a, b)) = ep_str
            .split_once('-')
            .and_then(|(a, b)| Some((a.trim().parse::<f64>().ok()?, b.trim().parse::<f64>().ok()?)))
        {
            if ep >= a && ep <= b { 1600 } else { continue }
        } else if ep_str.parse::<f64>().map(|e| (e - ep).abs() < 0.01).unwrap_or(false) {
            2000
        } else {
            continue;
        };
        // Prefer exactly-matching show names over longer ones ("Show" vs "Show S2").
        if show_norm == query_norm {
            score += 100;
        }
        if prefer_dub {
            // SubsPlease is sub-only, so it takes the same penalty
            // `score_release` applies to every non-dub release -- and it has
            // to take it here rather than being left alone, because
            // `find_candidates` refunds that penalty across the whole pool
            // when no dub exists anywhere. A candidate that never paid it
            // would collect the refund anyway and end up ranked above the
            // Nyaa releases it was previously tied with.
            score -= NON_DUB_PENALTY;
        }
        let Some(downloads) = item.get("downloads").and_then(|v| v.as_array()) else { continue };
        for d in downloads {
            if d.get("res").and_then(|v| v.as_str()) == Some("1080") {
                if let Some(magnet) = d.get("magnet").and_then(|v| v.as_str()) {
                    out.push(Candidate {
                        name: format!("[SubsPlease] {} - {} (1080p)", show, ep_str),
                        magnet: Some(magnet.to_string()),
                        torrent_url: None,
                        seeders: 50, // not reported by the API; assume healthy
                        score,
                        // The API states the episode (or range) explicitly, so
                        // there is never anything to assume here.
                        assume_batch: false,
                    });
                }
            }
        }
    }
    out
}

/// AnimeTosho's `title` is its own rewritten, metadata-enriched name
/// ("[EMBER] Frieren: Beyond Journey's End S02E05 [1080p] ..."), while
/// `torrent_name` is the release's real name, which is what Nyaa lists and
/// what the in-torrent layout matcher expects. Neither is strictly better:
/// the rewritten title often carries the English series name that the raw
/// release name never does (so it matches an AniList `english` title the
/// Nyaa listing would miss), while the raw name is the one that dedupes
/// against Nyaa and that `layout::select` reasons about. Score both and keep
/// whichever wins, so `name`, `score` and `assume_batch` always describe the
/// same string.
fn better_scored_name(
    title: &str,
    torrent_name: &str,
    query_title_norm: &str,
    alts: &[String],
    siblings: &SiblingTitles<'_>,
    criteria: ReleaseCriteria,
) -> Option<(String, i64, bool)> {
    let mut best: Option<(String, i64, bool)> = None;
    for cand in [torrent_name, title] {
        if cand.is_empty() {
            continue;
        }
        if let Some((score, assume_batch)) =
            score_release(cand, query_title_norm, alts, siblings, criteria)
        {
            if best.as_ref().is_none_or(|(_, best_score, _)| score > *best_score) {
                best = Some((cand.to_string(), score, assume_batch));
            }
        }
    }
    best
}

/// Drop a trailing container extension from a release name. AnimeTosho's
/// `torrent_name` for a single-file torrent is the file itself
/// ("[ASW] Show - 05.mkv"); Nyaa lists the same release without it, and an
/// unstripped "mkv" token survives `normalize` and defeats the dedupe that
/// merges the two listings of one release.
fn strip_container_ext(name: &str) -> &str {
    for ext in [".mkv", ".mp4", ".avi", ".webm", ".ts", ".m4v", ".mov"] {
        if let Some(stripped) = name.strip_suffix(ext) {
            return stripped;
        }
    }
    name
}

/// AnimeTosho mirrors Nyaa (and AniDex/Tosho's own uploads) behind a plain
/// JSON feed with no rate limiting, and every entry carries a direct
/// `.torrent` URL — so a hit here skips both the RSS parse and the DHT
/// metadata round-trip a magnet would cost. It answers a whole query in one
/// request where Nyaa needs a throttled round of three, which is why it runs
/// ahead of Nyaa rather than alongside it.
async fn search_animetosho(
    client: &reqwest::Client,
    query: &str,
    query_title_norm: &str,
    alts: &[String],
    siblings: &SiblingTitles<'_>,
    criteria: ReleaseCriteria,
) -> Vec<Candidate> {
    let mut out = vec![];
    let url = format!(
        "https://feed.animetosho.org/json?q={}&only_tor=1",
        urlencoding_encode(query)
    );
    let mut items: Vec<Value> = Vec::new();
    for attempt in 0..=1 {
        // Tightly bounded, and deliberately tighter than a request timeout
        // usually is. AnimeTosho serves one query at a time per client, so two
        // fired together queue: the second cannot start until the first
        // finishes, and a fruitful query takes ~2.4s against the live feed.
        // Everything here runs concurrently with a Nyaa round that answers in
        // about a second and covers the same releases, so a query still
        // waiting at three seconds has already stopped being the fast index
        // and become the reason the play is slow. Dropping it costs the extra
        // candidates it would have added; keeping it costs the whole wave.
        const TOSHO_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(3);
        let request = client
            .get(&url)
            .header("User-Agent", "AniCat/5.8.0")
            .timeout(TOSHO_TIMEOUT);
        match request.send().await {
            Ok(r) if r.status() == reqwest::StatusCode::TOO_MANY_REQUESTS && attempt == 0 => {
                tokio::time::sleep(std::time::Duration::from_millis(500)).await;
                continue;
            }
            Ok(r) if !r.status().is_success() => {
                log::warn!("torrent: animetosho returned HTTP {} for '{}'", r.status(), query);
                return out;
            }
            Ok(r) => {
                match r.json::<Vec<Value>>().await {
                    Ok(j) => items = j,
                    // Distinguished from an empty feed on purpose: both reach
                    // the caller as "no candidates", and only one of them is
                    // a reason to look at this function.
                    Err(e) => log::warn!(
                        "torrent: animetosho response for '{}' did not parse as a list: {}",
                        query, e
                    ),
                }
                break;
            }
            Err(e) if e.is_timeout() => {
                // Expected often enough not to be a warning: the budget below
                // is deliberately shorter than this feed's slow path, and a
                // dropped query costs extra candidates, never the play.
                log::info!("torrent: animetosho gave up on '{}' at its timeout", query);
                return out;
            }
            Err(e) => {
                log::warn!("torrent: animetosho search failed for '{}': {}", query, e);
                return out;
            }
        }
    }
    for item in items {
        let title = item.get("title").and_then(|v| v.as_str()).unwrap_or_default();
        let torrent_name = item
            .get("torrent_name")
            .and_then(|v| v.as_str())
            .map(strip_container_ext)
            .unwrap_or_default();
        if title.is_empty() && torrent_name.is_empty() {
            continue;
        }
        // `seeders` is null for entries AnimeTosho has not managed to scrape a
        // tracker for yet -- which says nothing about the swarm. Treating that
        // as zero dropped the entry outright (the `< 2` gate below); treat it
        // as unknown instead and let it in at the dead-swarm penalty, which is
        // where an unverifiable swarm belongs.
        let seeders_known = item.get("seeders").and_then(|v| v.as_u64());
        let seeders = seeders_known.unwrap_or(0);
        if seeders_known.is_some() && seeders < 2 {
            continue;
        }
        let Some((name, mut score, assume_batch)) = better_scored_name(
            title, torrent_name, query_title_norm, alts, siblings, criteria,
        ) else {
            continue;
        };
        score += seeder_score(seeders);
        if seeders < LOW_SEEDER_THRESHOLD {
            score -= DEAD_SWARM_PENALTY;
        }
        let torrent_url = item.get("torrent_url").and_then(|v| v.as_str()).map(|s| s.to_string());
        let magnet_uri = item.get("magnet_uri").and_then(|v| v.as_str()).map(|s| s.to_string());
        let info_hash = item.get("info_hash").and_then(|v| v.as_str());
        let magnet = magnet_uri.or_else(|| info_hash.map(magnet_from_infohash));

        out.push(Candidate {
            name,
            magnet,
            torrent_url,
            seeders,
            score,
            assume_batch,
        });
    }
    out
}

async fn search_nyaa(
    client: &reqwest::Client,
    query: &str,
    query_title_norm: &str,
    alts: &[String],
    siblings: &SiblingTitles<'_>,
    criteria: ReleaseCriteria,
) -> Vec<Candidate> {
    let mut out = vec![];
    let url = format!(
        "https://nyaa.si/?page=rss&c=1_2&f=0&s=seeders&o=desc&q={}",
        urlencoding_encode(query)
    );
    // A rate-limit or an outage answers with a body that simply has no <item>
    // in it, which is indistinguishable from "this show has no releases" once
    // it reaches the parser — and the symptom, "no streams found", is the same
    // as a genuine miss. Say which one it was, and give a throttled query one
    // more chance before writing the release off: a 429 here doesn't fail a
    // play outright, it quietly shrinks the candidate pool, so the release
    // that wins is whichever survived the throttle rather than the best one.
    let mut body = String::new();
    for attempt in 0..=1 {
        match client.get(&url).send().await {
            Ok(r) if r.status() == reqwest::StatusCode::TOO_MANY_REQUESTS && attempt == 0 => {
                tokio::time::sleep(std::time::Duration::from_millis(400)).await;
                continue;
            }
            Ok(r) if !r.status().is_success() => {
                log::warn!("torrent: nyaa search returned HTTP {} for '{}'", r.status(), query);
                return out;
            }
            Ok(r) => {
                body = r.text().await.unwrap_or_default();
                break;
            }
            Err(e) => {
                log::warn!("torrent: nyaa search failed: {}", e);
                return out;
            }
        }
    }
    if body.is_empty() {
        return out;
    }
    let item_re = regex_lite::Regex::new(r"(?s)<item>(.*?)</item>").unwrap();
    let field = |item: &str, tag: &str| -> String {
        regex_lite::Regex::new(&format!(r"(?s)<{tag}>(.*?)</{tag}>"))
            .unwrap()
            .captures(item)
            .map(|c| minimal_unescape(c[1].trim()))
            .unwrap_or_default()
    };
    for c in item_re.captures_iter(&body).take(40) {
        let item = &c[1];
        let name = field(item, "title");
        let seeders: u64 = field(item, "nyaa:seeders").parse().unwrap_or(0);
        if seeders < 2 {
            continue;
        }
        let trusted = field(item, "nyaa:trusted") == "Yes";
        let torrent_url = field(item, "link");
        let infohash = field(item, "nyaa:infoHash");
        let Some((mut score, assume_batch)) = score_release(&name, query_title_norm, alts, siblings, criteria) else {
            continue;
        };
        if trusted {
            score += TRUSTED_BONUS;
        }
        score += seeder_score(seeders);
        // A release nobody is seeding is not a candidate worth spending the
        // startup budget on: try_candidate pays a peer-grace wait and, if any
        // peer does connect, up to the full pre-buffer timeout before giving
        // up — so two of these ahead of a healthy release is most of a minute
        // of the user staring at nothing. Sink them below the healthy ones
        // rather than dropping them, since they are still better than no
        // playback at all when nothing else matched.
        if seeders < LOW_SEEDER_THRESHOLD {
            score -= DEAD_SWARM_PENALTY;
        }
        let magnet = if infohash.is_empty() {
            None
        } else {
            Some(magnet_from_infohash(&infohash))
        };
        out.push(Candidate {
            name,
            magnet,
            torrent_url: if torrent_url.is_empty() { None } else { Some(torrent_url) },
            seeders,
            score,
            assume_batch,
        });
    }
    out
}

/// Find ranked torrent candidates for `titles` (AniList romaji/english/
/// synonyms, best first) episode `episode`.
/// How hard to look before answering.
///
/// The two callers want opposite things. The play path wants the *first*
/// releases that will actually play, as fast as possible; the release picker
/// wants everything there is, because the user opened it precisely to see the
/// options the auto-pick passed over.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Breadth {
    /// Stop once the pool holds enough healthy, episode-stating releases to
    /// fill the shortlist `resolve` actually races.
    Fast,
    /// Query every title variant, always.
    Full,
}

/// Candidates of this quality make further querying pointless for the play
/// path: the release names its episode (so no in-torrent verification is
/// needed to know it is the right one), its swarm is above the
/// probably-dead line, and it survived scoring with room to spare -- a
/// browser-incompatible release, penalized by 1200, can never clear this.
fn is_strong(c: &Candidate) -> bool {
    !c.assume_batch && c.seeders >= LOW_SEEDER_THRESHOLD && c.score >= 600
}

/// How many of the pool's candidates `resolve` will ever touch: it slices the
/// top four, races two of them and keeps the other two as sequential
/// fallbacks. Everything past this is a longer list nothing reads.
const SHORTLIST_SIZE: usize = 4;
/// How many *strong* candidates are enough to stop querying. Only the raced
/// pair needs to clear that bar -- see `enough_candidates`, which requires the
/// rest of the shortlist to be merely viable.
const ENOUGH_STRONG_CANDIDATES: usize = 2;

pub async fn find_candidates(
    client: &reqwest::Client,
    titles: &[String],
    related_titles: &[String],
    criteria: ReleaseCriteria,
    breadth: Breadth,
) -> Vec<Candidate> {
    let episode = criteria.episode;
    let prefer_dub = criteria.prefer_dub;
    let mut all: Vec<Candidate> = vec![];

    // Expand season-naming variants and short forms, keep order, dedupe, cap
    // the fan-out. Each title is followed immediately by its own short form so
    // the cap can never keep a title while dropping the variant of it that
    // works — and a manual override, which `gather_media_info` puts first
    // precisely because the automatic titles failed, always survives.
    let mut expanded: Vec<String> = vec![];
    for t in titles {
        for v in title_variants(t).into_iter().flat_map(|v| {
            let short = short_title(&v);
            std::iter::once(v).chain(short)
        }) {
            if !v.trim().is_empty() && !expanded.iter().any(|e| normalize(e) == normalize(&v)) {
                expanded.push(v);
            }
        }
    }
    expanded.truncate(4);

    // Every title AniList has for this entry, normalized. Used only to tell an
    // alias apart from a title continuation after a dash — see `segments`.
    // Taken from `titles` rather than `expanded` so the cap above, which exists
    // to bound the number of *searches*, doesn't also narrow what counts as an
    // alias.
    let alts: Vec<String> = titles.iter().map(|t| normalize(t)).collect();
    let siblings = SiblingTitles { own: titles, related: related_titles };

    // The per-episode queries can never legitimately match an untagged
    // release, so they always score with allow_episodeless off regardless of
    // what the caller asked for; only the batch query honours it.
    let single = ReleaseCriteria { allow_episodeless: false, ..criteria };
    // Nyaa queries grouped by title variant rather than flat, because a
    // *round* is the unit of work that can be skipped: the variants are
    // ordered worst-last (a manual override first, then AniList
    // romaji/english, then short forms), so once a round has produced enough
    // playable releases the remaining rounds are querying progressively less
    // likely spellings of a title that already worked.
    let mut rounds: Vec<Vec<(String, String, ReleaseCriteria)>> = vec![];
    for title in &expanded {
        let norm = normalize(title);
        // Nyaa's own full-text search takes the query literally, so title
        // punctuation narrows it. AniList's romaji is the canonical,
        // punctuated form ("Toradora!"), and searching that verbatim returned
        // roughly half the results that the bare word did -- releases are
        // named without it. Matching is unaffected either way: `norm` still
        // governs what counts as a hit, and normalize() already discards
        // punctuation.
        let q_title = search_query_form(title);
        rounds.push(vec![
            (format!("{} - {:02}", q_title, episode), norm.clone(), single),
            // Nyaa's search is an AND over terms, so the episode has to be
            // spelled the way the release spells it or the query returns
            // nothing at all. "Rich Girl Caretaker - 06" returned 0 items
            // while "Rich Girl Caretaker S01E06" returned 5: every group on
            // that show uses the SxxEyy convention and none uses " - NN".
            (
                format!("{} S{:02}E{:02}", q_title, season_of(&norm), episode),
                norm.clone(),
                single,
            ),
            (format!("{} 1080p", q_title), norm, criteria),
        ]);
    }
    // Concurrent, but only so far. Measured against the live site, four
    // concurrent Nyaa requests all answer 200 while eight return two 429s and
    // twelve return six. Every throttled query is a silently smaller candidate
    // pool. A round is three queries, so it fits inside that budget whole and
    // no round is ever split across two waves.
    const MAX_CONCURRENT_NYAA_QUERIES: usize = 4;
    debug_assert!(rounds.iter().all(|r| r.len() <= MAX_CONCURRENT_NYAA_QUERIES));

    // The first two title variants only. `expanded` lists each variant
    // immediately followed by its own short form, so two entries already cover
    // both the long AniList spelling and the short one releases actually use
    // -- which is the pair that matters, since a show whose romaji is a
    // 130-character light-novel sentence is indexed under the short form
    // alone.
    //
    // Kept to two because AnimeTosho serves one query at a time per client:
    // measured against the live feed, four fired together answered at 0.04s,
    // 2.5s, 4.9s and 7.3s -- a clean ~2.4s queue, not parallelism. Two is what
    // fits inside the Nyaa round running alongside it.
    let tosho_queries: Vec<(String, String)> = expanded
        .iter()
        .take(2)
        .map(|title| {
            let norm = normalize(title);
            let q_title = search_query_form(title);
            let q = if criteria.allow_episodeless {
                format!("{} 1080p", q_title)
            } else {
                // One episode spelling, unlike Nyaa's two: AnimeTosho
                // tokenizes "S02E05" so a bare "05" matches it as well as a
                // "- 05" release (verified against the live feed), and its
                // one-at-a-time serving makes a second query cost a full
                // round-trip for releases the first already returned.
                format!("{} {:02}", q_title, episode)
            };
            (q, norm)
        })
        .collect();

    // One wave across three independent hosts rather than three phases. These
    // were run one after another -- SubsPlease, then AnimeTosho, then Nyaa --
    // with each phase's result deciding whether the next ran, which on a cold
    // play meant paying all three round-trips end to end before the first
    // candidate could be tried. Nothing about SubsPlease's answer changes what
    // to ask Nyaa, and the throttling that forces Nyaa into rounds is
    // per-host, so the first round of each belongs in the same wave. Only the
    // *later* Nyaa rounds are conditional, and those are the ones worth
    // skipping: they re-ask progressively less likely spellings of a title the
    // first round already answered.
    let first_wave = std::time::Instant::now();
    let subs_all = futures_util::future::join_all(
        expanded
            .iter()
            .map(|title| search_subsplease(client, title, &alts, episode, prefer_dub)),
    );
    let tosho_all = futures_util::future::join_all(
        tosho_queries
            .iter()
            .map(|(q, norm)| search_animetosho(client, q, norm, &alts, &siblings, criteria)),
    );
    let nyaa_first = async {
        match rounds.first() {
            Some(queries) => {
                futures_util::future::join_all(
                    queries
                        .iter()
                        .map(|(q, norm, crit)| search_nyaa(client, q, norm, &alts, &siblings, *crit)),
                )
                .await
            }
            None => vec![],
        }
    };
    // AnimeTosho enriches the pool but is never allowed to be the reason a
    // play is slow, so it is raced against the other two hosts rather than
    // joined with them: once SubsPlease and the first Nyaa round are in, it
    // gets a short grace period and is then abandoned mid-flight. It serves
    // one query at a time per client and throttles hard under repeated use --
    // measured against the live feed, the same query answered in 0.04s cold
    // and still hadn't answered three seconds later once the feed had decided
    // to queue us. Joining it would have handed that queue straight to the
    // user as startup latency, for an index the other two already cover.
    const TOSHO_GRACE: std::time::Duration = std::time::Duration::from_millis(600);
    let others = async { tokio::join!(subs_all, nyaa_first) };
    tokio::pin!(others);
    tokio::pin!(tosho_all);
    let mut tosho_batches: Vec<Vec<Candidate>> = Vec::new();
    let mut tosho_pending = true;
    let (subs_batches, nyaa_batches) = loop {
        tokio::select! {
            done = &mut others => break done,
            batches = &mut tosho_all, if tosho_pending => {
                tosho_batches = batches;
                tosho_pending = false;
            }
        }
    };
    if tosho_pending {
        match tokio::time::timeout(TOSHO_GRACE, tosho_all).await {
            Ok(batches) => tosho_batches = batches,
            Err(_) => log::info!(
                "[resolve] animetosho abandoned after {:?} of grace; using the other indexes",
                TOSHO_GRACE
            ),
        }
    }
    for batch in subs_batches
        .into_iter()
        .chain(tosho_batches)
        .chain(nyaa_batches)
    {
        all.extend(batch);
    }
    let first_wave_ms = first_wave.elapsed().as_millis();
    // Merged before counting, not after: the same release listed by both Nyaa
    // and AnimeTosho is one candidate, and counting it twice is how a pool
    // holding a single usable release satisfies a threshold that exists to
    // guarantee fallbacks.
    all = merge_duplicates(all);

    let mut query_count = rounds.first().map(|r| r.len()).unwrap_or(0);
    let later_rounds = std::time::Instant::now();
    for (round, queries) in rounds.iter().enumerate().skip(1) {
        if breadth == Breadth::Fast && enough_candidates(&all) {
            log::info!(
                "[resolve] torrent search stopping before round {}/{}: {} strong candidates",
                round + 1,
                rounds.len(),
                all.iter().filter(|c| is_strong(c)).count()
            );
            break;
        }
        query_count += queries.len();
        for batch in futures_util::future::join_all(
            queries
                .iter()
                .map(|(q, norm, crit)| search_nyaa(client, q, norm, &alts, &siblings, *crit)),
        )
        .await
        {
            all.extend(batch);
        }
        all = merge_duplicates(all);
    }
    // The two halves cost very different things: the first wave is one
    // round-trip against three hosts at once, while the rest is Nyaa alone,
    // throttled into chunks of four. Separated because the fix for a slow one
    // is not the fix for a slow other -- fewer title variants versus a
    // different concurrency cap.
    log::info!(
        "[resolve] torrent search titles={} wave1={}ms later_nyaa={}ms queries={} candidates={} strong={}",
        expanded.len(),
        first_wave_ms,
        later_rounds.elapsed().as_millis(),
        query_count,
        all.len(),
        all.iter().filter(|c| is_strong(c)).count()
    );

    // A dub preference is a preference between releases that exist, not a
    // filter. `score_release` sinks every non-dub release by
    // NON_DUB_PENALTY so a dub always wins when there is one -- but on a show
    // with no dub at all that penalty lands on every candidate equally, which
    // changes no ordering and pushes the whole pool under `is_strong`'s
    // absolute bar. Give it back when nothing was preferred over anything.
    if prefer_dub && !all.iter().any(|c| is_dub_release(&normalize(&c.name))) {
        for c in all.iter_mut() {
            c.score += NON_DUB_PENALTY;
        }
    }

    all.sort_by(|a, b| {
        b.score
            .cmp(&a.score)
            .then(b.torrent_url.is_some().cmp(&a.torrent_url.is_some()))
            .then(b.seeders.cmp(&a.seeders))
    });
    all
}

/// Collapse the several listings of one release into one candidate.
///
/// AnimeTosho mirrors most of Nyaa, so the same release routinely arrives
/// from both -- and the two listings are not interchangeable. Their seeder
/// counts come from separate tracker scrapes, and Nyaa's own `trusted` flag
/// adds a bonus AnimeTosho's copy never gets, so the scores differ and a
/// score-ordered `retain` would keep whichever copy happened to win and throw
/// away whatever the other one knew. Keep the best score, the best-known
/// swarm, and any direct `.torrent` URL either of them had -- that last one
/// is the whole reason to prefer a mirrored listing, since it skips the DHT
/// metadata round-trip a magnet costs on the play path.
fn merge_duplicates(candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut out: Vec<Candidate> = Vec::with_capacity(candidates.len());
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    for c in candidates {
        match index.get(&normalize(&c.name)) {
            Some(&i) => {
                let kept: &mut Candidate = &mut out[i];
                kept.score = kept.score.max(c.score);
                kept.seeders = kept.seeders.max(c.seeders);
                if kept.torrent_url.is_none() {
                    kept.torrent_url = c.torrent_url;
                }
                if kept.magnet.is_none() {
                    kept.magnet = c.magnet;
                }
                // Only one of the two listings needs to have named the episode
                // for the pair to stop being a guess.
                kept.assume_batch = kept.assume_batch && c.assume_batch;
            }
            None => {
                index.insert(normalize(&c.name), out.len());
                out.push(c);
            }
        }
    }
    out
}

/// A candidate `resolve` would actually be willing to spend startup budget
/// on: its swarm is above the probably-dead line and it scored well enough to
/// be a plausible match, without the stricter "names its own episode" bar
/// `is_strong` sets.
fn is_viable(c: &Candidate) -> bool {
    c.seeders >= LOW_SEEDER_THRESHOLD && c.score >= 400
}

/// Whether the pool already holds everything `resolve` can reach, so further
/// querying would only lengthen a list nothing will read.
///
/// Two bars, because `resolve` needs two different things. It races the top
/// two candidates, so at least that many have to be *strong* -- a pair of
/// near-dead guesses racing each other is not a head start. And it keeps two
/// more as sequential fallbacks, so the shortlist it slices has to be full;
/// those two only ever get tried after the raced pair failed, which is
/// exactly when being picky about them stops being worth another round-trip
/// to Nyaa.
///
/// Counting distinct releases matters here: before `merge_duplicates` existed
/// the same release listed by two indexes counted twice, so a pool that could
/// only ever race one thing satisfied a threshold meant to guarantee three
/// more behind it.
fn enough_candidates(all: &[Candidate]) -> bool {
    all.iter().filter(|c| is_strong(c)).count() >= ENOUGH_STRONG_CANDIDATES
        && all.iter().filter(|c| is_viable(c)).count() >= SHORTLIST_SIZE
}

pub(crate) fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            b' ' => out.push_str("%20"),
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// No franchise relations known — how every pre-existing assertion here
    /// was written, and what the sibling check degrades to when AniList has
    /// nothing to say about an entry's relatives.
    pub(super) const NO_SIBLINGS: SiblingTitles<'static> = SiblingTitles { own: &[], related: &[] };

    fn candidate(score: i64, seeders: u64, assume_batch: bool) -> Candidate {
        Candidate {
            name: "release".into(),
            magnet: None,
            torrent_url: None,
            seeders,
            score,
            assume_batch,
        }
    }

    /// The exact shape that made this necessary: AnimeTosho and Nyaa both
    /// list one release, their tracker scrapes disagree about the swarm, and
    /// only one of the two listings knows a direct `.torrent` URL.
    #[test]
    fn one_release_listed_by_two_indexes_keeps_what_each_of_them_knew() {
        let from_tosho = Candidate {
            name: "[ASW] Some Show - 05 [1080p]".into(),
            magnet: Some("magnet:?xt=urn:btih:abc".into()),
            torrent_url: Some("https://storage.animetosho.org/torrent/abc.torrent".into()),
            seeders: 40,
            score: 700,
            assume_batch: false,
        };
        // Nyaa scores the same release higher (its `trusted` flag is worth
        // TRUSTED_BONUS, which AnimeTosho's copy never gets) and reports a
        // different swarm -- so a score-ordered dedupe would keep this one and
        // throw the `.torrent` URL away with the other.
        let from_nyaa = Candidate {
            name: "[ASW] Some Show - 05 [1080p]".into(),
            magnet: Some("magnet:?xt=urn:btih:abc".into()),
            torrent_url: None,
            seeders: 55,
            score: 800,
            assume_batch: false,
        };

        let merged = merge_duplicates(vec![from_tosho, from_nyaa]);

        assert_eq!(merged.len(), 1, "the same release must not be raced twice");
        assert_eq!(merged[0].score, 800);
        assert_eq!(merged[0].seeders, 55);
        assert!(
            merged[0].torrent_url.is_some(),
            "the direct .torrent URL is the whole reason to keep the mirrored listing"
        );
    }

    /// A batch assumption is a guess about a name; one listing naming its
    /// episode settles it for the release, not just for that listing.
    #[test]
    fn a_listing_that_names_its_episode_settles_the_batch_guess_for_both() {
        let guessed = Candidate { name: "release".into(), ..candidate(700, 30, true) };
        let stated = Candidate { name: "release".into(), ..candidate(650, 30, false) };
        let merged = merge_duplicates(vec![guessed, stated]);
        assert_eq!(merged.len(), 1);
        assert!(!merged[0].assume_batch);
    }

    /// The pool has to hold everything `resolve` can reach -- the two it races
    /// plus the two it keeps as sequential fallbacks -- before more querying
    /// is pointless. Stopping earlier trades the fallbacks for a round-trip,
    /// and a swarm that turns out to be dead then has nothing behind it.
    #[test]
    fn the_early_stop_leaves_resolve_its_fallbacks() {
        let strong = || candidate(700, 30, false);
        // Merely viable: reachable as a fallback, not worth racing.
        let viable = || candidate(450, 30, true);
        // Two strong ones to race, but nothing behind them if both swarms
        // turn out to be dead.
        assert!(!enough_candidates(&[strong(), strong()]));
        // Four reachable candidates, two of them worth racing: the shortlist
        // `resolve` slices is full and another Nyaa round would only lengthen
        // a list it never reads.
        assert!(enough_candidates(&[strong(), strong(), viable(), viable()]));
        // A full shortlist of guesses is not a head start.
        assert!(!enough_candidates(&[strong(), viable(), viable(), viable()]));
        // A near-dead swarm is reachable but not worth counting on: it is the
        // case `resolve` pays a whole pre-buffer timeout to discover.
        assert!(!enough_candidates(&[strong(), strong(), candidate(700, 1, false), candidate(100, 30, false)]));
    }

    /// Asking for a dub must not sink a show that has none below the bars
    /// that decide whether the search stops and whether a release is worth
    /// racing -- the penalty exists to order dubs above subs, and with no dub
    /// present it lands on every candidate equally and orders nothing.
    #[test]
    fn a_dub_preference_costs_nothing_on_a_show_with_no_dub() {
        let subs_only = "[ASW] Some Show - 05 [1080p]";
        let siblings = NO_SIBLINGS;
        let alts: Vec<String> = vec![normalize("some show")];
        let crit = |prefer_dub: bool| ReleaseCriteria {
            episode: 5,
            allow_episodeless: false,
            prefer_dub,
            browser_client: false,
            extras: false,
            episode_count: None,
        };
        let scored = |prefer_dub: bool| {
            score_release(subs_only, &normalize("some show"), &alts, &siblings, crit(prefer_dub))
                .expect("the release matches the title either way")
                .0
        };
        assert_eq!(
            scored(true) + NON_DUB_PENALTY,
            scored(false),
            "the whole difference must be the refundable penalty, so find_candidates can undo it"
        );
    }

    /// The mirror case, and the one that actually reached a viewer: a
    /// dub-only release is not a substitute for the sub that was asked for,
    /// while a dual-audio release satisfies either preference.
    #[test]
    fn an_english_only_release_is_not_offered_to_someone_watching_subbed() {
        assert!(is_dub_only_release(&normalize("[Yameii] Some Show - 05 [English Dub]")));
        assert!(is_dub_only_release(&normalize("Some.Show.S01E05.DUBBED.1080p")));
        assert!(!is_dub_only_release(&normalize("[EMBER] Some Show S01E05 [Dual Audio]")));
        assert!(!is_dub_only_release(&normalize("[ASW] Some Show - 05 [1080p]")));
        // Still counts as a dub for someone who asked for one.
        assert!(is_dub_release(&normalize("[Yameii] Some Show - 05 [English Dub]")));
        assert!(is_dub_release(&normalize("[EMBER] Some Show S01E05 [Dual Audio]")));
    }

    /// AnimeTosho lists a single-file torrent's `torrent_name` as the file
    /// itself; Nyaa lists the same release without the extension, and an
    /// unstripped "mkv" token survives `normalize` and defeats the merge.
    #[test]
    fn a_release_and_its_filename_are_the_same_release() {
        assert_eq!(
            normalize(strip_container_ext("[ASW] Some Show - 05 [1080p].mkv")),
            normalize("[ASW] Some Show - 05 [1080p]")
        );
    }

    #[test]
    fn only_healthy_episode_stating_releases_stop_the_search_early() {
        // Exact episode, well seeded: the case the early exit exists for.
        assert!(is_strong(&candidate(1000, 50, false)));
        // Exactly on both bars.
        assert!(is_strong(&candidate(600, LOW_SEEDER_THRESHOLD, false)));
        // A release whose episode is only an assumption is not evidence the
        // search is done — try_candidate may yet reject it for not containing
        // the episode at all.
        assert!(!is_strong(&candidate(1400, 50, true)));
        // Below the probably-dead seeder line: it would cost the peer grace
        // and pre-buffer budget before failing, which is what the remaining
        // rounds exist to avoid.
        assert!(!is_strong(&candidate(1400, LOW_SEEDER_THRESHOLD - 1, false)));
        // Browser-incompatible: penalized by 1200, so even a saturated exact
        // match lands far under the bar and can never end the search.
        assert!(!is_strong(&candidate(
            1000 + TRUSTED_BONUS + seeder_score(400) - BROWSER_INCOMPATIBLE_PENALTY,
            400,
            false
        )));
    }

    /// Criteria for an mpv-bound resolve, which is what every pre-existing
    /// ordering assertion below was written against — mpv decodes everything,
    /// so no codec penalty applies and the tiers behave as they always did.
    fn crit(episode: i64, allow_episodeless: bool, prefer_dub: bool) -> ReleaseCriteria {
        ReleaseCriteria {
            episode,
            allow_episodeless,
            prefer_dub,
            browser_client: false,
            extras: false,
            episode_count: None,
        }
    }

    /// The same, bound for a browser `<video>` element.
    fn crit_browser(episode: i64, allow_episodeless: bool, prefer_dub: bool) -> ReleaseCriteria {
        ReleaseCriteria {
            episode,
            allow_episodeless,
            prefer_dub,
            browser_client: true,
            extras: false,
            episode_count: None,
        }
    }

    #[test]
    fn ova_and_shorts_aliases_match_their_own_relative_episode_range() {
        // A batch release naming an OVA/shorts entry by an absolute S00E11-E16
        // range, with the recognisable alias buried in a pipe-separated title
        // and trailed by its own relative episode range "1-6" (from "1-6").
        // Regression coverage for two bugs found together: `season_of` read a
        // trailing "1 6" pair as "season 6" (only the second of two adjacent
        // bare numbers is ever a season), and `strip_season_marker` popped
        // that same trailing "6" off an alias segment, leaving a lone "1"
        // that the title/episode-range heuristic then rejected on its own.
        let name = "[uba] Love, Chunibyo & Other Delusions! - S00E11-E16 - Heart Throb Lite Shorts (BD Remux 1080p AVC FLAC 2.0) | Chuunibyou demo Koi ga Shitai! Ren Lite | Chunibyo Lite! 1-6";
        assert!(title_matches(&normalize("Chunibyo Lite"), name));
        assert!(title_matches(&normalize("Heart Throb Lite"), name));
        assert!(title_matches(&normalize("Chuunibyou demo Koi ga Shitai! Ren Lite"), name));
    }

    #[test]
    fn browser_codec_markers_are_detected() {
        for name in [
            "[Judas] Show [BD 1080p][HEVC x265 10bit][Dual-Audio]",
            "[Sokudo] Toradora! [1080p BD AV1][dual audio]",
            "[NH] Show - Season 2 (WEB 1080p x265 10-bit)",
            "Show S02 1080p CR WEB-DL MULTi EAC3 H 264",
            "[Group] Show [BD 1080p FLAC]",
            "[Group] Show [1080p Hi10P]",
        ] {
            assert!(
                browser_incompatible_codec(&normalize(name)),
                "should be flagged as browser-incompatible: {}",
                name
            );
        }
        for name in [
            "[SubsPlease] Sousou no Frieren - 05 (1080p) [ABCD1234]",
            "[Erai-raws] Toradora - 01 ~ 25 [1080p]",
            "Show S02E10 1080p CR WEB-DL AAC2.0 H 264-VARYG",
        ] {
            assert!(
                !browser_incompatible_codec(&normalize(name)),
                "should be treated as playable: {}",
                name
            );
        }
        // normalize() maps every non-alphanumeric character to a space, so a
        // marker containing a dot or a hyphen can never match. These two are
        // the forms that only appear punctuated in the wild.
        for name in [
            "[Grp] Show - 05 [1080p H.265]",
            "Show S02E10 1080p WEB-DL E-AC-3 H 264-VARYG",
            "[Grp] Show - 05 [1080p x264 DDP5.1]",
            "[Grp] Show (BD 1080p DTS-HD MA)",
        ] {
            assert!(
                browser_incompatible_codec(&normalize(name)),
                "punctuated marker must survive normalize(): {}",
                name
            );
        }
    }

    #[test]
    fn browser_client_sinks_incompatible_release_below_compatible_batch() {
        let q = normalize("Toradora");
        // Best case for the incompatible release (exact episode) against the
        // worst case for the compatible one (an untagged batch, lowest tier),
        // plus the largest bonuses the incompatible one could pick up. Even
        // then it must lose, or a phone gets handed a stream it cannot decode.
        let (av1_exact, _) =
            score_release("[Grp] Toradora - 13 [1080p AV1]", &q, &[], &NO_SIBLINGS, crit_browser(13, false, false)).unwrap();
        let (h264_batch, _) =
            score_release("[Grp] Toradora [1080p BD]", &q, &[], &NO_SIBLINGS, crit_browser(13, false, false)).unwrap();
        assert!(
            av1_exact + TRUSTED_BONUS + seeder_score(SEEDER_SATURATION) < h264_batch,
            "AV1 exact ({}) must sink below H.264 batch ({}) even fully bonused",
            av1_exact,
            h264_batch
        );
    }

    #[test]
    fn mpv_client_is_unaffected_by_codec() {
        // mpv decodes all of these, so the penalty must not apply and the
        // exact-episode tier must still win.
        let q = normalize("Toradora");
        let (av1_exact, _) =
            score_release("[Grp] Toradora - 13 [1080p AV1]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        let (h264_exact, _) =
            score_release("[Grp] Toradora - 13 [1080p]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        assert_eq!(av1_exact, h264_exact);
    }

    #[test]
    fn browser_penalty_never_rejects_outright() {
        // When nothing compatible exists, the incompatible release is still
        // the best on offer and must remain selectable — scores are compared,
        // never thresholded.
        let q = normalize("Toradora");
        assert!(
            score_release("[Grp] Toradora - 13 [1080p HEVC 10bit]", &q, &[], &NO_SIBLINGS, crit_browser(13, false, false))
                .is_some()
        );
    }

    #[test]
    fn season1_query_rejects_r2_release() {
        // "Code Geass" (S1 query, no marker) must not match a season-2
        // ("R2") release just because the episode number lines up — R1/R2
        // is Code Geass fansub shorthand for "Rebellion 1/2", not caught by
        // the S2/"season 2"/"2nd season" patterns alone.
        // Raw names, not normalized ones: `title_matches` segments on the
        // punctuation release groups use, which normalize() flattens away.
        let query = normalize("Code Geass");
        assert!(title_matches(&query, "Code Geass - 11 [Group] 1080p"));
        assert!(!title_matches(&query, "Code Geass R2 - 11 [Group] 1080p"));
    }

    /// Real release names observed on nyaa.si, kept as a regression set.
    /// Title matching is the highest-blast-radius rule in this file: too loose
    /// and you watch the wrong show, too strict and a show stops working
    /// entirely, and neither shows up until someone presses play.
    #[test]
    fn a_one_word_title_does_not_match_unrelated_shows() {
        let q = normalize("Monster");
        // Every one of these outranked the real 2004 series, because the word
        // is present in each — just not as the show's name.
        for wrong in [
            "[SubsPlease] Monogatari Series - Off & Monster Season - 03 (1080p)",
            "[SubsPlease] Re Monster - 03v2 (1080p) [F6A81A26].mkv",
            "[Erai-raws] S-Rank Monster no -Behemoth- dakedo, Neko to Machigawarete - 03 [1080p]",
            "[Erai-raws] Re-Monster - 03 [1080p][Multiple Subtitle]",
            "[Group] Pocket Monsters - 03 [1080p]",
            "[Group] Monster Musume no Iru Nichijou - 03 [1080p]",
        ] {
            assert!(!title_matches(&q, wrong), "must not match: {}", wrong);
        }
        for right in [
            "[Group] Monster - 03 [1080p]",
            "[Group] Monster (01-74) [1080p] (Batch)",
            "[Group] Monster [BD 1080p][Dual Audio]",
        ] {
            assert!(title_matches(&q, right), "must match: {}", right);
        }
    }

    /// The "Rich Girl Caretaker" case: every group on the show writes
    /// `Title SxxEyy 1080p CR WEB-DL ...` with no separator between the title
    /// and the tags, so the release name arrives as a single segment and used
    /// to be rejected wholesale.
    #[test]
    fn glued_sxxeyy_naming_matches_and_still_respects_the_season() {
        let q = normalize("Rich Girl Caretaker");
        for right in [
            "[ToonsHub] Rich Girl Caretaker S01E06 1080p CR WEB-DL AAC2.0 H.264 (Multi-Subs)",
            "[BlackRose] Rich Girl Caretaker - S01E06 (WEB 1080p HEVC 10-bit EAC-3) | Saijo no Osewa",
            "Rich Girl Caretaker S01E06 1080p CR WEB-DL AAC2.0 H.264-VARYG (Multi-Subs)",
        ] {
            assert!(title_matches(&q, right), "must match: {}", right);
        }
        // The season still has to line up. Nothing else in the name states it,
        // so if `s02e06` isn't read as season 2 this release answers a
        // season-1 query and the user watches the wrong show.
        assert!(!title_matches(&q, "[ToonsHub] Rich Girl Caretaker S02E06 1080p WEB-DL"));
        // And a different show is still a different show: the episode marker
        // ends the title, it does not excuse the tokens ahead of it.
        assert!(!title_matches(&normalize("Monster"), "[G] Monster Hunter S01E06 1080p WEB-DL"));
    }

    #[test]
    fn a_subtitled_title_yields_the_short_form_release_groups_use() {
        assert_eq!(
            short_title("Rich Girl Caretaker: I'm Secretly the Caregiver of the Most Popular Girl"),
            Some("Rich Girl Caretaker".to_string())
        );
        // No subtitle, nothing to shorten.
        assert_eq!(short_title("Sousou no Frieren"), None);
        // A one-word head is too weak a query to spend a round-trip on.
        assert_eq!(
            short_title("Monster: A Subtitle Long Enough To Otherwise Qualify Here"),
            None
        );
        // A short subtitle names a sequel, arc or cour, and release groups keep
        // it. Dropping it would query the first season, which has the same
        // episode numbers and would silently win.
        for sequel in [
            "Kaguya-sama wa Kokurasetai: Ultra Romantic",
            "Kimetsu no Yaiba: Yuukaku-hen",
            "Sword Art Online: Alicization",
            "Fate/stay night: Unlimited Blade Works",
        ] {
            assert_eq!(short_title(sequel), None, "must not shorten: {}", sequel);
        }
    }

    /// A dash inside a title, which release groups use as freely as they use
    /// one before the episode number. Splitting on it blindly broke both
    /// directions at once: the queried entry went unfound because its title
    /// only ever existed as two adjacent chunks, and a longer-titled entry --
    /// a different cour, with its own episode 6 -- was accepted in its place.
    #[test]
    fn a_dash_inside_a_title_neither_hides_it_nor_matches_a_longer_one() {
        let alicization = normalize("Sword Art Online: Alicization");
        let war = normalize("Sword Art Online: Alicization - War of Underworld");

        let a_release = "[HorribleSubs] Sword Art Online - Alicization - 06 [1080p].mkv";
        let w_release = "[HorribleSubs] Sword Art Online - Alicization - War of Underworld - 06 [1080p].mkv";
        let w_release_glued = "[Erai-raws] Sword Art Online Alicization - War of Underworld 2nd Season - 06 [1080p]";

        assert!(title_matches(&alicization, a_release));
        assert!(!title_matches(&alicization, w_release));
        assert!(!title_matches(&alicization, w_release_glued));
        assert!(title_matches(&war, w_release));
        assert!(!title_matches(&war, a_release));

        // Same shape one franchise over: the arcs are separate AniList entries
        // and a query for the first season must not take one of them.
        let s1 = normalize("Kimetsu no Yaiba");
        for arc in [
            "[SubsPlease] Kimetsu no Yaiba - Yuukaku-hen - 06 (1080p)",
            "[SubsPlease] Kimetsu no Yaiba - Hashira Geiko-hen - 06 (1080p) [A994EC11].mkv",
        ] {
            assert!(!title_matches(&s1, arc), "must not match: {}", arc);
        }
        assert!(title_matches(
            &normalize("Kimetsu no Yaiba: Yuukaku-hen"),
            "[SubsPlease] Kimetsu no Yaiba - Yuukaku-hen - 06 (1080p)"
        ));
    }

    #[test]
    fn alternate_titles_and_suffixes_still_match() {
        // Anchoring the query at a segment start must not break the many
        // legitimate namings that put something else first, or trail the title
        // with season/format noise.
        let k = normalize("Koe no Katachi");
        for name in [
            "[Judas] Koe no Katachi (A Silent Voice) [BD 1080p][HEVC x265 10bit][Dual-Audio]",
            "[Okay-Subs] A Silent Voice (BD 1080p) | Koe no Katachi",
        ] {
            assert!(title_matches(&k, name), "must match: {}", name);
        }
        // A dash before the English title is an alias, not a continuation, and
        // only AniList knows which — with the entry's other titles in hand it
        // matches; without them the release is (correctly) treated as naming a
        // longer title than the query.
        let aliased = "[35mm] Koe no Katachi - A Silent Voice [1080p] [B9471AD7].mkv";
        let alts = vec![normalize("Koe no Katachi"), normalize("A Silent Voice")];
        assert!(title_matches_with_alts(&k, aliased, &alts));
        assert!(!title_matches(&k, aliased));

        let t = normalize("Toradora!");
        for name in [
            "[Erai-raws] Toradora - 01 ~ 25 [1080p][Multiple Subtitle]",
            "[Sokudo] Toradora! [1080p BD AV1][dual audio]",
            "[DragsterPS] Toradora! S01 [1080p] [English-Japanese Audio] [Multi-Subs]",
        ] {
            assert!(title_matches(&t, name), "must match: {}", name);
        }

        let f = normalize("Fate/Zero");
        for name in [
            "[HorribleSubs] Fate Zero (01-25) [1080p] (Batch)",
            "[MiniMTBB] Fate/Zero (BD 1080p)",
            "[Tenrai-Sensei] Fate Zero + OVAs + Fate Remix I, Ii [BD][1080p][HEVC 10bit]",
        ] {
            assert!(title_matches(&f, name), "must match: {}", name);
        }

        let ko = normalize("K-On!");
        assert!(title_matches(&ko, "[Anime Time] K-On! [Complete Series] (Season 01 + Season 02 + Movie)"));
        assert!(title_matches(&ko, "[MTBB] K-ON! S1 (BD 1080p)"));
    }

    #[test]
    fn roman_and_bare_numeral_sequels_line_up_with_release_naming() {
        // AniList writes "Mob Psycho 100 II"; release groups write "S2". Both
        // must resolve to the same season or the show returns no candidates.
        assert_eq!(season_of(&normalize("Mob Psycho 100 II")), 2);
        assert_eq!(season_of(&normalize("Mob Psycho 100 S2")), 2);
        assert_eq!(season_of(&normalize("Ashita no Joe 2")), 2);
        // A three-digit number in a title is not a season.
        assert_eq!(season_of(&normalize("Mob Psycho 100")), 1);
        // Nor is a season-1 marker, explicit or absent.
        assert_eq!(season_of(&normalize("Toradora")), 1);

        let q = normalize("Mob Psycho 100 II");
        assert!(title_matches(&q, "[SubsPlease] Mob Psycho 100 S2 - 05 (1080p)"));
        assert!(title_matches(&q, "[Group] Mob Psycho 100 II - 05 [1080p]"));
        // Title and season in separate segments: the season still counts.
        assert!(title_matches(&q, "[derp] Mob Psycho 100 - Season 2 (S02) (BD 1080p HEVC Opus)"));
        // Season 1 must not answer a season 2 query.
        assert!(!title_matches(&q, "[Group] Mob Psycho 100 - 05 [1080p]"));
        assert!(!title_matches(&q, "[derp] Mob Psycho 100 - Season 1 (S01) (BD 1080p)"));
    }

    #[test]
    fn a_numbered_sequel_is_not_the_same_show() {
        // "Steins;Gate 0" is a different series, not a season of "Steins;Gate",
        // and it outranked the real show for every episode query.
        let q = normalize("Steins;Gate");
        assert!(!title_matches(&q, "[HorribleSubs] Steins Gate 0 - 12 [1080p].mkv"));
        assert!(title_matches(&q, "[HorribleSubs] Steins;Gate - 12 [1080p].mkv"));
        assert!(title_matches(&q, "[Group] Steins;Gate (01-24) [1080p]"));
        // The reverse query must find its own show and not the original.
        let z = normalize("Steins;Gate 0");
        assert!(title_matches(&z, "[HorribleSubs] Steins Gate 0 - 12 [1080p].mkv"));
    }

    #[test]
    fn an_alternate_title_cannot_override_the_primary_ones_season() {
        // K-On!! (season 2) normalizes to the same tokens as K-On! (season 1)
        // once punctuation is gone, so a season-2 release carrying it as an
        // alternate title answered a season-1 query — and the episode-file
        // check cannot catch that, since season 2 has an episode 5 as well.
        let q = normalize("K-On!");
        assert!(!title_matches(&q, "[MTBB] K-ON! S2 (BD 1080p) | K-ON!!"));
        assert!(title_matches(&q, "[MTBB] K-ON! S1 (BD 1080p)"));
        // An alternate title still works when the primary doesn't match.
        let k = normalize("Koe no Katachi");
        assert!(title_matches(&k, "[Okay-Subs] A Silent Voice (BD 1080p) | Koe no Katachi"));
    }

    #[test]
    fn an_episode_number_is_never_read_as_a_season() {
        // The trailing-digit rule is only safe because segmentation puts the
        // episode in a segment of its own before season_of ever sees it — and
        // because a lone number can never stand in as a season segment, which
        // would otherwise reject every episode past the first.
        let q = normalize("Toradora");
        assert!(title_matches(&q, "[Group] Toradora - 05 [1080p]"));
        assert!(title_matches(&q, "[Group] Toradora - 12 [1080p]"));
        assert!(title_matches(&q, "[Group] Toradora - 25 [1080p]"));
        assert!(!is_pure_season_segment("25"));
        assert!(is_pure_season_segment("season 2"));
        assert!(is_pure_season_segment("s02"));
        let f = normalize("Sousou no Frieren");
        assert!(title_matches(&f, "[SubsPlease] Sousou no Frieren - 05 (1080p) [8E3F8FA5].mkv"));
    }

    #[test]
    fn a_film_ranks_below_the_series_for_a_numbered_episode() {
        // A film shares the series name and matches legitimately, but cannot
        // contain episode 5 — it should not consume a candidate slot ahead of
        // releases that can.
        let q = normalize("K-On!");
        let (film, _) = score_release("[MTBB] K-ON! the Movie (2011) (BD 1080p)", &q, &[], &NO_SIBLINGS, crit(5, false, false)).unwrap();
        let (series, _) = score_release("[MTBB] K-ON! S1 (BD 1080p)", &q, &[], &NO_SIBLINGS, crit(5, false, false)).unwrap();
        assert!(series > film);
        // For an actual film lookup (allow_episodeless), no penalty applies.
        let kk = normalize("Koe no Katachi");
        let (movie_ok, _) = score_release("[Judas] Koe no Katachi (A Silent Voice) [BD 1080p]", &kk, &[], &NO_SIBLINGS, crit(1, true, false)).unwrap();
        assert!(movie_ok > 0);
    }

    #[test]
    fn e_prefixed_ranges_parse_as_ranges_not_as_their_first_episode() {
        // A BD batch split into parts is routinely labelled this way. Read as
        // an exact episode it matched only its own first episode and was
        // rejected for the other nineteen it actually contains.
        let s = strip_noise("[sam] Hunter x Hunter (2011) Season 1 (S01) (E039-E058) (BD 1080p)");
        assert_eq!(parse_episode(&s).1, Some((39.0, 58.0)));
        assert_eq!(parse_episode(&strip_noise("[G] Show (EP01-EP12) [1080p]")).1, Some((1.0, 12.0)));
        // A single episode marker must still read as exact, not as a range.
        assert_eq!(parse_episode(&strip_noise("[G] Show E05 [1080p]")).0, Some(5.0));
        assert_eq!(parse_episode(&strip_noise("Show S01E12 1080p WEBRip.mkv")).0, Some(12.0));
    }

    #[test]
    fn a_range_is_found_past_an_earlier_false_positive() {
        // Observed live: this 49-seeder batch of the whole cour was parsed as
        // *exactly* episode 1, because "Part 2 - 01" matches the range pattern
        // before the real "01 ~ 12" does, fails a<b, and used to end the search.
        let s = strip_noise("[Erai-raws] 86 Eighty-Six Part 2 - 01 ~ 12 [1080p][BATCH][Multiple Subtitle]");
        assert_eq!(parse_episode(&s), (None, Some((1.0, 12.0))));
        let q = normalize("86: Eighty Six Part 2");
        for ep in [1, 2, 7, 12] {
            assert!(
                score_release(
                    "[Erai-raws] 86 Eighty-Six Part 2 - 01 ~ 12 [1080p][BATCH][Multiple Subtitle]",
                    &q, &[], &NO_SIBLINGS, crit(ep, false, false)).is_some(),
                "episode {} must match the batch containing it", ep
            );
        }
        // Outside the stated range it must still be rejected.
        assert!(score_release(
            "[Erai-raws] 86 Eighty-Six Part 2 - 01 ~ 12 [1080p][BATCH]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).is_none());
    }

    #[test]
    fn absolute_numbering_maps_a_split_cour_episode_to_its_file() {
        // "86 Part 2" is a 12-episode AniList entry shipped as files 12-23.
        let files: Vec<i64> = (12..=23).collect();
        let n = Some(12);
        assert_eq!(absolute_episode(&files, 1, n), Some(12));
        assert_eq!(absolute_episode(&files, 2, n), Some(13));
        // The case a literal filename match gets wrong: file "12" exists, but
        // it is this entry's episode 1, not its episode 12.
        assert_eq!(absolute_episode(&files, 12, n), Some(23));
        // Past the end of the season there is nothing to map to.
        assert_eq!(absolute_episode(&files, 13, n), None);

        // Same files, but the entry is the whole 23-episode series: this is a
        // partial batch, not an absolutely-numbered cour, so episode numbers
        // must be taken at face value.
        assert_eq!(absolute_episode(&files, 12, Some(23)), None);
        // An unknown episode count is never enough to justify remapping.
        assert_eq!(absolute_episode(&files, 2, None), None);

        // A release numbering from 1 has no offset, so a missing episode has to
        // stay missing rather than silently resolving to the wrong file.
        let from_one: Vec<i64> = (1..=12).collect();
        assert_eq!(absolute_episode(&from_one, 20, n), None);
        // Gaps mean the run isn't a clean season; refuse to guess.
        assert_eq!(absolute_episode(&[12, 13, 15, 16], 2, Some(4)), None);
        assert_eq!(absolute_episode(&[12], 1, Some(1)), None);
    }

    #[test]
    fn filename_season_reads_the_explicit_marker_and_nothing_else() {
        // The two files that actually collided in the EMBER batch: same
        // literal episode number, disambiguated only by folder + SxxExx tag.
        assert_eq!(
            filename_season("Season 1/[EMBER] Shinmai Maou no Testament - S01E01.mkv"),
            Some(1)
        );
        assert_eq!(
            filename_season("Season 2/[EMBER] Shinmai Maou no Testament - S02E01.mkv"),
            Some(2)
        );
        // No marker at all means "unknown", not "season 1" — a file like
        // this must never be excluded just for lacking a tag.
        assert_eq!(filename_season("[SubsPlease] Frieren - 05 (1080p).mkv"), None);
    }

    #[test]
    fn multi_season_batch_flags_combined_season_packs() {
        // The exact release that mapped season 1 episode 1 to season 2's
        // episode 1: a 12-episode-per-season show packed as one torrent,
        // whose files happen to number 13-24 for season 2 — a span that
        // coincidentally matches season 1's own episode_count of 12, so
        // absolute_episode would otherwise misfire on it.
        let name = normalize(
            "[EMBER] The Testament of Sister New Devil (2015-2016) (Season 1+2+OVA) (Uncensored) [BDRip] [1080p Dual Audio HEVC 10 bits] (Shinmai Maou no Testament)",
        );
        assert!(multi_season_batch(&name));
        assert!(multi_season_batch(&normalize("Show S1+S2 Batch [1080p]")));

        // A normal single-season release must not be flagged.
        assert!(!multi_season_batch(&normalize("[Chihiro] Shinmai Maou no Testament [Blu-ray 1080p Hi10P FLAC]")));
        assert!(!multi_season_batch(&normalize("Show Season 2 [1080p][BATCH]")));
    }

    #[test]
    fn a_bracketed_range_survives_noise_stripping() {
        // Release naming doesn't agree on which punctuation wraps the range.
        // "(01-25)" always parsed; "[01-25]" was deleted with the group tags
        // before parse_episode saw it, so the release read as episode-less.
        assert_eq!(parse_episode(&strip_noise("[Grp] Toradora! [BD 1080p][01-25]")).1, Some((1.0, 25.0)));
        assert_eq!(parse_episode(&strip_noise("[Grp] Toradora! (01-25) [1080p]")).1, Some((1.0, 25.0)));
        // Group tags and CRC hashes still must not read as episode numbers.
        assert_eq!(parse_episode(&strip_noise("[SubsPlease] Show [1080p][B7F32C9A].mkv")), (None, None));
    }

    #[test]
    fn an_untagged_batch_is_accepted_but_ranked_below_explicit_ones() {
        let q = normalize("Toradora");
        // The shape most back-catalog BD releases use: no episode info at all.
        // Rejecting these is what left a finished show with three candidates
        // when the site had a dozen.
        let (untagged, assume_batch) =
            score_release("[Sokudo] Toradora! [1080p BD AV1][dual audio]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        assert!(assume_batch);
        let (explicit, explicit_batch) =
            score_release("[Erai-raws] Toradora - 01 ~ 25 [1080p]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        assert!(!explicit_batch);
        assert!(explicit > untagged, "a release that states its range must outrank an assumed one");
    }

    #[test]
    fn seven_twenty_is_accepted_but_never_outranks_ten_eighty() {
        let q = normalize("Toradora");
        let (hd, _) = score_release("[Erai-raws] Toradora - 01 ~ 25 [1080p]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        let (sd, _) = score_release("[Erai-raws] Toradora - 01 ~ 25 [720p]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        assert!(sd < hd);
        // The seeder bonus saturates below SD_PENALTY, so it can never promote
        // a 720p release over the same release in 1080p.
        assert!(
            seeder_score(SEEDER_SATURATION) < SD_PENALTY,
            "SD_PENALTY must exceed the maximum seeder bonus"
        );
        assert!(sd + seeder_score(SEEDER_SATURATION) < hd);
        // Anything below 720p is still rejected outright.
        assert!(score_release("[Grp] Toradora - 01 ~ 25 [480p DVD]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).is_none());
    }

    #[test]
    fn seeder_score_separates_dead_swarms_from_live_ones() {
        // The low end is what decides whether a stream plays, so that is where
        // the curve has to be steep. The old linear seeders/3 gave 2 and 20
        // seeders a 6-point spread — noise against a 300-point tier gap.
        assert!(seeder_score(20) - seeder_score(2) > 50);
        // The high end is where it should stop mattering.
        assert!(seeder_score(400) - seeder_score(200) < 110);
        assert_eq!(seeder_score(0), 0);
        // Saturates rather than growing without bound.
        assert_eq!(seeder_score(SEEDER_SATURATION), seeder_score(SEEDER_SATURATION * 10));
    }

    #[test]
    fn a_healthy_assumed_batch_outranks_a_near_dead_explicit_one() {
        // The Toradora case: a 2-seeder release that names its episode range
        // used to beat a 52-seeder BD batch that doesn't, because the range
        // tier plus the trusted flag together outweighed everything about
        // whether either would actually download.
        let q = normalize("Toradora");
        let (dead_base, _) =
            score_release("[HorribleSubs] Toradora! (DUB) (01-25) [1080p] (Batch)", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        let dead = dead_base + TRUSTED_BONUS + seeder_score(2) - DEAD_SWARM_PENALTY;

        let (live_base, assumed) =
            score_release("[Sokudo] Toradora! [1080p BD AV1][dual audio]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        let live = live_base + seeder_score(52);

        assert!(assumed);
        assert!(live > dead, "healthy batch {} must outrank near-dead {}", live, dead);
    }

    #[test]
    fn a_healthy_exact_episode_still_wins_outright() {
        // Reweighting viability must not let a batch displace a healthy
        // release that names the exact episode — that ordering is correctness,
        // not preference.
        let q = normalize("Show");
        let (exact, _) = score_release("[Grp] Show - 13 [1080p]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        let (batch, _) = score_release("[Grp] Show [1080p BD]", &q, &[], &NO_SIBLINGS, crit(13, false, false)).unwrap();
        assert!(exact + seeder_score(20) > batch + seeder_score(SEEDER_SATURATION));
    }

    #[test]
    fn search_query_drops_punctuation_but_keeps_words_and_hyphens() {
        // AniList's romaji is the punctuated form, and Nyaa's search takes the
        // query literally — "Toradora!" returned about half what "Toradora" did.
        assert_eq!(search_query_form("Toradora!"), "Toradora");
        assert_eq!(search_query_form("Fate/Zero"), "Fate Zero");
        assert_eq!(search_query_form("Re:Zero kara Hajimeru"), "Re Zero kara Hajimeru");
        // The hyphen carries meaning in the "Title - 05" convention.
        assert_eq!(search_query_form("Kimetsu-no-Yaiba"), "Kimetsu-no-Yaiba");
    }

    #[test]
    fn r2_query_matches_r2_release_only() {
        let query = normalize("Code Geass R2");
        assert!(title_matches(&query, "Code Geass R2 - 11 [Group] 1080p"));
        assert!(!title_matches(&query, "Code Geass - 11 [Group] 1080p"));
    }
}



#[cfg(test)]
mod extras_tests {
    use super::*;

    /// The two real specials releases for "The Testament of Sister New Devil",
    /// scored against the two real AniList specials entries. Each release
    /// states the range the *franchise* numbers its specials by ("S00E03-E08",
    /// "S00E09-E13") while AniList numbers each collection from 1, so a
    /// literal range check rejects every episode of both.
    /// The franchise's other AniList entries, as `relations` hands them back.
    const FRANCHISE: &[&str] = &[
        "Shinmai Maou no Testament",
        "Shinmai Maou no Testament Burst",
        "Shinmai Maou no Testament Specials",
        "Shinmai Maou no Testament Burst Specials",
        "Shinmai Maou no Testament Departures",
        "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou",
    ];

    #[test]
    fn a_release_that_qualifies_its_ova_names_which_ova_it_is() {
        // AniList relates the season 1 OVA to the two TV seasons and to
        // nothing else, so Departures is three hops away and `names_a_sibling`
        // cannot see it. The release name can: "- OVA Departures" says which
        // OVA it is, in a word this entry's titles never use.
        let own: Vec<String> = vec![
            "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou".into(),
            "Shinmai Maou no Testament OVA".into(),
        ];
        assert!(names_an_unrelated_extra(
            "[Anime Time] The Testament Of Sister New Devil (Shinmai Maou no Testament) - OVA Departures [1080p][HEVC 10bit x265][AAC][Multi-Subs].mkv",
            &own
        ));

        // Everything that legitimately carries this OVA must survive. A pack
        // listing its contents ("Season 1+2+OVA", "Complete Series+OVAs+
        // Specials") names no particular extra; a group signing an
        // underscore-separated name ("OAD_BD720p_10bit_SmoodFlamez") is not
        // qualifying anything; and a release of this OVA itself qualifies it
        // with words the entry does use.
        for name in [
            "[EMBER] The Testament of Sister New Devil (2015-2016) (Season 1+2+OVA) (Uncensored) [BDRip] [1080p Dual Audio HEVC 10 bits] (Shinmai Maou no Testament)",
            "[DB] Shinmai Maou no Testament | The Testament of Sister New Devil (Complete Series+OVAs+Specials) (Uncensored) [Dual Audio 10bit BD1080p][HEVC-x265]",
            "Shinmai Maou no Testament Complete Batch  Seasons 1+2 With OVAS+OAD_(BD720p_10bit_SmoodFlamez)",
            "[BKC] Shinmai Maou no Testament OVA | The Testament of Sister New Devil OVA (BD 1080p x264 Hi10P FLAC Dual Audio)",
            "The Testament of Sister New Devil (Shinmai Maou no Testament) (2015) 01-12 + OVA [BD 1080p Hi10P AAC dual-audio][kuchikirukia]",
        ] {
            assert!(!names_an_unrelated_extra(name, &own), "disowned its own release: {}", name);
        }

        // And the Departures entry keeps the release the OVA entry gave up.
        let departures: Vec<String> = vec![
            "Shinmai Maou no Testament Departures".into(),
            "The Testament of Sister New Devil DEPARTURES".into(),
        ];
        assert!(!names_an_unrelated_extra(
            "[Anime Time] The Testament Of Sister New Devil (Shinmai Maou no Testament) - OVA Departures [1080p][HEVC 10bit x265][AAC][Multi-Subs].mkv",
            &departures
        ));
    }

    #[test]
    fn a_release_of_a_sibling_ova_is_not_this_ova() {
        // Every one-episode extra of this franchise is a single-file release
        // whose name contains the series title, so all of them match the OVA
        // entry's title and none of them can be told apart by episode number
        // — there is only ever episode 1. What separates them is the word
        // the other entry owns and this one doesn't.
        let own: Vec<String> = vec![
            "Shinmai Maou no Testament: Toujou Basara no Hard Sweet na Nichijou".into(),
            "Shinmai Maou no Testament OVA".into(),
        ];
        let related: Vec<String> = FRANCHISE.iter().map(|t| t.to_string()).collect();
        let departures = normalize(
            "[Anime Time] The Testament Of Sister New Devil (Shinmai Maou no Testament) - OVA Departures [1080p][HEVC 10bit x265][AAC][Multi-Subs].mkv",
        );
        assert!(names_a_sibling(&departures, &own, &related), "Departures is a different entry");
        let burst_ova = normalize("[Nep_Blanc] Shinmai Maou No Testament BURST OVA [1080p] [x265] [10Bit] [Subbed]");
        assert!(names_a_sibling(&burst_ova, &own, &related), "the Burst OVA is a different entry");

        // This entry's own releases, and the franchise packs that contain it,
        // must survive: "OVAs" and "Specials" say what a pack holds, not
        // which entry it is.
        let ember = normalize(
            "[EMBER] The Testament of Sister New Devil (2015-2016) (Season 1+2+OVA) (Uncensored) [BDRip] [1080p Dual Audio HEVC 10 bits] (Shinmai Maou no Testament)",
        );
        assert!(!names_a_sibling(&ember, &own, &related));
        let db = normalize(
            "[DB] Shinmai Maou no Testament | The Testament of Sister New Devil (Complete Series+OVAs+Specials) (Uncensored) [Dual Audio 10bit BD1080p][HEVC-x265]",
        );
        assert!(!names_a_sibling(&db, &own, &related));
        let own_ova = normalize("[BKC] Shinmai Maou no Testament OVA | The Testament of Sister New Devil OVA (BD 1080p x264 Hi10P FLAC Dual Audio)");
        assert!(!names_a_sibling(&own_ova, &own, &related));

        // And the Departures entry itself must keep its own release.
        let departures_own: Vec<String> = vec![
            "Shinmai Maou no Testament Departures".into(),
            "The Testament of Sister New Devil DEPARTURES".into(),
        ];
        assert!(!names_a_sibling(&departures, &departures_own, &related));
    }

    #[test]
    fn a_specials_release_answers_an_entry_that_numbers_from_one() {
        const KUROMII: &str = "[SCY-Kuromii] The Testament of Sister New Devil (2015) - S00E03-E08 - Specials (BD 1080p x264 10-bit Hi10P FLAC 2.0) | Shinmai Maou no Testament: Loli Ero Succubus Maria no Characommentary Tsuki Hizou Eizou";
        const BURST_SP: &str = "[SCY] The Testament of Sister New Devil (2015) - S00E09-E13 - Burst Specials (BD 1080p x264 10-bit Hi10P FLAC 2.0) | Shinmai Maou no Testament Burst Specials";
        let crit = |episode: i64, count: i64| ReleaseCriteria {
            episode,
            allow_episodeless: false,
            prefer_dub: false,
            browser_client: false,
            extras: true,
            episode_count: Some(count),
        };
        // Scored as the real entries are: with their own titles, which is
        // what `names_an_unrelated_extra` reads to tell "Burst Specials" from
        // "Specials".
        let own_s: Vec<String> = vec![
            "Shinmai Maou no Testament Specials".into(),
            "The Testament of Sister New Devil Specials".into(),
        ];
        let own_b: Vec<String> = vec![
            "Shinmai Maou no Testament Burst Specials".into(),
            "The Testament of Sister New Devil BURST Specials".into(),
        ];
        let sib_s = SiblingTitles { own: &own_s, related: &[] };
        let sib_b = SiblingTitles { own: &own_b, related: &[] };
        let q = normalize("The Testament of Sister New Devil Specials");
        assert!(score_release(KUROMII, &q, &[], &sib_s, crit(1, 6)).is_some(), "six-special entry, episode 1");
        assert!(score_release(KUROMII, &q, &[], &sib_s, crit(6, 6)).is_some(), "six-special entry, episode 6");
        // The other collection is five long *and* qualifies itself as Burst's,
        // a word this entry's titles never use — either one disowns it.
        assert!(score_release(BURST_SP, &q, &[], &sib_s, crit(1, 6)).is_none(), "wrong collection");
        // The Burst collection is reached by its romaji title rather than its
        // English one: the release names the entry as "Shinmai Maou no
        // Testament Burst Specials" in its alias tail and never spells out
        // "The Testament of Sister New Devil BURST" there. Both titles are
        // searched for every entry, so one of them landing is enough — which
        // is also why matching stays anchored rather than being loosened
        // until every spelling hits.
        let qb = normalize("Shinmai Maou no Testament Burst Specials");
        assert!(score_release(BURST_SP, &qb, &[], &sib_b, crit(1, 5)).is_some(), "five-special entry");
        assert!(score_release(KUROMII, &qb, &[], &sib_b, crit(1, 5)).is_none(), "the other collection");
    }
}
