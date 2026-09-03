"""Anicat scraper microservice - isolated Python process for provider scraping.

Launched on-demand by the Rust core. Self-terminates after 60s idle.
Communicates via HTTP on localhost ephemeral port.

Every endpoint below takes the provider to use as a required parameter -- it
used to default to "anineko", which is now retired, so a caller that forgot to
name one silently got a dead provider (and, because `_load_provider` answers
None for anything it doesn't know, an AttributeError rather than a message
saying so). The Rust client has always named the provider explicitly.
"""

import argparse
import os
import threading
import time
import uvicorn
import logging
import sys
from typing import Optional, List, Dict, Any, Union
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

logging.basicConfig(
    level=logging.INFO,
    format="[%(levelname)s] %(name)s: %(message)s",
    stream=sys.stderr,
)
logger = logging.getLogger("anicat-scraper")

PROVIDERS: dict[str, object | None] = {}

def _load_provider(name: str) -> object:
    if name in PROVIDERS and PROVIDERS[name] is not None:
        return PROVIDERS[name]
    if name == "anineko":
        from anineko import AniNekoProvider
        PROVIDERS["anineko"] = AniNekoProvider()
    elif name == "mangakatana":
        from mangakatana import MangaKatanaProvider
        PROVIDERS["mangakatana"] = MangaKatanaProvider()
    elif name == "mangadex":
        from mangadex import MangaDexProvider
        PROVIDERS["mangadex"] = MangaDexProvider()
    return PROVIDERS.get(name)


def _require_provider(name: str) -> object:
    """Load a provider, or raise with a message naming the one that was asked for.

    `_load_provider` answers None for a name it has no branch for, and every
    caller went straight on to call a method on it -- so asking for a provider
    this sidecar doesn't implement (a retired one, or an anime provider the
    Rust side serves itself, like nyaa) surfaced as "'NoneType' object has no
    attribute 'search'" in the app's error toast.
    """
    prov = _load_provider(name)
    if prov is None:
        raise ValueError(f"unknown provider: {name!r}")
    return prov

app = FastAPI(title="Anicat Scraper", docs_url=None, redoc_url=None)
_last_used = time.monotonic()

def _touch():
    global _last_used
    _last_used = time.monotonic()


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/last_used")
async def last_used():
    return {"seconds_since_last_use": time.monotonic() - _last_used}


@app.get("/warmup")
async def warmup(provider: str = Query(...)):
    """Do a provider's expensive first-request work now, off the play path.

    Importing a provider module (curl_cffi and friends), constructing it, and
    letting it reach its site once is most of what makes the first stream
    lookup of a session slow. The Rust side calls this right after spawning
    the sidecar, while the user is still browsing.

    Always answers 200: a warm-up is best-effort by definition, and a failure
    here must not read as "the sidecar is broken" to the caller -- the first
    real request will simply pay the cost it always paid.
    """
    try:
        prov = _load_provider(provider)
        if prov is None:
            return {"warmed": False, "reason": f"unknown provider: {provider}"}
        warm = getattr(prov, "warmup", None)
        if warm is None:
            # Import + construction alone is still a real chunk of the cost.
            return {"warmed": True, "detail": "loaded"}
        await warm()
        return {"warmed": True}
    except Exception as e:
        logger.warning("Warmup failed for %s: %s", provider, e)
        return {"warmed": False, "reason": str(e)}


@app.get("/search")
async def search(query: str = Query(...), provider: str = Query(...)):
    _touch()
    try:
        prov = _require_provider(provider)
        results = await prov.search(query)
        return [{"id": r.id, "title": r.title, "year": r.year if hasattr(r, "year") else None} for r in results]
    except Exception as e:
        logger.exception(f"Search failed for query='{query}' provider='{provider}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/get")
