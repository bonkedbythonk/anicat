"""Mappers for converting AniNeko HTML to generic provider models."""

import re
from typing import Optional

from ..types import (
    Anime,
    AnimeEpisodes,
    PageInfo,
    SearchResult,
    SearchResults,
)


def _parse_episode_counts(element_html: str) -> tuple[int, int]:
    sub_count = 0
    dub_count = 0

    cc_match = re.search(r"CC\s*(\d+)", element_html)
    if cc_match:
        sub_count = int(cc_match.group(1))

    if "DUB" in element_html.upper():
        dub_match = re.search(r"DUB\s*(\d+)", element_html, re.IGNORECASE)
        if dub_match:
            dub_count = int(dub_match.group(1))
        else:
            dub_count = sub_count

    return sub_count, dub_count


def map_to_search_results(
    raw_html: str,
) -> Optional[SearchResults]:

    from ...scraping.html_parser import HTMLParser, HTMLParserConfig

    parser = HTMLParser(HTMLParserConfig(use_lxml=False))
    parsed = parser.parse(raw_html)
    article_elements = parsed.find_by_tag("article")

    results: list[SearchResult] = []
    for article in article_elements:
        raw_article = _element_to_string(article, raw_html)
        if not raw_article:
            continue

        link_match = re.search(r'href="(/watch/[^"]+)"', raw_article)
        if not link_match:
            continue
        slug = link_match.group(1).replace("/watch/", "")

        title = None
        img_alt = re.search(r'<img[^>]+alt="([^"]+)"', raw_article)
        if not img_alt:
            heading_match = re.search(
                r"<h[23][^>]*>([^<]+(?:<[^>]+>[^<]*</[^>]+>)?[^<]*)</h[23]>", raw_article
            )
            if heading_match:
                title = re.sub(r"<[^>]+>", "", heading_match.group(1)).strip()
            else:
                a_match = re.search(r'<a[^>]*>([^<]{3,120})</a>', raw_article)
                if a_match:
                    title = a_match.group(1).strip()
        if img_alt:
            title = img_alt.group(1).strip()
        if not title:
            continue

        poster = None
        img_match = re.search(r'<img[^>]+src="([^"]+)"', raw_article)
        if img_match:
            poster = img_match.group(1)

        media_type = None
        badge_match = re.search(r'<span[^>]*nv-badge-new[^>]*>([^<]+)<', raw_article)
        if badge_match:
            media_type = badge_match.group(1).strip()

        sub_count, dub_count = _parse_episode_counts(raw_article)

        year = None
        year_match = re.search(r">\s*(\d{4})\s*<", raw_article)
        if year_match:
            year = year_match.group(1)

        sub_list = [str(i) for i in range(1, sub_count + 1)]
        dub_list = [str(i) for i in range(1, dub_count + 1)]

        results.append(
            SearchResult(
                id=slug,
                title=title,
                poster=poster,
                episodes=AnimeEpisodes(sub=sub_list, dub=dub_list),
                media_type=media_type,
                year=year,
            )
        )

    if not results:
        return None

    total_pages = 1
    pagination_links = re.findall(r"\?page=(\d+)", raw_html)
    if pagination_links:
        try:
            total_pages = max(int(p) for p in pagination_links)
        except ValueError:
            pass

    return SearchResults(
        page_info=PageInfo(total=total_pages),
        results=results,
    )


