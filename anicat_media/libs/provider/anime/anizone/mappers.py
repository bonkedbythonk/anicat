"""Mappers for converting AniZone HTML to generic provider models.

AniZone is a Laravel Livewire app using Vidstack player. Search results and
episode pages are server-rendered with stream URLs embedded in the HTML.

Key patterns:
- Search: /anime?search={query} — result cards with cover, title, slug, metadata
- Detail: /anime/{slug} — title, synopsis, tags, episode count
- Episode: /anime/{slug}/{ep} — <media-player src="...master.m3u8"> in HTML
"""

import re
from typing import Optional

from ....provider.anime.types import (
    Anime,
    AnimeEpisodeInfo,
    AnimeEpisodes,
    PageInfo,
    SearchResult,
    SearchResults,
    Subtitle,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_SLUG_RE = re.compile(r"/anime/([a-z0-9]+)")
_IMAGE_RE = re.compile(r"/images/anime/([a-f0-9-]+)\.(?:jpg|webp)")


def _extract_search_cards(raw_html: str) -> list[dict]:
    """Extract search result cards from the anime index page.

    Each card is defined in a div container starting with x-data="{ anmTitles: ...
    """
    results: list[dict] = []

    starts = [m.start() for m in re.finditer(r'<div\s+x-data="\{\s*anmTitles:', raw_html)]
    blocks = []
    for i, start in enumerate(starts):
        end = starts[i+1] if i + 1 < len(starts) else len(raw_html)
        blocks.append(raw_html[start:end])

    for block in blocks:
        # Extract title from window.getTitle fallback parameter
        title_match = re.search(r"window\.getTitle\([^,]+,\s*'([^']+)'\)", block)
        if not title_match:
            title_match = re.search(r"window\.getTitle\([^,]+,\s*\"([^\"]+)\"\)", block)
        title = title_match.group(1) if title_match else None
        if not title:
            continue

        # Extract slug from href
        slug_match = re.search(r'href="https://anizone\.to/anime/([a-z0-9]+)"', block)
        if not slug_match:
            slug_match = re.search(r'href="/anime/([a-z0-9]+)"', block)
        slug = slug_match.group(1) if slug_match else None
        if not slug:
            continue

        # Extract image
        img_match = re.search(r'src="(https://anizone\.to/images/anime/[^"]+)"', block)
        image_url = img_match.group(1) if img_match else ""

        # Extract year
        year_match = re.search(r"not-last:after:content-\['•'\].*?>(\d{4})</span>", block, re.DOTALL)
        year = year_match.group(1) if year_match else None

        # Extract episode count
        ep_match = re.search(r"(\d+)\s*Eps?", block)
        ep_count = int(ep_match.group(1)) if ep_match else 0

        # Extract status (Completed, Releasing, etc.)
        status_match = re.search(r">(Completed|Releasing|Upcoming|Airing)</span>", block, re.IGNORECASE)
        status = status_match.group(1) if status_match else None

        results.append({
            "slug": slug,
            "title": title,
            "image_url": image_url,
            "url": f"https://anizone.to/anime/{slug}",
            "ep_count": ep_count,
            "year": year,
            "status": status,
        })

    return results


def map_to_search_results(raw_html: str) -> Optional[SearchResults]:
    """Map AniZone anime index/search page HTML to generic SearchResults."""
    cards = _extract_search_cards(raw_html)
    if not cards:
        return None

    items: list[SearchResult] = []
    for card in cards:
        items.append(
            SearchResult(
                id=card["slug"],
                title=card["title"],
                poster=card["image_url"],
                episodes=AnimeEpisodes(
                    sub=[str(i) for i in range(1, card["ep_count"] + 1)]
                )
                if card["ep_count"]
                else AnimeEpisodes(sub=[]),
                year=card["year"],
                status=card["status"],
            )
        )

    return SearchResults(
        page_info=PageInfo(current_page=1),
        results=items,
    )


# ---------------------------------------------------------------------------
# Detail page mapping
# ---------------------------------------------------------------------------


def map_to_anime_result(raw_html: str, slug: str) -> Optional[Anime]:
    """Map AniZone anime detail page HTML to generic Anime model."""
    title = _extract_title(raw_html)
    if not title:
        return None

    cover = _extract_cover_image(raw_html)
    episode_count = _extract_episode_count(raw_html)

    # AniZone doesn't expose per-episode titles on the detail page.
    # We generate episode IDs from the total count.
    ep_ids = [str(i) for i in range(1, episode_count + 1)] if episode_count else []
    episodes = AnimeEpisodes(sub=ep_ids)

    return Anime(
        id=slug,
        title=title,
        poster=cover,
        episodes=episodes,
        year=None,
    )


def _extract_title(html: str) -> Optional[str]:
    m = re.search(r"<h1[^>]*>([^<]+)</h1>", html)
    if m:
        t = m.group(1).strip()
        if t and t != "displayAnimeTitle":
            return t
    # Fallback to HTML <title> tag (e.g. "Otaku ni Yasashii Gal wa Inai!? — AniZone")
    title_match = re.search(r"<title>([^<|—\-]+)", html)
    if title_match:
        return title_match.group(1).strip()
    return None


def _extract_cover_image(html: str) -> Optional[str]:
    m = re.search(
        r'<img[^>]*src="(https://anizone\.to/images/anime/[^"]+)"[^>]*>', html
    )
    return m.group(1) if m else None


def _extract_synopsis(html: str) -> Optional[str]:
    # Synopsis is in a div after "Synopsis" heading
    m = re.search(r"<h3[^>]*>Synopsis</h3>\s*<div[^>]*>(.*?)</div>", html, re.DOTALL)
    if not m:
        return None
    # Strip HTML tags
    text = re.sub(r"<[^>]+>", "", m.group(1))
    text = text.replace("<br />", "\n").replace("<br>", "\n")
    return text.strip()


def _extract_episode_count(html: str) -> int:
    m = re.search(r"(\d+)\s*Episodes?", html)
    return int(m.group(1)) if m else 0


def _extract_tags(html: str) -> list[str]:
    """Extract genre/tag links from the detail page."""
    tags: list[str] = []
    # Tags are in links to /tag/{slug}
    for m in re.finditer(r'href="/tag/[a-z0-9]+"[^>]*>([^<]+)</a>', html):
        tags.append(m.group(1).strip())
    return tags


# ---------------------------------------------------------------------------
# Episode page mapping
# ---------------------------------------------------------------------------


def extract_stream_url(raw_html: str) -> Optional[str]:
    """Extract the master.m3u8 stream URL from an episode page.

    The URL is in the <media-player> element's src attribute:
    <media-player src="https://seiryuu.vid-cdn.xyz/{uuid}/master.m3u8" ...>
    """
    m = re.search(r'<media-player[^>]*\s+src="(https://[^"]+\.m3u8)"', raw_html)
    if m:
        return m.group(1)
    # Fallback: search for any seiryuu master.m3u8 URL
    m = re.search(r'https://seiryuu\.vid-cdn\.xyz/[^"\'\\s<>]+/master\.m3u8', raw_html)
    return m.group(0) if m else None


def extract_subtitles(raw_html: str) -> list[Subtitle]:
    """Extract subtitle tracks from an episode page.

    The <track> elements in the player contain ASS subtitle URLs:
    <track src=https://seiryuu.vid-cdn.xyz/{uuid}/subtitles/0_en.ass
           kind="subtitles" label="Full Subtitles [MTBB]" srclang="en" />
    Note: src may be unquoted.

    Only English and Japanese subtitles are included by default to avoid
    startup delays from downloading 13+ subtitle files.
    """
    subtitles: list[Subtitle] = []
    track_pattern = re.compile(
        r'<track\s+src="?(https://[^"\s>]+?/subtitles/\d+_\w+\.ass)"?'
        r'[^>]*?label="([^"]*)"'
        r'[^>]*?srclang="([^"]*)"',
        re.DOTALL | re.IGNORECASE,
    )
    for m in track_pattern.finditer(raw_html):
        url = m.group(1)
        label = m.group(2).replace("&amp;", "&")
        lang = m.group(3)
        if lang.lower() not in ("en", "ja"):
            continue
        subtitles.append(Subtitle(url=url, language=f"{lang} ({label})"))
    return subtitles


def extract_episodes_from_episode_page(
    raw_html: str, anime_slug: str
) -> list[AnimeEpisodeInfo]:
    """Extract episode list from an episode page sidebar.

    The sidebar contains links like:
    <a wire:navigate wire:key="e-N" href="https://anizone.to/anime/{slug}/{N}">
        <div class='min-w-10 text-sm'>N</div>
        <div class="grow text-sm line-clamp-1">Title</div>
    </a>
    """
    episodes: list[AnimeEpisodeInfo] = []
    pattern = re.compile(
        r'wire:key="e-(\d+)"\s+href="[^"]*/(\d+)"[^>]*>'
        r".*?<div[^>]*line-clamp-1[^>]*>([^<]*)</div>",
        re.DOTALL,
    )
    for m in pattern.finditer(raw_html):
        ep_num = m.group(1)
        ep_title = m.group(3).strip()
        episodes.append(
            AnimeEpisodeInfo(
                id=ep_num, episode=ep_num, title=ep_title if ep_title else None
            )
        )

    if not episodes:
        # Fallback: extract just numbers from hrefs
        nums = set()
        for m in re.finditer(
            rf'href="[^"]*/anime/{re.escape(anime_slug)}/(\d+)"', raw_html
        ):
            nums.add(int(m.group(1)))
        episodes = [AnimeEpisodeInfo(id=str(n), episode=str(n)) for n in sorted(nums)]

    return episodes