async def get_anime(slug: str = Query(...), provider: str = Query(...)):
    _touch()
    try:
        prov = _require_provider(provider)
        info = await prov.get(slug)
        if info is None:
            return {"title": "", "episodes": []}
        return {
            "title": info.title,
            "episodes": [
                {"number": ep.number, "title": ep.title if hasattr(ep, "title") else None, "image": ep.image if hasattr(ep, "image") else None}
                for ep in info.episodes
            ],
        }
    except Exception as e:
        logger.exception(f"Get failed for slug='{slug}' provider='{provider}'")
        return {"title": "", "episodes": [], "error": str(e)}


@app.get("/streams")
async def get_streams(slug: str = Query(...), episode: int = Query(...), provider: str = Query(...)):
    _touch()
    try:
        prov = _require_provider(provider)
        servers, _ = await prov.streams(slug, episode, debug=False)
        return [
            {
                "name": s.name,
                "url": s.url,
                "quality": s.quality,
                "is_m3u8": s.is_m3u8,
                "headers": s.headers,
                "group": s.group,
                "source_type": s.source_type,
                "subtitle_url": s.subtitle_url,
                # Whether a browser-based player can decode this one, for the
                # desktop builtin <video> player. Read with getattr rather than
                # s.browser_ok because providers predating the field don't set
                # it, and those are reported browser-capable -- the behaviour
                # that shipped before the field existed.
                "browser_ok": getattr(s, "browser_ok", True),
            }
            for s in servers
        ]
    except Exception as e:
        logger.exception(f"Streams failed for slug='{slug}' episode={episode} provider='{provider}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/debug/streams")
async def debug_streams(slug: str = Query(...), episode: int = Query(...), provider: str = Query("anineko")):
    _touch()
    prov = _load_provider(provider)

    import re

    try:
        url = f"https://anineko.to/watch/{slug}/ep-{episode}"
        resp = prov.session.get(url, timeout=30)
        html = resp.text
        html_len = len(html)
        page_title = ""
        tm = re.search(r"<title>([^<]+)</title>", html)
        if tm:
            page_title = tm.group(1).strip()

        all_iframes = re.findall(r'<iframe[^>]+src\s*=\s*"([^"]+)"', html)
        all_video_sources = re.findall(r'<video[^>]+src\s*=\s*"([^"]+)"', html)
        all_data_video = re.findall(r'data-video\s*=\s*"([^"]+)"', html)
        all_script_tags = re.findall(
            r"<script[^>]*>(.{1,300})", html, re.DOTALL
        )[:10]
        all_m3u8 = re.findall(r'["\']([^"\']+\.m3u8[^"\']*)["\']', html, re.IGNORECASE)
        all_mp4 = re.findall(r'["\']([^"\']+\.mp4[^"\']*)["\']', html, re.IGNORECASE)
        all_embed = re.findall(r'["\']([^"\']+/embed/[^"\']*)["\']', html, re.IGNORECASE)

        sources, debug_passes = await prov.streams(slug, episode, debug=True)

        player_idx = html.find("data-video")
        html_snippet = html[max(0, player_idx - 500):player_idx + 1500] if player_idx >= 0 else ""

        result = {
            "slug": slug,
            "episode": episode,
            "request_url": url,
            "final_url": str(resp.url),
            "page_title": page_title,
            "html_length": html_len,
            "html_snippet": html_snippet[:2000],
            "user_agent": prov.session.headers.get("User-Agent", ""),
            "all_iframes": all_iframes,
            "all_video_sources": all_video_sources,
            "all_data_video_attrs": all_data_video,
            "all_script_tags_trimmed": [t.strip()[:300] for t in all_script_tags],
            "all_candidate_urls": all_data_video + all_m3u8 + all_mp4 + all_embed,
            "all_m3u8_urls": all_m3u8,
            "all_mp4_urls": all_mp4,
            "all_embed_urls": all_embed,
            "debug_passes": debug_passes,
            "final_streams": [
                {
                    "name": s.name,
                    "url": s.url,
                    "quality": s.quality or "unknown",
                    "is_m3u8": s.is_m3u8 or False,
                    "group": s.group,
                    "source_type": s.source_type,
                }
                for s in sources
            ],
            "errors": [],
        }
        return JSONResponse(content=result)
    except Exception as e:
        return JSONResponse(
            status_code=500,
            content={"slug": slug, "episode": episode, "errors": [str(e)]},
        )


