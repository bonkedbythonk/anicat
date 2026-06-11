"""AniNeko provider — verified against live site DOM (2026-06-11).

Real DOM structure:
  Search: article.nv-anime-card > a.nv-anime-thumb (slug), img alt (title)
  Episode page: button.nv-server-btn with data-video=URL, data-tab=tab_N
     <span>Hard Sub</span> / <span>DUB</span> for group labels
  Embed URLs: third-party sites that require follow-up fetch for stream URLs
"""

import re
import asyncio
import json
import time
from dataclasses import dataclass, field, asdict
from typing import Optional, List, Tuple
from curl_cffi import requests
from selectolax.parser import HTMLParser

BASE_URL = "https://anineko.to"


def clean_title_for_search(title: str) -> str:
    """Remove season/part/cour suffixes that AniNeko slugs won't match."""
    # Remove season syntax: "Season 4", "Season 4 2nd Year", "1st Semester", etc.
    title = re.sub(
        r'\s*([-–]\s*)?('
        r'season\s*\d+|part\s*\d+|cour\s*\d+|\d+(st|nd|rd|th)\s*season'
        r'|2nd year.*|1st semester.*|ichi gakki.*|ni gakki.*'
        r'|[-–:]\s*\w+\s*arc|\(\d{4}\)'
        r')\s*$',
        '', title, flags=re.IGNORECASE,
    ).strip()
    # Remove trailing parenthetical content
    title = re.sub(r'\s*[\(\[].*?[\)\]]\s*$', '', title).strip()
    # Collapse multiple spaces
    title = re.sub(r'\s+', ' ', title).strip()
    return title


@dataclass
class AnimeRef:
    id: str
    title: str
    year: Optional[int] = None


@dataclass
class Episode:
    number: int
    title: Optional[str] = None
    image: Optional[str] = None


@dataclass
class AnimeInfo:
    title: str
    episodes: list[Episode] = field(default_factory=list)


@dataclass
class StreamServer:
    name: str
    url: str
    quality: Optional[str] = None
    is_m3u8: Optional[bool] = None
    headers: Optional[dict] = None
    group: str = "unknown"
    source_type: str = "unknown"


