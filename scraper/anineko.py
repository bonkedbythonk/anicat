"""AniNeko provider - curl_cffi scraping with Chrome TLS impersonation."""

import re
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
                params = {"keyword": query}
                resp = self.session.get(url, params=params, timeout=15)
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
                resp = self.session.get(url, timeout=15)
                resp.raise_for_status()
                return self._parse_anime(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Get failed after 3 attempts: {e}")
                await self._sleep(1 + attempt)

        return None

    async def streams(
        self, slug: str, episode: int
    ) -> list[StreamServer]:
        for attempt in range(3):
            try:
                url = f"{BASE_URL}/watch/{slug}-episode-{episode}"
                resp = self.session.get(url, timeout=15)
                resp.raise_for_status()
                return self._parse_servers(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Stream resolution failed after 3 attempts: {e}")
                await self._sleep(1 + attempt)

        return []

    def _parse_search(self, html: str) -> list[AnimeRef]:
        tree = HTMLParser(html)
        results = []

        for item in tree.css(".browser-item, .anime-item, .film_list-wrap .flw-item"):
            link = item.css_first("a")
            title_el = item.css_first(".film-name, .anime-name, h3")
            year_el = item.css_first(".fdi-item, .anime-year, .year")

            if not link or not title_el:
                continue

            href = link.attributes.get("href", "")
            slug = href.strip("/").split("/")[-1]

            title = title_el.text(strip=True)
            year = None
            if year_el:
                year_text = year_el.text(strip=True)
                match = re.search(r"\d{4}", year_text)
                if match:
                    year = int(match.group())

            results.append(AnimeRef(id=slug, title=title, year=year))

        return results

    def _parse_anime(self, html: str) -> AnimeInfo:
        tree = HTMLParser(html)

        title_el = tree.css_first("h2.film-name, h1.anime-name, h1.entry-title")
        title = title_el.text(strip=True) if title_el else ""

        episodes = []
        ep_items = tree.css(".ep-item, .episodes-list a, .episode-list li a")
        for ep in ep_items:
            ep_number = 0
            ep_title = ""

            number_el = ep.css_first(".ep-no, .episode-number, .ep-label")
            title_el = ep.css_first(".ep-title, .episode-title")

            if number_el:
                num_text = number_el.text(strip=True)
                match = re.search(r"\d+", num_text)
                if match:
                    ep_number = int(match.group())

            if title_el:
                ep_title = title_el.text(strip=True)

            if ep_number > 0:
                episodes.append(Episode(number=ep_number, title=ep_title))

        return AnimeInfo(title=title, episodes=episodes)

    def _parse_servers(self, html: str) -> list[StreamServer]:
        tree = HTMLParser(html)
        servers = []

        server_els = tree.css(
            ".server-item, .ps_-list .ps_-item, .servers-list .server, "
            ".playlist-server-item, .sv-list li"
        )
        for s in server_els:
            data_id = s.attributes.get("data-id") or s.attributes.get("data-server")
            name = data_id or s.text(strip=True) or "Server"

            payload = s.attributes.get("data-url", "")
            if not payload:
                payload = s.attributes.get("data-src", "")

            if not payload:
                continue

            servers.append(
                StreamServer(
                    name=name,
                    url=payload,
                    is_m3u8=True,
                )
            )

        return servers

    async def _sleep(self, seconds: float):
        import asyncio

        await asyncio.sleep(seconds)