@app.get("/debug/test")
async def debug_test():
    """Hardcoded test on classroom-of-the-elite-iv episode 1."""
    _touch()
    return await debug_streams(
        slug="classroom-of-the-elite-iv", episode=1
    )


@app.get("/manga/search")
async def manga_search(
    query: str = Query(...),
    provider: str = Query("mangadex"),
    anilist_id: Optional[int] = Query(None),
):
    _touch()
    try:
        prov = _require_provider(provider)
        if hasattr(prov, "search"):
            import inspect
            sig = inspect.signature(prov.search)
            if "anilist_id" in sig.parameters:
                results = await prov.search(query, anilist_id=anilist_id)
            else:
                results = await prov.search(query)
        else:
            results = []
        return [{"id": r["id"], "title": r["title"], "year": None} for r in results]
    except Exception as e:
        logger.exception(f"Manga search failed for query='{query}' provider='{provider}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/manga/get")
async def get_manga(slug: str = Query(...), provider: str = Query("mangadex")):
    _touch()
    try:
        prov = _require_provider(provider)
        info = await prov.get(slug)
        if info is None:
            return {"title": "", "episodes": []}
        return {
            "title": info["title"],
            "episodes": [
                {"number": ep["number"], "title": ep["title"], "image": ep.get("image")}
                for ep in info["chapters"]
            ],
        }
    except Exception as e:
        logger.exception(f"Manga get failed for slug='{slug}' provider='{provider}'")
        return {"title": "", "episodes": [], "error": str(e)}


@app.get("/manga/chapter")
async def get_chapter(
    slug: str = Query(...),
    chapter: str = Query(...),
    provider: str = Query("mangadex"),
):
    _touch()
    try:
        prov = _require_provider(provider)
        info = await prov.get(slug)
        if not info or not info.get("chapters"):
            return {"thumbnails": [], "title": ""}

        target_ch = None
        for ep in info["chapters"]:
            if str(ep["number"]) == chapter:
                target_ch = ep
                break

        if not target_ch:
            try:
                ch_float = float(chapter)
                for ep in info["chapters"]:
                    if abs(float(ep["number"]) - ch_float) < 0.01:
                        target_ch = ep
                        break
            except ValueError:
                pass

        if not target_ch:
            return {"thumbnails": [], "title": ""}

        pages_info = await prov.get_pages(target_ch["url"])
        if not pages_info:
            return {"thumbnails": [], "title": ""}
        return pages_info
    except Exception as e:
        logger.exception(f"Manga chapter failed for slug='{slug}' chapter='{chapter}' provider='{provider}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/novel/presets")
async def get_novel_presets():
    _touch()
    return [
        {
            "id": "xteink_x3",
            "name": "Xteink X3 (3.97\" E-Ink)",
            "width": 528,
            "height": 792,
            "grayscale": True,
            "quality": 85,
            "split_spreads": True,
            "description": "Native 528x792 8-bit grayscale optimization for Xteink X3"
        },
        {
            "id": "xteink_x4",
            "name": "Xteink X4 (4.3\" E-Ink)",
            "width": 480,
            "height": 800,
            "grayscale": True,
            "quality": 85,
            "split_spreads": True,
            "description": "Native 480x800 resolution for Xteink X4"
        },
        {
            "id": "kindle_pw",
            "name": "Kindle Paperwhite (6.8\" / 300 PPI)",
            "width": 1072,
            "height": 1448,
            "grayscale": True,
            "quality": 85,
            "split_spreads": True,
            "description": "High-res 300 PPI layout for Kindle Paperwhite"
        },
        {
            "id": "kindle_basic",
            "name": "Kindle Basic (6.0\")",
            "width": 600,
            "height": 800,
            "grayscale": True,
            "quality": 85,
            "split_spreads": True,
            "description": "600x800 portrait layout for Kindle Basic"
        },
        {
            "id": "kobo_clara",
            "name": "Kobo Clara 2E / BW (6.0\")",
            "width": 1072,
            "height": 1448,
            "grayscale": True,
            "quality": 85,
            "split_spreads": True,
            "description": "Crisp 300 PPI layout for Kobo Clara"
        },
        {
            "id": "kobo_libra",
            "name": "Kobo Libra / Color (7.0\")",
            "width": 1264,
            "height": 1680,
            "grayscale": False,
            "quality": 90,
            "split_spreads": True,
            "description": "High-res portrait layout with color illustration support"
        },
        {
            "id": "custom",
            "name": "Custom Resolution",
            "width": 528,
            "height": 792,
            "grayscale": True,
            "quality": 85,
            "split_spreads": True,
            "description": "User-defined screen resolution and grayscale settings"
        }
    ]