class AniNekoProvider:
    def __init__(self):
        self.session = requests.Session(impersonate="chrome131")
        self.session.headers.update(
            {
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/131.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
            }
        )

    async def search(self, query: str) -> list[AnimeRef]:
        attempts = self._build_search_attempts(query)
        for attempt in attempts:
            for tries in range(1):  # single try per fallback — fast retries handled by Rust
                try:
                    resp = self.session.get(
                        f"{BASE_URL}/browser",
                        params={"keyword": attempt},
                        timeout=20,
                    )
                    resp.raise_for_status()
                    results = self._parse_search(resp.text)
                    if results:
                        return results
                    break  # No results for this attempt, try next
                except Exception:
                    if tries == 2:
                        break
                    await self._sleep(1 + tries)
        return []

    def _build_search_attempts(self, title: str) -> list[str]:
        attempts = []
        cleaned = clean_title_for_search(title)
        attempts.append(cleaned)
        words = cleaned.split()
        if len(words) > 5:
            attempts.append(" ".join(words[:5]))
        if len(words) > 3:
            attempts.append(" ".join(words[:3]))
        base = re.sub(
            r"\s*(season\s*\d+|s\d+|\biv\b|\biii\b|\bii\b)\s*$",
            "", cleaned, flags=re.IGNORECASE,
        ).strip()
        if base and base != cleaned:
            attempts.append(base)
        seen = set()
        return [x for x in attempts if x and not (x in seen or seen.add(x))]

    async def get(self, slug: str) -> Optional[AnimeInfo]:
        for attempt in range(3):
            try:
                resp = self.session.get(f"{BASE_URL}/watch/{slug}", timeout=20)
                resp.raise_for_status()
                return self._parse_anime(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Get failed after 3 attempts: {e}")
                await self._sleep(1 + attempt)
        return None

    async def streams(
        self, slug: str, episode: int, debug: bool = False
    ) -> Tuple[List[StreamServer], List[dict]]:
        """Multi-pass extraction with optional debug output."""
        debug_log = []
        url = f"{BASE_URL}/watch/{slug}/ep-{episode}"

        for attempt in range(3):
            try:
                resp = self.session.get(url, timeout=30)
                resp.raise_for_status()
                html = resp.text
                page_title = self._extract_title(html)

                if debug:
                    debug_log.append({
                        "pass": "request",
                        "status": resp.status_code,
                        "final_url": str(resp.url),
                        "html_length": len(html),
                        "page_title": page_title,
                    })

                sources: List[StreamServer] = []

                # Pass A — DOM data-video elements
                sources_a, debug_a = self._pass_dom(html)
                sources.extend(sources_a)
                if debug:
                    debug_log.append(debug_a)

                # Pass B — Regex over raw HTML
                sources_b, debug_b = self._pass_regex(html)
                sources.extend(sources_b)
                if debug:
                    debug_log.append(debug_b)

                # Pass C — Script JSON blobs
                sources_c, debug_c = self._pass_script_json(html)
                sources.extend(sources_c)
                if debug:
                    debug_log.append(debug_c)

                # Pass D — Server groups (Hard Sub / Soft Sub / DUB)
                sources_d, debug_d = self._pass_server_groups(html)
                sources.extend(sources_d)
                if debug:
                    debug_log.append(debug_d)

                # Deduplicate by URL
                seen = set()
                unique = []
                for s in sources:
                    if s.url and s.url not in seen:
                        seen.add(s.url)
                        unique.append(s)

                if debug:
                    return unique, debug_log
                return unique, []

            except Exception as e:
                if attempt == 2:
                    if debug:
                        return [], [{"pass": "error", "error": str(e)}]
                    raise RuntimeError(
                        f"Stream resolution failed after 3 attempts: {e}"
                    )
                await self._sleep(1 + attempt)

        return [], []

    # ── Parsers ────────────────────────────────────────

    def _parse_search(self, html: str) -> list[AnimeRef]:
        tree = HTMLParser(html)
        results = []
        for card in tree.css("article.nv-anime-card"):
            thumb = card.css_first("a.nv-anime-thumb")
            href = thumb.attributes.get("href", "") if thumb else ""
            if not href or not href.startswith("/watch/"):
                continue
            slug = href.replace("/watch/", "")
            img = thumb.css_first("img") if thumb else None
            title = img.attributes.get("alt", "") if img else ""
            if not title:
                title_div = card.css_first(".nv-anime-title")
                if title_div:
                    title_a = title_div.css_first("a")
                    if title_a:
                        title = title_a.text(strip=True)
            if not title:
                continue
            results.append(AnimeRef(id=slug, title=title))
        return results

    def _parse_anime(self, html: str) -> Optional[AnimeInfo]:
        tree = HTMLParser(html)
        title = ""
        h1 = tree.css_first("h1")
        if h1:
            title = h1.text(strip=True)
        if not title:
            m = re.search(r"<title>([^-]+)", html)
            if m:
                title = m.group(1).strip()
        if not title:
            return None

        episodes = []
        for ep_card in tree.css("article.nv-info-episode-item"):
            ep_link = ep_card.css_first("a.nv-info-episode-main")
            if not ep_link:
                continue
            href = ep_link.attributes.get("href", "")
            number_el = ep_link.css_first("strong")
            title_el = ep_link.css_first("span")
            ep_num = 0
            if number_el:
                m = re.search(r"\d+", number_el.text(strip=True))
                if m:
                    ep_num = int(m.group())
            if ep_num == 0 and href:
                m = re.search(r"/ep-(\d+)", href)
                if m:
                    ep_num = int(m.group(1))
            if ep_num <= 0:
                continue
            episodes.append(
                Episode(
                    number=ep_num,
                    title=title_el.text(strip=True) if title_el else None,
                )
            )
        return AnimeInfo(title=title, episodes=episodes)

    def _extract_title(self, html: str) -> str:
        m = re.search(r"<title>([^<]+)</title>", html)
        return m.group(1).strip() if m else ""

    # ── Pass A: DOM data-video elements ─────────────────

    def _pass_dom(self, html: str) -> Tuple[List[StreamServer], dict]:
        found, notes = [], []
        # data-video attributes on server buttons
        matches = re.findall(
            r'<button[^>]*\bdata-video\s*=\s*"([^"]+)"([^>]*)>(.*?)</button>',
            html,
            re.DOTALL | re.IGNORECASE,
        )
        for url, rest_attrs, inner in matches:
            data_tab = ""
            tab_m = re.search(r'data-tab\s*=\s*"([^"]+)"', rest_attrs)
            if tab_m:
                data_tab = tab_m.group(1)
            # Server name from text inside button
            name = re.sub(r"<[^>]+>", "", inner).strip()[:40]
            # Group from span inside button
            group = "unknown"
            span_m = re.search(r"<span[^>]*>([^<]+)</span>", inner)
            if span_m:
                group = span_m.group(1).strip().lower().replace(" ", "_")
                if "hard" in group:
                    group = "hard_sub"
                elif "soft" in group:
                    group = "soft_sub"
                elif "dub" in group:
                    group = "dub"

            found.append(
                StreamServer(
                    name=name or f"server_{len(found)}",
                    url=url,
                    group=group,
                    source_type="dom_data_video",
                )
            )
        # Also check iframe src
        iframes = re.findall(r'<iframe[^>]+src\s*=\s*"([^"]+)"', html)
        for url in iframes:
            found.append(
                StreamServer(
                    name="iframe",
                    url=url,
                    group="unknown",
                    source_type="dom_iframe",
                )
            )
        return found, {"pass": "dom_iframe", "found": len(found), "notes": notes}

    # ── Pass B: Regex over raw HTML ─────────────────────

    def _pass_regex(self, html: str) -> Tuple[List[StreamServer], dict]:
        found = []
        patterns = [
            r'data-video\s*=\s*"([^"]+)"',
            r'src\s*=\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"',
            r'"((?:https?:)?//[^"]+\.(?:m3u8|mp4)[^"]*)"',
            r'"((?:https?:)?//[^"]+/embed/[^"]*)"',
        ]
        for pat in patterns:
            for url in re.findall(pat, html):
                found.append(
                    StreamServer(
                        name="regex",
                        url=url,
                        group="unknown",
                        source_type="regex",
                        is_m3u8=(".m3u8" in url) or None,
                    )
                )
        return found, {
            "pass": "regex",
            "found": len(found),
            "notes": [],
        }

    # ── Pass C: Script JSON blobs ───────────────────────

    def _pass_script_json(self, html: str) -> Tuple[List[StreamServer], dict]:
        found, notes = [], []
        scripts = re.findall(
            r"<script[^>]*>(.*?)</script>", html, re.DOTALL | re.IGNORECASE
        )
        for i, s in enumerate(scripts):
            s = s.strip()
            if not s:
                continue
            # Try to find JSON objects in the script
            json_objects = re.findall(r"\{[^{}]*\}", s)
            for obj_str in json_objects:
                try:
                    obj = json.loads(obj_str)
                except (json.JSONDecodeError, ValueError):
                    # Try braces balancing
                    depth = 0
                    start = obj_str.find("{")
                    if start < 0:
                        start = s.find(obj_str)
                        if start < 0:
                            continue
                        obj_str = s[start : start + 500]
                    try:
                        obj = json.loads(obj_str)
                    except (json.JSONDecodeError, ValueError):
                        continue
                # Look for video URLs in the JSON
                for key in ["sources", "file", "src", "url", "stream", "hls", "video"]:
                    if isinstance(obj, dict) and key in obj:
                        val = obj[key]
                        if isinstance(val, str):
                            found.append(
                                StreamServer(
                                    name=f"script_{key}",
                                    url=val,
                                    group="unknown",
                                    source_type="script_json",
                                    is_m3u8=(".m3u8" in val) or None,
                                )
                            )
                        elif isinstance(val, list):
                            for item in val:
                                if isinstance(item, str):
                                    found.append(
                                        StreamServer(
                                            name=f"script_{key}",
                                            url=item,
                                            group="unknown",
                                            source_type="script_json",
                                            is_m3u8=(".m3u8" in item) or None,
                                        )
                                    )
            if found:
                notes.append(f"Script #{i} produced {len(found)} URLs")
                break
        return found, {
            "pass": "script_json",
            "found": len(found),
            "notes": notes,
        }

    # ── Pass D: Server groups ───────────────────────────

    def _pass_server_groups(self, html: str) -> Tuple[List[StreamServer], dict]:
        found = []
        # Match server buttons with data-video AND extract group from span
        matches = re.findall(
            r'data-video\s*=\s*"([^"]+)"',
            html,
        )
        for url in matches:
            # Already captured in Pass A as dom_data_video, but add as
            # embedding-friendly version for multi-server display
            if url not in {s.url for s in found}:
                found.append(
                    StreamServer(
                        name="server",
                        url=url,
                        group="unknown",
                        source_type="server_group",
                    )
                )
        return found, {
            "pass": "server_groups",
            "found": len(found),
            "notes": [],
        }

    async def _sleep(self, seconds: float):
        await asyncio.sleep(seconds)


# ── Quick test ─────────────────────────────────────────

if __name__ == "__main__":

    async def main():
        provider = AniNekoProvider()
        print("Testing AniNeko scraper...\n")

        print("Search: naruto")
        results = await provider.search("naruto")
        print(f"  Found {len(results)} results")
        for r in results[:3]:
            print(f"    {r.title[:50]}  (slug={r.id})")

        if not results:
            print("  FAILED: no search results")
            return

        slug = results[0].id
        print(f"\nGet episodes: {slug}")
        info = await provider.get(slug)
        if info:
            print(f"  Title: {info.title}")
            print(f"  Episodes: {len(info.episodes)}")
            for ep in info.episodes[:3]:
                print(f"    Ep {ep.number}: {ep.title or '(no title)'}")
        else:
            print("  FAILED: no anime info")

        if info and info.episodes:
            ep_num = info.episodes[0].number
            slug2 = "classroom-of-the-elite-iv"
            print(f"\nDebug streams: {slug2} ep 1")
            sources, debug = await provider.streams(slug2, 1, debug=True)
            print(f"  Found {len(sources)} sources")
            for s in sources[:5]:
                print(f"    [{s.source_type}] {s.name}: {s.url[:80]}...")
            print(f"\n  Debug log: {len(debug)} passes")
            for d in debug:
                print(f"    {d.get('pass', 'unknown')}: {d.get('found', '?')} items")

    asyncio.run(main())
