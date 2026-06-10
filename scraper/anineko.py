"""AniNeko provider — curl_cffi scraping with verified CSS selectors.

Real DOM structure (verified 2026-06-10):
  Search: article.nv-anime-card > a.nv-anime-thumb[href^="/watch/"] (slug)
          div.nv-anime-title > a (title)
  Detail: article.nv-info-episode-item > a.nv-info-episode-main (ep link)
          strong (episode number: "Episode N")
          span (episode title)
  Servers: regex data-video="URL" from episode page HTML
"""

import re
import asyncio
from dataclasses import dataclass, field
from typing import Optional

from curl_cffi import requests
from selectolax.parser import HTMLParser

BASE_URL = "https://anineko.to"


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
        for attempt in range(3):
            try:
                url = f"{BASE_URL}/browser"
                resp = self.session.get(url, params={"keyword": query}, timeout=20)
                resp.raise_for_status()
                return self._parse_search(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Search failed after 3 attempts: {e}")
                await self._sleep(1 + attempt)
        return []

    async def get(self, slug: str) -> Optional[AnimeInfo]:
        for attempt in range(3):
            try:
                url = f"{BASE_URL}/watch/{slug}"
                resp = self.session.get(url, timeout=20)
                resp.raise_for_status()
                return self._parse_anime(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Get failed after 3 attempts: {e}")
                await self._sleep(1 + attempt)
        return None

    async def streams(self, slug: str, episode: int) -> list[StreamServer]:
        for attempt in range(3):
            try:
                url = f"{BASE_URL}/watch/{slug}/ep-{episode}"
                resp = self.session.get(url, timeout=20)
                resp.raise_for_status()
                return self._parse_servers(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(
                        f"Stream resolution failed after 3 attempts: {e}"
                    )
                await self._sleep(1 + attempt)
        return []

    # ── Parsers ────────────────────────────────────────

    def _parse_search(self, html: str) -> list[AnimeRef]:
        tree = HTMLParser(html)
        results = []

        for card in tree.css("article.nv-anime-card"):
            thumb = card.css_first("a.nv-anime-thumb")
            title_div = card.css_first(".nv-anime-title")
            title_a = title_div.css_first("a") if title_div else None

            href = thumb.attributes.get("href", "") if thumb else ""
            if not href or not href.startswith("/watch/"):
                continue

            slug = href.replace("/watch/", "").split("?")[0]

            # Title: prefer img alt from thumbnail, fallback to title div link
            title = ""
            if thumb:
                img = thumb.css_first("img")
                if img:
                    title = img.attributes.get("alt", "")
            if not title and title_a:
                title = title_a.text(strip=True)
            if not title:
                continue

            # Year: check meta or search text for 4-digit year
            year = None
            meta = card.css_first(".nv-anime-meta")
            if meta:
                year_match = re.search(r"\b(19|20)\d{2}\b", meta.text(strip=True))
                if year_match:
                    year = int(year_match.group())

            results.append(AnimeRef(id=slug, title=title, year=year))

        return results

    def _parse_anime(self, html: str) -> Optional[AnimeInfo]:
        tree = HTMLParser(html)

        # Title: from h1 or title tag
        title = ""
        h1 = tree.css_first("h1")
        if h1:
            title = h1.text(strip=True)
        if not title:
            title_match = re.search(r"<title>([^-]+)", html)
            if title_match:
                title = title_match.group(1).strip()
        if not title:
            return None

        # Episodes: from the episode grid items
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
                num_text = number_el.text(strip=True)
                match = re.search(r"\d+", num_text)
                if match:
                    ep_num = int(match.group())

            # Also try href fallback: /watch/slug/ep-N
            if ep_num == 0 and href:
                match = re.search(r"/ep-(\d+)", href)
                if match:
                    ep_num = int(match.group(1))

            if ep_num <= 0:
                continue

            ep_title = title_el.text(strip=True) if title_el else None
            episodes.append(Episode(number=ep_num, title=ep_title))

        return AnimeInfo(title=title, episodes=episodes)

    def _parse_servers(self, html: str) -> list[StreamServer]:
        servers = []

        # Find all data-video attributes and their surrounding context
        matches = list(
            re.finditer(
                r'<(\w+)[^>]*\bdata-video\s*=\s*"([^"]+)"([^>]*)>(.*?)</\1>',
                html,
                re.DOTALL | re.IGNORECASE,
            )
        )

        for match in matches:
            embed_url = match.group(2)
            tag_content = match.group(4)

            # Extract server name from tag content
            name = re.sub(r"<[^>]+>", "", tag_content).strip()

            # If no name from content, look at text before this element
            if not name or len(name) < 2:
                before = html[: match.start()]
                text_before = re.findall(r">\s*([^<]{2,40})\s*<", before)
                if text_before:
                    name = text_before[-1].strip()

            if not name or len(name) < 2:
                name = f"Server {len(servers) + 1}"

            servers.append(
                StreamServer(
                    name=name.strip(),
                    url=embed_url,
                    is_m3u8=True,
                )
            )

        # Fallback: just find all data-video URLs
        if not servers:
            data_urls = re.findall(r'data-video\s*=\s*"([^"]+)"', html)
            for i, url in enumerate(data_urls):
                servers.append(
                    StreamServer(
                        name=f"Server {i + 1}",
                        url=url,
                        is_m3u8=True,
                    )
                )

        return servers

    async def _sleep(self, seconds: float):
        await asyncio.sleep(seconds)


# ── Quick test ─────────────────────────────────────────

if __name__ == "__main__":

    async def main():
        provider = AniNekoProvider()
        print("Testing AniNeko scraper...\n")

        # Search
        print("Search: naruto")
        results = await provider.search("naruto")
        print(f"  Found {len(results)} results")
        for r in results[:3]:
            print(f"    {r.title[:50]}  (slug={r.id})")

        if not results:
            print("  FAILED: no search results")
            return

        # Get episodes
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

        # Streams for first episode
        if info and info.episodes:
            ep_num = info.episodes[0].number
            print(f"\nStream servers: {slug} ep {ep_num}")
            servers = await provider.streams(slug, ep_num)
            print(f"  Found {len(servers)} servers")
            for s in servers[:3]:
                print(f"    {s.name}: {s.url[:80]}...")

    asyncio.run(main())