@app.get("/novel/search")
async def novel_search(query: str = Query(...), provider: str = Query("ranobedb")):
    _touch()
    try:
        from novel import RanobeDBClient, get_scraper_for_url
        if query.startswith("http://") or query.startswith("https://"):
            scraper = get_scraper_for_url(query)
            novel_info = scraper.get_novel_info(query)
            return [{
                "id": query,
                "title": novel_info.title,
                "romaji": None,
                "author": novel_info.author,
                "cover_url": novel_info.cover_image_url,
                "books_count": len(novel_info.chapters),
                "rating": None,
                "description": novel_info.description,
                "tags": [],
                "source_url": query
            }]

        client = RanobeDBClient()
        results = client.search_series(query)
        return [
            {
                "id": str(s.id),
                "title": s.display_title,
                "title_orig": s.title_orig,
                "romaji": s.romaji,
                "author": ", ".join(s.authors),
                "cover_url": s.primary_cover_url,
                "books_count": len(s.books),
                "rating": s.rating_score,
                "description": s.description,
                "tags": s.genres,
                "source_url": f"https://ranobedb.org/series/{s.id}"
            }
            for s in results
        ]
    except Exception as e:
        logger.exception(f"Novel search failed for query='{query}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/novel/get")
async def novel_get(slug: str = Query(...), provider: str = Query("ranobedb")):
    _touch()
    try:
        from novel import RanobeDBClient, get_scraper_for_url
        if slug.startswith("http://") or slug.startswith("https://"):
            from novel.scrapers.lnori import LnoriScraper
            scraper = get_scraper_for_url(slug)

            # A Lnori series page links one page per volume, each holding a whole
            # book. Listing the volumes is one fetch; reading every volume's
            # table of contents up front would be dozens, so leave that to
            # /novel/toc when a volume is actually opened.
            if isinstance(scraper, LnoriScraper) and "/series/" in slug:
                volumes = scraper.list_volumes(slug)
                series_id = scraper.extract_series_id(slug)
                series_info = None
                if series_id:
                    try:
                        series_info = RanobeDBClient().get_series(series_id)
                    except Exception as ex:
                        logger.warning("RanobeDB lookup failed for Lnori series %s: %s", series_id, ex)
                return {
                    "id": slug,
                    "title": series_info.display_title if series_info else slug,
                    "romaji": series_info.romaji if series_info else None,
                    "author": ", ".join(series_info.authors) if series_info else "",
                    "description": series_info.description if series_info else "",
                    "cover_url": series_info.primary_cover_url if series_info else None,
                    "books": [
                        {"id": bid, "title": vtitle, "url": vurl, "sort_order": idx}
                        for idx, (bid, vtitle, vurl) in enumerate(volumes, 1)
                    ],
                    "source_url": slug,
                    "text_source_url": slug,
                }

            novel_info = scraper.get_novel_info(slug)
            return {
                "id": slug,
                "title": novel_info.title,
                "romaji": None,
                "author": novel_info.author,
                "description": novel_info.description,
                "cover_url": novel_info.cover_image_url,
                "books": [
                    {
                        "id": ch.index,
                        "title": ch.title,
                        "volume_name": ch.volume_name,
                        "url": ch.url,
                        "cover_url": novel_info.cover_image_url,
                    }
                    for ch in novel_info.chapters
                ],
                "chapters": [
                    {
                        "index": ch.index,
                        "title": ch.title,
                        "volume_name": ch.volume_name,
                        "url": ch.url,
                    }
                    for ch in novel_info.chapters
                ],
                "source_url": slug
            }

        client = RanobeDBClient()
        series_id = int(slug) if slug.isdigit() else None
        if not series_id:
            results = client.search_series(slug, limit=1)
            if results:
                series_id = results[0].id

        if not series_id:
            return JSONResponse(status_code=404, content={"error": "Series not found"})

        series_info = client.get_series(series_id)

        # RanobeDB is metadata only. Lnori reuses its series and book ids and
        # does carry the text, so a series it stocks gets a readable URL per
        # volume; anything it does not stock stays URL-less and the reader says
        # so rather than inventing prose.
        text_source_url = None
        volume_urls = {}
        try:
            from novel.scrapers.lnori import LnoriScraper
            lnori = LnoriScraper()
            text_source_url = lnori.resolve_series_url(series_info.id)
            if text_source_url:
                volume_urls = {bid: url for bid, _title, url in lnori.list_volumes(text_source_url)}
        except Exception as ex:
            logger.warning("Lnori lookup failed for series %s: %s", series_id, ex)

        books_data = [
            {
                "id": b.id,
                "title": b.title or f"Volume {idx+1}",
                "romaji": b.romaji,
                "cover_url": b.image.url if b.image else None,
                "pages": b.pages,
                "release_date": b.release_date,
                "description": b.description,
                "sort_order": b.sort_order,
                "url": volume_urls.get(b.id),
            }
            for idx, b in enumerate(series_info.books)
        ]

        return {
            "id": str(series_info.id),
            "title": series_info.display_title,
            "title_orig": series_info.title_orig,
            "romaji": series_info.romaji,
            "author": ", ".join(series_info.authors),
            "artists": series_info.artists,
            "translators": series_info.translators,
            "publishers": [p.name for p in series_info.publishers],
            "description": series_info.description,
            "cover_url": series_info.primary_cover_url,
            "books": books_data,
            "tags": series_info.genres,
            "rating": series_info.rating_score,
            "source_url": f"https://ranobedb.org/series/{series_info.id}",
            "text_source_url": text_source_url,
        }
    except Exception as e:
        logger.exception(f"Novel get failed for slug='{slug}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/novel/toc")
