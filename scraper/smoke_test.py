"""Daily provider smoke test, run on the Pi by anicat-smoke.timer.

Exercises each provider with a known-good query so scraper breakage is
noticed before anyone tries to watch something:

  - anineko:     search (goes through the Cloudflare clearance path)
  - mkissa:      search + get (exercises the AES-GCM/aaReq handshake)
  - mangakatana: search
  - nyaa:        SubsPlease API + Nyaa RSS reachability (the Rust side owns
                 the real logic; this just proves the upstreams answer)

Prints one OK/FAIL line per check, exits nonzero if any check failed.
Runnable by hand from scraper/: uv run python smoke_test.py
"""

import asyncio
import sys

from curl_cffi.requests import AsyncSession

SEARCH_QUERY = "frieren"
MANGA_QUERY = "one piece"

results: list[tuple[str, bool, str]] = []


async def run_check(name: str, coro, timeout: float):
    try:
        detail = await asyncio.wait_for(coro, timeout=timeout)
        results.append((name, True, detail))
    except Exception as e:  # noqa: BLE001 - report everything, this is a probe
        results.append((name, False, f"{type(e).__name__}: {e}"))


async def check_anineko() -> str:
    from anineko import AniNekoProvider

    refs = await AniNekoProvider().search(SEARCH_QUERY)
    if not refs:
        raise RuntimeError(f"search '{SEARCH_QUERY}' returned 0 results")
    return f"{len(refs)} results, first: {refs[0].title}"


async def check_mkissa() -> str:
    from mkissa import MkissaProvider

    prov = MkissaProvider()
    refs = await prov.search(SEARCH_QUERY)
    if not refs:
        raise RuntimeError(f"search '{SEARCH_QUERY}' returned 0 results")
    info = await prov.get(refs[0].id)
    if info is None or not info.episodes:
        raise RuntimeError(f"get('{refs[0].id}') returned no episodes")
    return f"{len(refs)} results, {info.title}: {len(info.episodes)} episodes"


async def check_mangakatana() -> str:
    from mangakatana import MangaKatanaProvider

    refs = await MangaKatanaProvider().search(MANGA_QUERY)
    if not refs:
        raise RuntimeError(f"search '{MANGA_QUERY}' returned 0 results")
    return f"{len(refs)} results"


async def check_subsplease() -> str:
    async with AsyncSession(impersonate="chrome") as s:
        r = await s.get(
            "https://subsplease.org/api/?f=search&tz=UTC&s=one%20piece",
            timeout=30,
        )
        r.raise_for_status()
        data = r.json()
    if not data:
        raise RuntimeError("search API returned empty result")
    return f"{len(data)} releases"


async def check_nyaa_rss() -> str:
    async with AsyncSession(impersonate="chrome") as s:
        r = await s.get(
            "https://nyaa.si/?page=rss&c=1_2&f=0&s=seeders&o=desc&q=subsplease%201080",
            timeout=30,
        )
        r.raise_for_status()
        body = r.text
    if "<item>" not in body:
        raise RuntimeError("RSS feed contained no <item> entries")
    return f"feed ok, {body.count('<item>')} items"


async def main() -> int:
    # anineko may spin up headless Chromium for Cloudflare clearance, so it
    # gets a much larger timeout than the plain-HTTP checks.
    await run_check("anineko", check_anineko(), timeout=300)
    await run_check("mkissa", check_mkissa(), timeout=120)
    await run_check("mangakatana", check_mangakatana(), timeout=60)
    await run_check("subsplease", check_subsplease(), timeout=45)
    await run_check("nyaa-rss", check_nyaa_rss(), timeout=45)

    failed = 0
    for name, ok, detail in results:
        print(f"{'OK  ' if ok else 'FAIL'} {name}: {detail}")
        if not ok:
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
