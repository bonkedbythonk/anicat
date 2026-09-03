import time
from typing import Optional, List, Dict, Any
from urllib.parse import quote_plus
from curl_cffi import requests

from diagnostics import warn_empty

BASE_URL = "https://api.mangadex.org"
UPLOADS_URL = "https://uploads.mangadex.org"


class MangaDexProvider:
    def __init__(self):
        self.session = requests.Session(impersonate="chrome131")
        self.session.headers.update(
            {
                "User-Agent": "Anicat/5.2 (https://github.com/bonkedbythonk/anicat)",
                "Accept": "application/json",
            }
        )
        self._cache: Dict[str, tuple[float, dict]] = {}
        self._cache_ttl = 900.0  # 15 minutes

    async def warmup(self):
        try:
            self.session.get(f"{BASE_URL}/ping", timeout=5)
        except Exception:
            pass

    async def search(self, query: str, anilist_id: Optional[int] = None) -> List[dict]:
        try:
            url = (
                f"{BASE_URL}/manga?title={quote_plus(query)}"
                f"&limit=25&includes[]=cover_art"
                f"&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica"
                f"&order[relevance]=desc"
            )
            resp = self.session.get(url, timeout=20)
            if resp.status_code != 200:
                return []
            data = resp.json()
            return self._parse_search_results(data, anilist_id=anilist_id)
        except Exception as e:
            print(f"[MANGADEX] Search error: {e}")
            return []

    @staticmethod
    def _parse_search_results(data: dict, anilist_id: Optional[int] = None) -> List[dict]:
        items = data.get("data", [])
        if not items:
            warn_empty("mangadex", "data", "search results")
            return []

        results = []
        al_matched = []
        for item in items:
            manga_id = item.get("id", "")
            attrs = item.get("attributes", {})
            title_obj = attrs.get("title", {})
            title = (
                title_obj.get("en")
                or title_obj.get("ja-ro")
                or next(iter(title_obj.values()), "Unknown")
            )

            cover_image = ""
            for rel in item.get("relationships", []):
                if rel.get("type") == "cover_art":
                    filename = rel.get("attributes", {}).get("fileName")
                    if filename:
                        cover_image = f"{UPLOADS_URL}/covers/{manga_id}/{filename}.512.jpg"
                    break

            entry = {
                "id": manga_id,
                "title": title,
                "cover_image": cover_image,
            }

            links = attrs.get("links") or {}
            al_link = links.get("al")
            if anilist_id and al_link and str(al_link) == str(anilist_id):
                al_matched.append(entry)
            else:
                results.append(entry)

        # Prioritize exact AniList ID match if found
        return al_matched + results

    async def get(self, manga_id: str) -> Optional[dict]:
        now = time.monotonic()
        if manga_id in self._cache:
            ts, cached = self._cache[manga_id]
            if now - ts < self._cache_ttl:
                return cached

        try:
            # 1. Fetch manga details for title and cover
            detail_url = f"{BASE_URL}/manga/{manga_id}?includes[]=cover_art"
            resp = self.session.get(detail_url, timeout=20)
            if resp.status_code != 200:
                return None
            detail_data = resp.json()
            manga_obj = detail_data.get("data", {})
            attrs = manga_obj.get("attributes", {})
            title_obj = attrs.get("title", {})
            title = (
                title_obj.get("en")
                or title_obj.get("ja-ro")
                or next(iter(title_obj.values()), "Unknown")
            )

            cover_image = ""
            for rel in manga_obj.get("relationships", []):
                if rel.get("type") == "cover_art":
                    filename = rel.get("attributes", {}).get("fileName")
                    if filename:
                        cover_image = f"{UPLOADS_URL}/covers/{manga_id}/{filename}.512.jpg"
                    break

            # 2. Fetch chapter feed (up to 1000 chapters)
            feed_items = []
            limit = 500
            for offset in (0, 500):
                feed_url = (
                    f"{BASE_URL}/manga/{manga_id}/feed?"
                    f"translatedLanguage[]=en&includeExternalUrl=0&limit={limit}&offset={offset}&order[chapter]=asc"
                    f"&contentRating[]=safe&contentRating[]=suggestive&contentRating[]=erotica"
                )
                feed_resp = self.session.get(feed_url, timeout=20)
                if feed_resp.status_code != 200:
                    break
                feed_json = feed_resp.json()
                batch = feed_json.get("data", [])
                feed_items.extend(batch)
                if len(batch) < limit or feed_json.get("total", 0) <= offset + limit:
                    break

            info = self._parse_feed(feed_items, title=title, cover_image=cover_image)
            self._cache[manga_id] = (now, info)
            return info
        except Exception as e:
            print(f"[MANGADEX] Get error: {e}")
            return None

    @staticmethod
    def _parse_feed(feed_items: List[dict], title: str, cover_image: str) -> dict:
        if not feed_items:
            warn_empty("mangadex", "feed data", f"detail page '{title}'")
            return {
                "title": title,
                "cover_image": cover_image,
                "chapters": [],
            }

        chapters_map: Dict[str, dict] = {}
        for ch in feed_items:
            ch_attrs = ch.get("attributes", {})
            if ch_attrs.get("pages", 0) <= 0 or ch_attrs.get("externalUrl"):
                continue

            ch_num_str = ch_attrs.get("chapter")
            if not ch_num_str:
                continue

            try:
                ch_num_float = float(ch_num_str)
                num_val = int(ch_num_float) if ch_num_float.is_integer() else ch_num_float
            except ValueError:
                continue

            ch_title = ch_attrs.get("title")
            display_title = f"Chapter {ch_num_str}"
            if ch_title:
                display_title = f"{display_title}: {ch_title}"

            pages_count = ch_attrs.get("pages", 0)
            if ch_num_str not in chapters_map or pages_count > chapters_map[ch_num_str]["_pages"]:
                chapters_map[ch_num_str] = {
                    "number": num_val,
                    "title": display_title,
                    "url": ch["id"],
                    "_sort_key": ch_num_float,
                    "_pages": pages_count,
                }

        sorted_chapters = sorted(chapters_map.values(), key=lambda x: x["_sort_key"])

        # Fallback for oneshots / single chapter items with no chapter number
        if not sorted_chapters and feed_items:
            for ch in feed_items:
                ch_attrs = ch.get("attributes", {})
                if ch_attrs.get("pages", 0) > 0 and not ch_attrs.get("externalUrl"):
                    ch_title = ch_attrs.get("title") or "Oneshot"
                    sorted_chapters.append(
                        {
                            "number": 1,
                            "title": f"Chapter 1: {ch_title}",
                            "url": ch["id"],
                        }
                    )
                    break

        for ch in sorted_chapters:
            ch.pop("_sort_key", None)
            ch.pop("_pages", None)

        return {
            "title": title,
            "cover_image": cover_image,
            "chapters": sorted_chapters,
        }

    async def get_pages(self, chapter_id: str) -> Optional[dict]:
        try:
            url = f"{BASE_URL}/at-home/server/{chapter_id}"
            resp = self.session.get(url, timeout=20)
            if resp.status_code != 200:
                return None
            data = resp.json()
            return self._parse_at_home(data, chapter_id)
        except Exception as e:
            print(f"[MANGADEX] Get chapter pages error: {e}")
            return None

    @staticmethod
    def _parse_at_home(data: dict, chapter_id: str) -> Optional[dict]:
        base_url = data.get("baseUrl")
        ch_obj = data.get("chapter", {})
        ch_hash = ch_obj.get("hash")
        files = ch_obj.get("data", [])

        if not base_url or not ch_hash or not files:
            warn_empty("mangadex", "chapter.data", f"chapter '{chapter_id}'")
            return None

        image_urls = [f"{base_url}/data/{ch_hash}/{f}" for f in files]
        return {
            "thumbnails": image_urls,
            "title": chapter_id,
        }