async def novel_toc(url: str = Query(...), title: str = Query(None)):
    """Chapter list for one volume, read from that volume's own page."""
    _touch()
    if not (url.startswith("http://") or url.startswith("https://")):
        return JSONResponse(status_code=400, content={"error": "A volume URL is required"})
    try:
        from novel import get_scraper_for_url
        from novel.scrapers.lnori import LnoriScraper
        from bs4 import BeautifulSoup

        scraper = get_scraper_for_url(url)
        if isinstance(scraper, LnoriScraper):
            soup = BeautifulSoup(scraper.fetch_page(url), "html.parser")
            chapters = scraper.extract_toc(soup, url, volume_name=title)
        else:
            chapters = scraper.get_novel_info(url).chapters

        return {
            "url": url,
            "chapters": [
                {
                    "index": ch.index,
                    "title": ch.title,
                    "volume_name": ch.volume_name,
                    "url": ch.url,
                }
                for ch in chapters
            ],
        }
    except Exception as e:
        logger.exception(f"Novel toc fetch failed for url='{url}'")
        return JSONResponse(status_code=502, content={"error": str(e)})


@app.get("/novel/chapter")
async def novel_chapter(
    slug: str = Query(...),
    chapter: str = Query(...),
    url: str = Query(None)
):
    _touch()
    target_url = url or ""
    if not (target_url.startswith("http://") or target_url.startswith("https://")):
        return JSONResponse(
            status_code=404,
            content={"error": f"No readable text source for '{slug}'"},
        )
    try:
        from novel import get_scraper_for_url, Chapter
        scraper = get_scraper_for_url(target_url)
        ch_obj = Chapter(
            index=int(chapter) if chapter.isdigit() else 1,
            title=f"Chapter {chapter}",
            url=target_url,
        )
        scraper.fetch_chapter_content(ch_obj)
        if not ch_obj.content_html:
            return JSONResponse(
                status_code=502,
                content={"error": f"Source returned no text for chapter {chapter}"},
            )
        return {
            "title": ch_obj.title,
            "content_html": ch_obj.content_html,
            "content_text": ch_obj.content_text,
            "index": ch_obj.index,
            "volume_name": ch_obj.volume_name,
        }
    except Exception as e:
        logger.exception(f"Novel chapter fetch failed for slug='{slug}' chapter='{chapter}'")
        return JSONResponse(status_code=502, content={"error": str(e)})


