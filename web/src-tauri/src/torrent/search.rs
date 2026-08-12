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
const TRACKERS: &[&str] = &[
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
fn segments(name: &str) -> Vec<String> {
    name.split(['[', ']', '(', ')', '|', '+', '~'])
        .flat_map(|part| part.split(" - "))
        .map(normalize)
        .filter(|s| !s.is_empty())
        .collect()
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
        "complete", "series", "collection", "batch", "tv", "bd", "bdrip", "bluray",
        "remastered", "uncensored", "dual", "audio", "multi", "subs", "subbed", "dubbed",
    ];
    // Bare numbers and "s01"-style markers: part of how a season is written,
    // never part of which show it is.
    t.chars().all(|c| c.is_ascii_digit())
        || (t.starts_with('s') && t.len() <= 3 && t[1..].chars().all(|c| c.is_ascii_digit()))
        || WORDS.contains(&t)
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
    let s: Vec<&str> = segment_base.split(' ').filter(|t| !t.is_empty()).collect();
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
fn title_matches(query_norm: &str, name: &str) -> bool {
    let query_season = season_of(query_norm);
    let segs = segments(name);
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
fn explicit_season(norm: &str) -> Option<u32> {
    let stated = season_of(norm);
    if stated != 1 {
        return Some(stated);
    }
    // Season 1 stated outright, rather than merely unmarked.
    let re = regex_lite::Regex::new(r"\bs0*1\b|\bseason 0*1\b|\b1st season\b").unwrap();
    re.is_match(norm).then_some(1)
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
fn season_of(norm: &str) -> u32 {
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
    if let Some(last) = norm.split(' ').next_back() {
        if let Some(n) = roman_numeral(last) {
            return n;
        }
        if last.len() <= 2 {
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
    let stripped = strip_noise(name);
    match parse_episode(&stripped) {
        (Some(e), _) if e >= 0.0 && e.fract() == 0.0 => Some(e as i64),
        _ => None,
    }
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

/// Score contribution from a swarm's seeder count.
///
/// Square-root rather than linear: the difference between 2 and 20 seeders
/// decides whether a stream plays at all, while the difference between 200 and
/// 400 is invisible to the viewer. A linear `seeders/3` (capped at 100) got
/// this backwards — it was too flat at the low end to separate a dead swarm
/// from a live one, and seeder count is the single strongest predictor of
/// whether a torrent actually starts.
fn seeder_score(seeders: u64) -> i64 {
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
}

/// Score a release name against the wanted episode. None = reject.
fn score_release(
    name: &str,
    query_norm: &str,
    criteria: ReleaseCriteria,
) -> Option<(i64, bool)> {
    let ReleaseCriteria { episode, allow_episodeless, prefer_dub, browser_client } = criteria;
    let name_norm = normalize(name);
    if !title_matches(query_norm, name) {
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
    if prefer_dub && (name_norm.contains("dual audio") || name_norm.contains("dual-audio") || name_norm.contains("english dub")) {
        score += 250;
    }
    if browser_client && browser_incompatible_codec(&name_norm) {
        score -= BROWSER_INCOMPATIBLE_PENALTY;
    }
    Some((score, assume_batch))
}

async fn search_subsplease(
    client: &reqwest::Client,
    title: &str,
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
        if !title_matches(&query_norm, &show_norm) {
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
            // SubsPlease is sub-only; leave the score as-is, Nyaa dual-audio
            // results can outrank it via their own bonus.
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

async fn search_nyaa(
    client: &reqwest::Client,
    query: &str,
    query_title_norm: &str,
    criteria: ReleaseCriteria,
) -> Vec<Candidate> {
    let mut out = vec![];
    let url = format!(
        "https://nyaa.si/?page=rss&c=1_2&f=0&s=seeders&o=desc&q={}",
        urlencoding_encode(query)
    );
    let body = match client.get(&url).send().await {
        Ok(r) => r.text().await.unwrap_or_default(),
        Err(e) => {
            log::warn!("torrent: nyaa search failed: {}", e);
            return out;
        }
    };
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
        let Some((mut score, assume_batch)) = score_release(&name, query_title_norm, criteria) else {
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
            let trackers: String = TRACKERS
                .iter()
                .map(|t| format!("&tr={}", urlencoding_encode(t)))
                .collect();
            Some(format!("magnet:?xt=urn:btih:{}{}", infohash, trackers))
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
pub async fn find_candidates(
    client: &reqwest::Client,
    titles: &[String],
    criteria: ReleaseCriteria,
) -> Vec<Candidate> {
    let episode = criteria.episode;
    let prefer_dub = criteria.prefer_dub;
    let mut all: Vec<Candidate> = vec![];

    // Expand season-naming variants, keep order, dedupe, cap the fan-out.
    let mut expanded: Vec<String> = vec![];
    for t in titles {
        for v in title_variants(t) {
            if !v.trim().is_empty() && !expanded.iter().any(|e| normalize(e) == normalize(&v)) {
                expanded.push(v);
            }
        }
    }
    expanded.truncate(4);

    for title in &expanded {
        all.extend(search_subsplease(client, title, episode, prefer_dub).await);
    }

    for title in &expanded {
        let norm = normalize(title);
        // Nyaa's own full-text search takes the query literally, so title
        // punctuation narrows it. AniList's romaji is the canonical, punctuated
        // form ("Toradora!"), and searching that verbatim returned roughly half
        // the results that the bare word did — releases are named without it.
        // Matching is unaffected either way: `norm` still governs what counts
        // as a hit, and normalize() already discards punctuation.
        let q_title = search_query_form(title);
        let single_q = format!("{} - {:02}", q_title, episode);
        // The per-episode query can never legitimately match an untagged
        // release, so it always scores with allow_episodeless off regardless of
        // what the caller asked for; only the batch query honours it.
        let single = ReleaseCriteria { allow_episodeless: false, ..criteria };
        all.extend(search_nyaa(client, &single_q, &norm, single).await);
        let batch_q = format!("{} 1080p", q_title);
        all.extend(search_nyaa(client, &batch_q, &norm, criteria).await);
    }

    // Dedupe by name, best score wins.
    all.sort_by(|a, b| b.score.cmp(&a.score).then(b.seeders.cmp(&a.seeders)));
    let mut seen = std::collections::HashSet::new();
    all.retain(|c| seen.insert(normalize(&c.name)));
    all
}

fn urlencoding_encode(s: &str) -> String {
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

    /// Criteria for an mpv-bound resolve, which is what every pre-existing
    /// ordering assertion below was written against — mpv decodes everything,
    /// so no codec penalty applies and the tiers behave as they always did.
    fn crit(episode: i64, allow_episodeless: bool, prefer_dub: bool) -> ReleaseCriteria {
        ReleaseCriteria { episode, allow_episodeless, prefer_dub, browser_client: false }
    }

    /// The same, bound for a browser `<video>` element.
    fn crit_browser(episode: i64, allow_episodeless: bool, prefer_dub: bool) -> ReleaseCriteria {
        ReleaseCriteria { episode, allow_episodeless, prefer_dub, browser_client: true }
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
            score_release("[Grp] Toradora - 13 [1080p AV1]", &q, crit_browser(13, false, false)).unwrap();
        let (h264_batch, _) =
            score_release("[Grp] Toradora [1080p BD]", &q, crit_browser(13, false, false)).unwrap();
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
            score_release("[Grp] Toradora - 13 [1080p AV1]", &q, crit(13, false, false)).unwrap();
        let (h264_exact, _) =
            score_release("[Grp] Toradora - 13 [1080p]", &q, crit(13, false, false)).unwrap();
        assert_eq!(av1_exact, h264_exact);
    }

    #[test]
    fn browser_penalty_never_rejects_outright() {
        // When nothing compatible exists, the incompatible release is still
        // the best on offer and must remain selectable — scores are compared,
        // never thresholded.
        let q = normalize("Toradora");
        assert!(
            score_release("[Grp] Toradora - 13 [1080p HEVC 10bit]", &q, crit_browser(13, false, false))
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

    #[test]
    fn alternate_titles_and_suffixes_still_match() {
        // Anchoring the query at a segment start must not break the many
        // legitimate namings that put something else first, or trail the title
        // with season/format noise.
        let k = normalize("Koe no Katachi");
        for name in [
            "[Judas] Koe no Katachi (A Silent Voice) [BD 1080p][HEVC x265 10bit][Dual-Audio]",
            "[35mm] Koe no Katachi - A Silent Voice [1080p] [B9471AD7].mkv",
            "[Okay-Subs] A Silent Voice (BD 1080p) | Koe no Katachi",
        ] {
            assert!(title_matches(&k, name), "must match: {}", name);
        }

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
        let (film, _) = score_release("[MTBB] K-ON! the Movie (2011) (BD 1080p)", &q, crit(5, false, false)).unwrap();
        let (series, _) = score_release("[MTBB] K-ON! S1 (BD 1080p)", &q, crit(5, false, false)).unwrap();
        assert!(series > film);
        // For an actual film lookup (allow_episodeless), no penalty applies.
        let kk = normalize("Koe no Katachi");
        let (movie_ok, _) = score_release("[Judas] Koe no Katachi (A Silent Voice) [BD 1080p]", &kk, crit(1, true, false)).unwrap();
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
                    &q, crit(ep, false, false)).is_some(),
                "episode {} must match the batch containing it", ep
            );
        }
        // Outside the stated range it must still be rejected.
        assert!(score_release(
            "[Erai-raws] 86 Eighty-Six Part 2 - 01 ~ 12 [1080p][BATCH]", &q, crit(13, false, false)).is_none());
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
            score_release("[Sokudo] Toradora! [1080p BD AV1][dual audio]", &q, crit(13, false, false)).unwrap();
        assert!(assume_batch);
        let (explicit, explicit_batch) =
            score_release("[Erai-raws] Toradora - 01 ~ 25 [1080p]", &q, crit(13, false, false)).unwrap();
        assert!(!explicit_batch);
        assert!(explicit > untagged, "a release that states its range must outrank an assumed one");
    }

    #[test]
    fn seven_twenty_is_accepted_but_never_outranks_ten_eighty() {
        let q = normalize("Toradora");
        let (hd, _) = score_release("[Erai-raws] Toradora - 01 ~ 25 [1080p]", &q, crit(13, false, false)).unwrap();
        let (sd, _) = score_release("[Erai-raws] Toradora - 01 ~ 25 [720p]", &q, crit(13, false, false)).unwrap();
        assert!(sd < hd);
        // The seeder bonus saturates below SD_PENALTY, so it can never promote
        // a 720p release over the same release in 1080p.
        assert!(
            seeder_score(SEEDER_SATURATION) < SD_PENALTY,
            "SD_PENALTY must exceed the maximum seeder bonus"
        );
        assert!(sd + seeder_score(SEEDER_SATURATION) < hd);
        // Anything below 720p is still rejected outright.
        assert!(score_release("[Grp] Toradora - 01 ~ 25 [480p DVD]", &q, crit(13, false, false)).is_none());
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
            score_release("[HorribleSubs] Toradora! (DUB) (01-25) [1080p] (Batch)", &q, crit(13, false, false)).unwrap();
        let dead = dead_base + TRUSTED_BONUS + seeder_score(2) - DEAD_SWARM_PENALTY;

        let (live_base, assumed) =
            score_release("[Sokudo] Toradora! [1080p BD AV1][dual audio]", &q, crit(13, false, false)).unwrap();
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
        let (exact, _) = score_release("[Grp] Show - 13 [1080p]", &q, crit(13, false, false)).unwrap();
        let (batch, _) = score_release("[Grp] Show [1080p BD]", &q, crit(13, false, false)).unwrap();
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
