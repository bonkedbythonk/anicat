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

/// Every word of the query title must appear as a whole token in the release
/// name — stops "Monster" matching "Pocket Monsters".
fn title_matches(query_norm: &str, name_norm: &str) -> bool {
    let name_tokens: std::collections::HashSet<&str> = name_norm.split(' ').collect();
    let tokens_ok = query_norm
        .split(' ')
        .all(|t| t.is_empty() || name_tokens.contains(t));
    // Token-subset matching lets "Show S2" match a plain "Show" query; both
    // sides must mean the same season (absent marker = season 1).
    tokens_ok && season_of(query_norm) == season_of(name_norm)
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
    1
}

/// Strip tokens that look like episode numbers but aren't (resolution, codec,
/// bit depth, years, CRC groups) before trying to parse an episode number.
fn strip_noise(name: &str) -> String {
    let mut s = String::with_capacity(name.len());
    // Drop bracketed groups entirely: [SubsPlease], [B7F32C9A]. Parenthesized
    // chunks stay because episode ranges like (01-28) live in them.
    let mut depth: i32 = 0;
    for c in name.chars() {
        match c {
            '[' => depth += 1,
            ']' => depth = (depth - 1).max(0),
            _ if depth == 0 => s.push(c),
            _ => {}
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
    // Batch range: "01-28", "01 ~ 28", "(01-10)"
    let range_re = regex_lite::Regex::new(r"\b(\d{1,4}(?:\.\d)?)\s*[-~]\s*(\d{1,4}(?:\.\d)?)\b").unwrap();
    if let Some(c) = range_re.captures(name) {
        let a: f64 = c[1].parse().unwrap_or(0.0);
        let b: f64 = c[2].parse().unwrap_or(0.0);
        if a < b && b - a <= 600.0 && b <= 3000.0 {
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
    let stripped = strip_noise(name);
    match parse_episode(&stripped) {
        (Some(e), _) => (e - episode as f64).abs() < 0.01,
        _ => false,
    }
}

fn minimal_unescape(s: &str) -> String {
    s.replace("&amp;", "&")
        .replace("&#39;", "'")
        .replace("&quot;", "\"")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
}

/// Score a release name against the wanted episode. None = reject.
fn score_release(
    name: &str,
    query_norm: &str,
    episode: i64,
    allow_episodeless: bool,
    prefer_dub: bool,
) -> Option<i64> {
    let name_norm = normalize(name);
    if !title_matches(query_norm, &name_norm) {
        return None;
    }
    if !name_norm.contains("1080") {
        return None;
    }
    let stripped = strip_noise(name);
    let (exact, range) = parse_episode(&stripped);
    let ep = episode as f64;
    let mut score = match (exact, range) {
        (Some(e), _) if (e - ep).abs() < 0.01 => 1000,
        (None, Some((a, b))) if ep >= a && ep <= b => 600,
        (None, None) if allow_episodeless => 400,
        _ => return None,
    };
    if prefer_dub && (name_norm.contains("dual audio") || name_norm.contains("dual-audio") || name_norm.contains("english dub")) {
        score += 250;
    }
    Some(score)
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
    episode: i64,
    allow_episodeless: bool,
    prefer_dub: bool,
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
        let Some(mut score) = score_release(&name, query_title_norm, episode, allow_episodeless, prefer_dub) else {
            continue;
        };
        if trusted {
            score += 300;
        }
        score += seeders.min(300) as i64 / 3;
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
        });
    }
    out
}

/// Find ranked torrent candidates for `titles` (AniList romaji/english/
/// synonyms, best first) episode `episode`.
pub async fn find_candidates(
    client: &reqwest::Client,
    titles: &[String],
    episode: i64,
    allow_episodeless: bool,
    prefer_dub: bool,
) -> Vec<Candidate> {
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
        // Stop early if SubsPlease already produced an exact-episode hit —
        // it's the highest-quality, best-seeded option for current shows.
        if all.iter().any(|c| c.score >= 2000) {
            break;
        }
    }

    if !all.iter().any(|c| c.score >= 2000) {
        for title in &expanded {
            let norm = normalize(title);
            let single_q = format!("{} - {:02}", title, episode);
            all.extend(search_nyaa(client, &single_q, &norm, episode, false, prefer_dub).await);
            let batch_q = format!("{} 1080p", title);
            all.extend(search_nyaa(client, &batch_q, &norm, episode, allow_episodeless, prefer_dub).await);
            if all.iter().any(|c| c.score >= 1000) {
                break;
            }
        }
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

    #[test]
    fn season1_query_rejects_r2_release() {
        // "Code Geass" (S1 query, no marker) must not match a season-2
        // ("R2") release just because the episode number lines up — R1/R2
        // is Code Geass fansub shorthand for "Rebellion 1/2", not caught by
        // the S2/"season 2"/"2nd season" patterns alone.
        let query = normalize("Code Geass");
        assert!(title_matches(&query, &normalize("Code Geass - 11 [Group] 1080p")));
        assert!(!title_matches(&query, &normalize("Code Geass R2 - 11 [Group] 1080p")));
    }

    #[test]
    fn r2_query_matches_r2_release_only() {
        let query = normalize("Code Geass R2");
        assert!(title_matches(&query, &normalize("Code Geass R2 - 11 [Group] 1080p")));
        assert!(!title_matches(&query, &normalize("Code Geass - 11 [Group] 1080p")));
    }
}
