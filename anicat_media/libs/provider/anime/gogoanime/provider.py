import concurrent.futures
import logging
import re
import time
from typing import Iterator, Optional
from urllib.parse import urljoin, urlparse, parse_qs

from ..base import BaseAnimeProvider
from ..params import AnimeParams, EpisodeStreamsParams, SearchParams
from ..types import (
    Anime,
    EpisodeStream,
    MediaTranslationType,
    SearchResults,
    Server,
    Subtitle,
)
from . import constants, mappers

logger = logging.getLogger(__name__)

_UNPACK_EXECUTOR = concurrent.futures.ThreadPoolExecutor(
    max_workers=2, thread_name_prefix="unpack"
)


def _decode_baseN(num: int, base: int) -> str:
    chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
    if num == 0:
        return "0"
    res = []
    while num > 0:
        res.append(chars[num % base])
        num //= base
    return "".join(reversed(res))


def _unpack(p: str, a: int, c: int, k: list[str]) -> str:
    for i in range(c - 1, -1, -1):
        if i < len(k) and k[i]:
            val = k[i]
            base_n_str = _decode_baseN(i, a)
            pattern = r"\b" + re.escape(base_n_str) + r"\b"
            p = re.sub(pattern, val, p)
    return p


def _unpack_async(p: str, a: int, c: int, k: list[str]) -> str:
    future = _UNPACK_EXECUTOR.submit(_unpack, p, a, c, k)
    return future.result(timeout=5)


