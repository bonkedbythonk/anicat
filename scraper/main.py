"""AniNeko scraper microservice - isolated Python process for provider scraping.

Launched on-demand by the Rust core. Self-terminates after 60s idle.
Communicates via HTTP on localhost ephemeral port.
"""

import argparse
import time
import uvicorn
import logging
import sys
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse

# Configure logging
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
    elif name == "mkissa":
        from mkissa import MkissaProvider
        PROVIDERS["mkissa"] = MkissaProvider()
    elif name == "mangakatana":
        from mangakatana import MangaKatanaProvider
        PROVIDERS["mangakatana"] = MangaKatanaProvider()
    return PROVIDERS[name]

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


@app.get("/search")
async def search(query: str = Query(...), provider: str = Query("anineko")):
    _touch()
    try:
        prov = _load_provider(provider)
        results = await prov.search(query)
        return [{"id": r.id, "title": r.title, "year": r.year if hasattr(r, "year") else None} for r in results]
    except Exception as e:
        logger.exception(f"Search failed for query='{query}' provider='{provider}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/get")
async def get_anime(slug: str = Query(...), provider: str = Query("anineko")):
    _touch()
    try:
        prov = _load_provider(provider)
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
async def get_streams(slug: str = Query(...), episode: int = Query(...), provider: str = Query("anineko")):
    _touch()
    try:
        prov = _load_provider(provider)
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
    if provider == "mkissa":
        try:
            servers, debug_log = await prov.streams(slug, episode, debug=True)
            result = {
                "slug": slug,
                "episode": episode,
                "request_url": "https://api.allanime.day/api",
                "final_url": "https://api.allanime.day/api",
                "page_title": "Mkissa API debug",
                "html_length": 0,
                "html_snippet": "JSON API endpoint used",
                "user_agent": prov.session.headers.get("User-Agent", ""),
                "all_iframes": [],
                "all_video_sources": [],
                "all_data_video_attrs": [],
                "all_script_tags_trimmed": [],
                "all_candidate_urls": [s.url for s in servers],
                "all_m3u8_urls": [s.url for s in servers if s.is_m3u8],
                "all_mp4_urls": [s.url for s in servers if not s.is_m3u8],
                "all_embed_urls": [],
                "debug_passes": debug_log,
                "final_streams": [
                    {
                        "name": s.name,
                        "url": s.url,
                        "quality": s.quality or "unknown",
                        "is_m3u8": s.is_m3u8 or False,
                        "group": s.group,
                        "source_type": s.source_type,
                    }
                    for s in servers
                ],
                "errors": [],
            }
            return JSONResponse(content=result)
        except Exception as e:
            return JSONResponse(
                status_code=500,
                content={"slug": slug, "episode": episode, "errors": [str(e)]},
            )

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
async def manga_search(query: str = Query(...)):
    _touch()
    try:
        prov = _load_provider("mangakatana")
        results = await prov.search(query)
        return [{"id": r["id"], "title": r["title"], "year": None} for r in results]
    except Exception as e:
        logger.exception(f"Manga search failed for query='{query}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.get("/manga/get")
async def get_manga(slug: str = Query(...)):
    _touch()
    try:
        prov = _load_provider("mangakatana")
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
        logger.exception(f"Manga get failed for slug='{slug}'")
        return {"title": "", "episodes": [], "error": str(e)}


@app.get("/manga/chapter")
async def get_chapter(slug: str = Query(...), chapter: str = Query(...)):
    _touch()
    try:
        prov = _load_provider("mangakatana")
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
        logger.exception(f"Manga chapter failed for slug='{slug}' chapter='{chapter}'")
        return JSONResponse(status_code=500, content={"error": str(e)})


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=19876)
    args = parser.parse_args()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