def map_to_anime_result(slug: str, raw_html: str) -> Optional[Anime]:
    title_match = re.search(r"<h1[^>]*>([^<]+)</h1>", raw_html)
    if not title_match:
        title_match = re.search(r"<title>([^-]+)", raw_html)
    if not title_match:
        return None
    title = title_match.group(1).strip()

    ep_matches = re.findall(r"/watch/" + re.escape(slug) + r"/ep-(\d+)", raw_html)
    episode_numbers = sorted(set(ep_matches), key=int) if ep_matches else []

    has_dub = "DUB" in raw_html

    media_type = None
    type_match = re.search(r">\s*(TV|Movie|OVA|Special|ONA)\s*<", raw_html)
    if type_match:
        media_type = type_match.group(1)

    year = None
    year_match = re.search(r">\s*(\d{4})\s*<", raw_html)
    if year_match:
        year = year_match.group(1)

    poster = None
    poster_match = re.search(
        r'<img[^>]+src="([^"]+)"[^>]*alt="[^"]*' + re.escape(title[:20]) + r'[^"]*"',
        raw_html,
    )
    if not poster_match:
        poster_match = re.search(
            r'<img[^>]+src="(https://[^"]+/(?:poster|cover|image)[^"]+)"', raw_html
        )
    if not poster_match:
        poster_match = re.search(
            r'<img[^>]+src="(https://[^"]+\.(?:jpg|jpeg|png|webp)[^"]*)"', raw_html
        )
    if poster_match:
        poster = poster_match.group(1)

    sub_list = (
        [str(i) for i in range(1, len(episode_numbers) + 1)]
        if episode_numbers
        else episode_numbers
    )
    dub_list = (
        [str(i) for i in range(1, len(episode_numbers) + 1)]
        if has_dub and episode_numbers
        else []
    )

    return Anime(
        id=slug,
        title=title,
        episodes=AnimeEpisodes(
            sub=sub_list,
            dub=dub_list,
            raw=[],
        ),
        type=media_type,
        poster=poster,
        year=year,
    )


def extract_episode_servers(raw_html: str) -> list[tuple[str, str]]:
    servers: list[tuple[str, str]] = []

    data_video_pattern = re.compile(
        r'<(\w+)[^>]*data-video="([^"]+)"([^>]*)>(.*?)</\1>',
        re.DOTALL | re.IGNORECASE,
    )

    for match in data_video_pattern.finditer(raw_html):
        embed_url = match.group(2)
        tag_content = match.group(4)

        name = re.sub(r"<[^>]+>", "", tag_content).strip()

        if not name:
            before = raw_html[: match.start()]
            text_before = re.findall(r">\s*([^<]{2,30})\s*<", before)
            if text_before:
                name = text_before[-1].strip()

        if not name or len(name) < 2:
            name = f"Server {len(servers) + 1}"

        servers.append((name.strip(), embed_url))

    if not servers:
        data_video_matches = re.findall(r'data-video="([^"]+)"', raw_html)
        server_name_matches = re.findall(
            r"(?:server-name|data-server)[^>]*>\s*([^<]+)\s*<",
            raw_html,
            re.IGNORECASE,
        )
        if not server_name_matches:
            server_name_matches = re.findall(
                r"<(?:button|span|div)[^>]*>\s*(?:<[^>]+>)?\s*(?:Hard Sub|Sort Sub|Raw|HD|SD|Stream \d+)[^<]*<",
                raw_html,
                re.IGNORECASE,
            )
            server_name_matches = [
                re.sub(r"<[^>]+>", "", m).strip() for m in server_name_matches
            ]

        for i, embed_url in enumerate(data_video_matches):
            name = (
                server_name_matches[i]
                if i < len(server_name_matches)
                else f"Server {i + 1}"
            )
            servers.append((name.strip(), embed_url))

    return servers


def _element_to_string(element: dict, raw_html: str) -> Optional[str]:
    try:
        start_pos = element.get("start_pos", (0, 0))
        tag = element.get("tag", "div")
        if isinstance(start_pos, tuple) and len(start_pos) == 2:
            line_num = start_pos[0]
            pattern = re.compile(
                rf"<{tag}\b[^>]*>.*?</{tag}>", re.DOTALL | re.IGNORECASE
            )
            matches = list(pattern.finditer(raw_html))
            for m in matches:
                line = raw_html[: m.start()].count("\n") + 1
                if line == line_num:
                    return m.group(0)
            if matches:
                return matches[0].group(0)
    except Exception:
        pass
    return None