class GogoAnime(BaseAnimeProvider):

    HEADERS = {
        "Referer": constants.ANINEKO_BASE_URL,
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7",
        "Accept-Language": "en-US,en;q=0.9",
        "Sec-Ch-Ua": '"Not A(Brand";v="99", "Google Chrome";v="121", "Chromium";v="121"',
        "Sec-Ch-Ua-Mobile": "?0",
        "Sec-Ch-Ua-Platform": '"macOS"',
        "Sec-Fetch-Dest": "document",
        "Sec-Fetch-Mode": "navigate",
        "Sec-Fetch-Site": "none",
        "Sec-Fetch-User": "?1",
        "Upgrade-Insecure-Requests": "1",
    }

    def __init__(self, client) -> None:
        super().__init__(client)
        self._detail_cache: dict[str, str] = {}

    @staticmethod
    def _clean_slug(anime_id: str) -> str:
        return anime_id.split("?")[0].strip().rstrip("/")

    def _get_detail_html(self, slug: str) -> str:
        if slug not in self._detail_cache:
            url = f"{constants.WATCH_URL}/{slug}"
            resp = self.client.get(url, follow_redirects=True)
            resp.raise_for_status()
            self._detail_cache[slug] = resp.text
        return self._detail_cache[slug]

    def _fallback_get(self, params: AnimeParams) -> Optional[Anime]:
        if not params.query:
            return None
        try:
            search_results = self.search(
                SearchParams(
                    query=params.query,
                    translation_type=getattr(params, "translation_type", "sub"),
                )
            )
            if not search_results or not search_results.results:
                return None

            matched = search_results.results[0]
            slug = self._clean_slug(matched.id)
            html = self._get_detail_html(slug)
            anime = mappers.map_to_anime_result(slug, html)
            if anime:
                logger.info(
                    f"GogoAnime resolved '{params.id}' -> '{anime.id}' via query"
                )
                return anime
        except Exception as e:
            logger.error(f"GogoAnime query fallback failed for '{params.id}': {e}")
        return None

    def search(self, params: SearchParams) -> Optional[SearchResults]:
        search_url = f"{constants.SEARCH_URL}?keyword={params.query}"
        try:
            response = self.client.get(search_url, follow_redirects=True)
            response.raise_for_status()

            if response.status_code == 404:
                logger.debug(f"No results found on AniNeko for '{params.query}'")
                return None

            results = mappers.map_to_search_results(response.text)
            if not results or not results.results:
                logger.debug(f"No search results parsed for '{params.query}'")
                return None

            return results
        except Exception as e:
            logger.error(f"Failed to search AniNeko for '{params.query}': {e}")
            return None

    def get(self, params: AnimeParams) -> Optional[Anime]:
        slug = self._clean_slug(params.id)

        try:
            html = self._get_detail_html(slug)
        except Exception:
            logger.debug(
                f"GogoAnime detail fetch failed for '{slug}', "
                f"trying query fallback..."
            )
            return self._fallback_get(params)

        try:
            anime = mappers.map_to_anime_result(slug, html)
            if anime is not None:
                return anime
        except Exception as e:
            logger.debug(f"GogoAnime parse failed for '{slug}': {e}")

        logger.debug(
            f"GogoAnime parse returned None for '{slug}', "
            f"trying query fallback..."
        )
        return self._fallback_get(params)

    def episode_streams(
        self, params: EpisodeStreamsParams
    ) -> Optional[Iterator[Server]]:
        ep_num = params.episode
        slug = self._clean_slug(params.anime_id)
        already_resolved = slug in self._detail_cache

        def _fetch_servers(s: str) -> Optional[list]:
            url = f"{constants.WATCH_URL}/{s}/ep-{ep_num}"
            last_error = None
            for attempt in range(3):
                try:
                    resp = self.client.get(url, follow_redirects=True)
                    resp.raise_for_status()
                    break
                except Exception as e:
                    last_error = e
                    if attempt < 2:
                        time.sleep(1 + attempt)
                    continue
            else:
                if last_error:
                    raise last_error
                return None
            if resp.status_code == 404:
                logger.warning(f"Episode not found on AniNeko: '{s}' episode {ep_num}")
                return None
            server_list = mappers.extract_episode_servers(resp.text)
            if not server_list:
                logger.warning(f"No stream servers found for '{s}' episode {ep_num}")
                return None
            return server_list

        server_list = None
        try:
            server_list = _fetch_servers(slug)
        except Exception:
            logger.debug(
                f"GogoAnime episode_streams failed for slug '{slug}', "
                f"trying query fallback..."
            )

        if server_list is None and params.query and not already_resolved:
            try:
                search_results = self.search(
                    SearchParams(
                        query=params.query,
                        translation_type=getattr(params, "translation_type", "sub"),
                    )
                )
                if search_results and search_results.results:
                    resolved = self._clean_slug(search_results.results[0].id)
                    logger.info(
                        f"GogoAnime episode_streams resolved "
                        f"'{params.anime_id}' -> '{resolved}' via query"
                    )
                    server_list = _fetch_servers(resolved)
            except Exception as e:
                logger.error(f"GogoAnime episode_streams query fallback failed: {e}")

        if server_list is None:
            return None

        servers = []
        for item in server_list:
            try:
                server_name, embed_url = item
                translation_type = MediaTranslationType.SUB
                if "dub" in server_name.lower():
                    translation_type = MediaTranslationType.DUB
                elif "raw" in server_name.lower():
                    translation_type = MediaTranslationType.RAW

                subtitles = []
                parsed_url = urlparse(embed_url)
                q = parse_qs(parsed_url.query)
                sub_url = None
                lang = "English"

                if "sub" in q:
                    sub_url = q["sub"][0]
                elif "caption_1" in q:
                    sub_url = q["caption_1"][0]
                    if "sub_1" in q:
                        lang = q["sub_1"][0]
                elif "c1_file" in q:
                    sub_url = q["c1_file"][0]
                    if "c1_label" in q:
                        lang = q["c1_label"][0]

                if sub_url:
                    subtitles.append(Subtitle(url=sub_url, language=lang))

                clean_name = re.sub(r"\s+", " ", server_name).strip()

                server_obj = Server(
                    name=f"AniNeko - {clean_name}",
                    links=[
                        EpisodeStream(
                            link=embed_url,
                            quality="auto",
                            translation_type=translation_type,
                            hls=False,
                        )
                    ],
                    subtitles=subtitles,
                    headers={"Referer": constants.ANINEKO_BASE_URL},
                )
                servers.append(server_obj)
            except Exception as e:
                logger.warning(
                    f"Failed to pre-process server '{item[0]}' for "
                    f"'{slug}' episode {ep_num}: {e}"
                )

        def server_sort_key(s):
            name_lower = s.name.lower()
            preferred_type = getattr(params, "translation_type", "sub")
            link_trans = s.links[0].translation_type
            link_trans_val = link_trans.value if hasattr(link_trans, "value") else str(link_trans)
            trans_prio = 0 if link_trans_val == preferred_type else 1

            if "hd-1" in name_lower:
                server_prio = 10
            elif "hd-2" in name_lower:
                server_prio = 20
            elif "streamhg" in name_lower:
                server_prio = 30
            elif "earnvids" in name_lower:
                server_prio = 40
            elif "doodstream" in name_lower:
                server_prio = 50
            else:
                server_prio = 100

            if "sort sub" in name_lower:
                sub_type_prio = 0
            elif "hard sub" in name_lower:
                sub_type_prio = 1
            else:
                sub_type_prio = 2

            return (trans_prio, server_prio, sub_type_prio, name_lower)

        servers.sort(key=server_sort_key)

        resolve_direct = getattr(params, "resolve_direct", True)
        if not resolve_direct:
            for s in servers:
                yield s
            return

        target_server = None
        requested_server = getattr(params, "server", None)
        if requested_server:
            target_server = next((s for s in servers if s.name.lower() == requested_server.lower()), None)

        if target_server:
            embed_url = target_server.links[0].link
            direct_url = self._try_extract_direct_url(embed_url)
            if direct_url:
                updated_link = target_server.links[0].model_copy(update={
                    "link": direct_url,
                    "hls": bool(
                        ".m3u8" in direct_url
                        or "master.txt" in direct_url
                        or "master.m3u8" in direct_url
                    )
                })
                target_server = target_server.model_copy(update={
                    "links": [updated_link]
                })
            yield target_server
            return

        for s in servers:
            embed_url = s.links[0].link
            direct_url = self._try_extract_direct_url(embed_url)
            if direct_url:
                updated_link = s.links[0].model_copy(update={
                    "link": direct_url,
                    "hls": bool(
                        ".m3u8" in direct_url
                        or "master.txt" in direct_url
                        or "master.m3u8" in direct_url
                    )
                })
                s_copy = s.model_copy(update={
                    "links": [updated_link]
                })
                yield s_copy
                return

        if servers:
            yield servers[0]

    def _try_extract_direct_url(self, embed_url: str) -> Optional[str]:
        vibe_match = re.search(r"vibeplayer\.site/(\w+)", embed_url)
        if vibe_match:
            vid = vibe_match.group(1)
            return f"https://vibeplayer.site/public/stream/{vid}/master.m3u8"

        otaku_match = re.search(r"otakuvid\.com/(\w+)", embed_url)
        if otaku_match:
            vid = otaku_match.group(1)
            return f"https://otakuvid.com/public/stream/{vid}/master.m3u8"

        try:
            response = self.client.get(embed_url, follow_redirects=True)
            response.raise_for_status()

            text = response.text

            packed_matches = re.finditer(
                r"eval\(function\(p,a,c,k,e,d\).*?\}\('(.*?)'\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*'(.*?)'\.split\('\|'\)\)\)",
                text,
                re.DOTALL
            )
            for match in packed_matches:
                p, a, c, k_str = match.groups()
                try:
                    unpacked = _unpack_async(p, int(a), int(c), k_str.split('|'))
                    text += "\n" + unpacked
                except Exception as e:
                    logger.debug(f"Failed to unpack obfuscated JS: {e}")

            for pattern in [
                r'"hls\d*"\s*:\s*["\']([^"\']+(?:\.mp4|\.m3u8|master\.txt)[^"\']*)["\']',
                r'source\s*:\s*["\']([^"\']+\.m3u8[^"\']*)["\']',
                r'src\s*:\s*["\']([^"\']+(?:\.mp4|\.m3u8)[^"\']*)["\']',
                r'file\s*:\s*["\']([^"\']+(?:\.mp4|\.m3u8)[^"\']*)["\']',
                r'"file"\s*:\s*"([^"]+(?:\.mp4|\.m3u8)[^"]*)"',
                r'const\s+src\s*=\s*["\']([^"\']+\.m3u8[^"\']*)["\']',
            ]:
                match = re.search(pattern, text, re.IGNORECASE)
                if match:
                    raw_link = match.group(1)
                    return urljoin(embed_url, raw_link)
        except Exception as e:
            logger.debug(f"Error extracting direct stream URL from {embed_url}: {e}")

        return None