from pydantic import BaseModel

class NovelBuildEpubRequest(BaseModel):
    slug: str
    volume_id: Optional[int] = None
    volume_title: Optional[str] = None
    target_width: int = 528
    target_height: int = 792
    grayscale: bool = True
    jpeg_quality: int = 85
    split_spreads: bool = True
    output_dir: Optional[str] = None


@app.post("/novel/build_epub")
async def novel_build_epub(req: NovelBuildEpubRequest):
    _touch()
    try:
        from novel import RanobeDBClient, build_novel_epub, get_scraper_for_url, Novel, Chapter
        output_dir = req.output_dir or os.path.expanduser("~/Downloads")
        os.makedirs(output_dir, exist_ok=True)

        novel = None
        series_info = None

        if req.slug.startswith("http://") or req.slug.startswith("https://"):
            try:
                scraper = get_scraper_for_url(req.slug)
                novel = scraper.get_novel_info(req.slug)
                for ch in novel.chapters[:50]:
                    scraper.fetch_chapter_content(ch)
            except Exception as ex:
                logger.warning("Scraper failed for URL %s: %s", req.slug, ex)

        if not novel:
            client = RanobeDBClient()
            series_id = int(req.slug) if req.slug.isdigit() else None
            if not series_id:
                try:
                    res = client.search_series(req.slug, limit=1)
                    if res:
                        series_id = res[0].id
                except Exception as ex:
                    logger.warning("RanobeDB search failed for %s: %s", req.slug, ex)

            if series_id:
                try:
                    series_info = client.get_series(series_id)
                except Exception as ex:
                    logger.warning("RanobeDB get_series failed for %s: %s", series_id, ex)

            if series_info:
                # Look for volume cover / metadata
                vol_title = req.volume_title
                vol_cover_url = None
                if req.volume_id:
                    for b in series_info.books:
                        if b.id == req.volume_id:
                            vol_title = b.title
                            if b.image:
                                vol_cover_url = b.image.url
                            break

                # Lnori carries the licensed text under RanobeDB's own ids, so
                # it is the first place to look for a real volume.
                # Only for a single requested volume: a whole-series EPUB would
                # mean fetching every volume page and every image in it, which
                # does not fit the request budget. Series-wide downloads stay on
                # the metadata compendium below.
                if req.volume_id:
                    try:
                        from novel.scrapers.lnori import LnoriScraper
                        lnori = LnoriScraper()
                        lnori_series = lnori.resolve_series_url(series_info.id)
                        if lnori_series:
                            target = next(
                                (u for bid, _t, u in lnori.list_volumes(lnori_series) if bid == req.volume_id),
                                None,
                            )
                            if target:
                                novel = lnori.get_novel_info(target)
                                for ch in novel.chapters:
                                    lnori.fetch_chapter_content(ch)
                    except Exception as ex:
                        logger.warning("Lnori epub source failed for series %s: %s", series_info.id, ex)

                # If web novel link exists in series_info
                if not novel and series_info.web_novel:
                    try:
                        scraper = get_scraper_for_url(series_info.web_novel)
                        novel = scraper.get_novel_info(series_info.web_novel)
                        for ch in novel.chapters[:50]:
                            scraper.fetch_chapter_content(ch)
                    except Exception as ex:
                        logger.warning("Failed to fetch web novel: %s", ex)

                if not novel:
                    chapters = []
                    for idx, b in enumerate(series_info.books, 1):
                        b_desc = b.description or "No synopsis available."
                        b_img = f'<p><img src="{b.image.url}" alt="{b.title}" /></p>' if b.image and b.image.url else ""
                        ch_html = f"""<div class="book-entry">
                          <h2>{b.title or f"Volume {idx}"}</h2>
                          {b_img}
                          <p><strong>Release Date:</strong> {b.release_date or 'Unknown'}</p>
                          <p><strong>Pages:</strong> {b.pages or 'Unknown'}</p>
                          <div class="synopsis">{b_desc}</div>
                        </div>"""
                        chapters.append(Chapter(
                            index=idx,
                            title=b.title or f"Volume {idx}",
                            url=f"urn:ranobedb:book:{b.id}",
                            volume_name=b.title,
                            content_html=ch_html
                        ))

                    novel = Novel(
                        title=series_info.display_title,
                        author=", ".join(series_info.authors) or "Light Novel",
                        description=series_info.description,
                        source_url=f"https://ranobedb.org/series/{series_info.id}",
                        cover_image_url=vol_cover_url or series_info.primary_cover_url,
                        chapters=chapters,
                        series_info=series_info,
                        language="en"
                    )

        if not novel:
            return JSONResponse(
                status_code=404,
                content={"error": f"No light novel source found for '{req.slug}'"},
            )

        final_path = build_novel_epub(
            novel=novel,
            output_path=output_dir,
            series_info=series_info,
            volume_title=req.volume_title,
            target_width=req.target_width,
            target_height=req.target_height,
            grayscale=req.grayscale,
            jpeg_quality=req.jpeg_quality,
            split_spreads=req.split_spreads
        )

        file_size = os.path.getsize(final_path) if os.path.exists(final_path) else 0
        filename = os.path.basename(final_path)

        return {
            "status": "ok",
            "file_path": final_path,
            "filename": filename,
            "file_size": file_size,
            "title": novel.title
        }
    except Exception as e:
        logger.exception("Build novel epub failed")
        return JSONResponse(status_code=500, content={"error": str(e)})


