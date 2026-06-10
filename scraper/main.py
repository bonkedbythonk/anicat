"""AniNeko scraper microservice - isolated Python process for provider scraping.

Launched on-demand by the Rust core. Self-terminates after 60s idle.
Communicates via HTTP on localhost ephemeral port.
"""

import argparse
import time
import uvicorn
from fastapi import FastAPI, Query
from fastapi.responses import JSONResponse
from anineko import AniNekoProvider

app = FastAPI(title="Anicat Scraper", docs_url=None, redoc_url=None)
provider = AniNekoProvider()
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
async def search(query: str = Query(...)):
    _touch()
    results = await provider.search(query)
    return [{"id": r.id, "title": r.title, "year": r.year} for r in results]


@app.get("/get")
async def get_anime(slug: str = Query(...)):
    _touch()
    info = await provider.get(slug)
    if info is None:
        return {"title": "", "episodes": []}
    return {
        "title": info.title,
        "episodes": [
            {"number": ep.number, "title": ep.title, "image": ep.image}
            for ep in info.episodes
        ],
    }


@app.get("/streams")
async def get_streams(slug: str = Query(...), episode: int = Query(...)):
    _touch()
    servers, _ = await provider.streams(slug, episode, debug=False)
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


@app.get("/debug/streams")
async def debug_streams(slug: str = Query(...), episode: int = Query(...)):
    _touch()
    import re, json as _json

    try:
        url = f"https://anineko.to/watch/{slug}/ep-{episode}"
        resp = provider.session.get(url, timeout=30)
        html = resp.text
        html_len = len(html)
        page_title = ""
        tm = re.search(r"<title>([^<]+)</title>", html)
        if tm:
            page_title = tm.group(1).strip()

        # Collect all diagnostic data
        all_iframes = re.findall(r'<iframe[^>]+src\s*=\s*"([^"]+)"', html)
        all_video_sources = re.findall(r'<video[^>]+src\s*=\s*"([^"]+)"', html)
        all_data_video = re.findall(r'data-video\s*=\s*"([^"]+)"', html)
        all_script_tags = re.findall(
            r"<script[^>]*>(.{1,300})", html, re.DOTALL
        )[:10]
        all_m3u8 = re.findall(r'["\']([^"\']+\.m3u8[^"\']*)["\']', html, re.IGNORECASE)
        all_mp4 = re.findall(r'["\']([^"\']+\.mp4[^"\']*)["\']', html, re.IGNORECASE)
        all_embed = re.findall(r'["\']([^"\']+/embed/[^"\']*)["\']', html, re.IGNORECASE)

        # Run full debug pipeline
        sources, debug_passes = await provider.streams(slug, episode, debug=True)

        # Player area snippet
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
            "user_agent": provider.session.headers.get("User-Agent", ""),
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


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=19876)
    args = parser.parse_args()
    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
