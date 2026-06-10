"""AniNeko scraper microservice - isolated Python process for provider scraping.

Launched on-demand by the Rust core. Self-terminates after 60s idle.
Communicates via HTTP on localhost ephemeral port.
"""

import argparse
import time
import uvicorn
from fastapi import FastAPI, Query
from anineko import AniNekoProvider

app = FastAPI(title="Anicat Scraper", docs_url=None, redoc_url=None)
provider = AniNekoProvider()
_last_used = time.monotonic()


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.get("/last_used")
async def last_used():
    seconds = time.monotonic() - _last_used
    return {"seconds_since_last_use": seconds}


@app.get("/search")
async def search(query: str = Query(...)):
    global _last_used
    _last_used = time.monotonic()

    results = await provider.search(query)
    return [
        {"id": r.id, "title": r.title, "year": r.year}
        for r in results
    ]


@app.get("/get")
async def get_anime(slug: str = Query(...)):
    global _last_used
    _last_used = time.monotonic()

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
    global _last_used
    _last_used = time.monotonic()

    servers = await provider.streams(slug, episode)
    return [
        {
            "name": s.name,
            "url": s.url,
            "quality": s.quality,
            "is_m3u8": s.is_m3u8,
            "headers": s.headers,
        }
        for s in servers
    ]


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=19876)
    args = parser.parse_args()

    uvicorn.run(app, host="127.0.0.1", port=args.port, log_level="warning")