def _parent_alive(parent_pid: int) -> bool:
    """Best-effort liveness check for the Rust host process.

    A crash or force-quit skips Rust's own RunEvent::Exit shutdown path, so
    this sidecar never hears about it and is reparented to init/launchd
    instead of exiting -- confirmed in the wild as a pile of these processes
    still running days after the host they belonged to was gone.
    """
    if sys.platform == "win32":
        import ctypes

        PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
        STILL_ACTIVE = 259
        handle = ctypes.windll.kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, False, parent_pid)
        if not handle:
            return False
        try:
            exit_code = ctypes.c_ulong()
            ctypes.windll.kernel32.GetExitCodeProcess(handle, ctypes.byref(exit_code))
            return exit_code.value == STILL_ACTIVE
        finally:
            ctypes.windll.kernel32.CloseHandle(handle)
    try:
        # Signal 0 sends nothing; it only checks whether the pid is ownable.
        os.kill(parent_pid, 0)
        return True
    except OSError:
        return False


def _watch_parent(parent_pid: int | None = None):
    """Exit once the Rust host is gone.

    `parent_pid` is passed explicitly because in dev the host spawns this as
    `uv run python main.py`, so `os.getppid()` is the *uv wrapper*, not
    anicat. uv is reparented to init when anicat dies and keeps running, so
    the getppid() check succeeded forever and nothing ever self-terminated --
    55 orphaned sidecars, oldest two days old, each still holding its port.
    The fallback is only for a host that predates the flag.
    """
    if parent_pid is None:
        parent_pid = os.getppid()
    while True:
        time.sleep(10)
        if not _parent_alive(parent_pid):
            logger.warning("parent process (pid %d) is gone; self-terminating", parent_pid)
            os._exit(0)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=19876)
    parser.add_argument("--parent-pid", type=int, default=None)
    args = parser.parse_args()
    threading.Thread(target=_watch_parent, args=(args.parent_pid,), daemon=True).start()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
