"""Daily provider smoke test, run on the Pi by anicat-smoke.timer.

Exercises each provider with a known-good query so scraper breakage is
noticed before anyone tries to watch something:

  - anineko:     search (goes through the Cloudflare clearance path) + stream
                 resolution + proof that a *mobile-playable* server actually
                 serves segments. Search alone stayed green through a complete
                 mobile outage, so all three are asserted.
  - mkissa:      search + get + episode stream resolution (exercises the
                 AES-GCM/aaReq handshake and the response decrypt — the
                 part that silently breaks when the site rotates its build)
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

# (name, ok, detail, fatal)
results: list[tuple[str, bool, str, bool]] = []


async def run_check(name: str, coro, timeout: float, fatal: bool = True):
    """Run one probe. `fatal=False` reports but does not fail the run.

    Retired providers are kept in-tree in case they are reinstated, but they
    are not selectable, so their breakage must not turn the daily probe red --
    a check that is always failing is one nobody reads, which would bury the
    checks that do matter.
    """
    try:
        detail = await asyncio.wait_for(coro, timeout=timeout)
        results.append((name, True, detail, fatal))
    except Exception as e:  # noqa: BLE001 - report everything, this is a probe
        results.append((name, False, f"{type(e).__name__}: {e}", fatal))


def _first_media_entry(playlist: str) -> str | None:
    """First non-comment line of an m3u8, or None if there isn't one."""
    for line in playlist.splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    return None


async def _segment_serves(session: AsyncSession, master_url: str) -> tuple[bool, str]:
    """Walk an HLS playlist down to a real segment and see if it serves.

    Mirrors `probe_stream` in commands/playback.rs. Fetching the playlist is
    not enough and that is the entire point of this check: a playlist is a
    small static file that answers 200 long after the media behind it is gone.
    """
    url = master_url
    for _ in range(2):  # master -> variant -> segment
        r = await session.get(url, timeout=30, headers={"Referer": "https://anineko.to/"})
        if r.status_code != 200:
            return False, f"playlist HTTP {r.status_code}"
        entry = _first_media_entry(r.text)
        if entry is None:
            return False, "playlist had no media entries"
        url = entry if entry.startswith("http") else url.rsplit("/", 1)[0] + "/" + entry
        if not (url.split("?")[0].endswith(".m3u8") or url.split("?")[0].endswith("master.txt")):
            break
    r = await session.get(url, timeout=45, headers={"Referer": "https://anineko.to/"})
    host = url.split("/")[2] if "//" in url else url
    if r.status_code != 200:
        return False, f"segment HTTP {r.status_code} on {host}"
    return True, f"segment ok on {host}"


async def check_anineko() -> str:
    """Search, resolve streams, and prove at least one of them plays on a phone.

    Search alone used to be the whole check, and it stayed green through a
    complete mobile outage: anineko lists ~12 servers per episode but only the
    ones on proxy-allowlisted hosts are reachable from the PWA, and the segments
    behind those are served by CDNs that revoke them per asset. Both halves have
    to be asserted or this probe reports health it hasn't measured.

    Desktop is deliberately not the bar here. mpv fetches upstream directly and
    can play servers the phone cannot, so a check that ignores browser_ok would
    go green while mobile is dead -- exactly what happened.
    """
    from anineko import AniNekoProvider

    prov = AniNekoProvider()
    refs = await prov.search(SEARCH_QUERY)
    if not refs:
        raise RuntimeError(f"search '{SEARCH_QUERY}' returned 0 results")

    slug = refs[0].id
    servers, _ = await prov.streams(slug, 1)
    if not servers:
        raise RuntimeError(
            f"streams('{slug}', ep 1) resolved 0 servers "
            "(watch-page layout changed? check the lang-group panel selectors)"
        )

    reachable = [s for s in servers if s.browser_ok]
    if not reachable:
        raise RuntimeError(
            f"streams('{slug}', ep 1) resolved {len(servers)} servers but none are "
            "proxy-reachable, so the mobile PWA has nothing to play "
            "(hosts: "
            + ", ".join(sorted({s.url.split('/')[2] for s in servers if '//' in s.url}))
            + ") -- add the stable one to _BROWSER_REACHABLE_HOSTS and ALLOWED_DOMAINS"
        )

    # At least one reachable server must serve actual media, not just a
    # playlist. They cover for each other, so only a total failure is fatal.
    failures = []
    async with AsyncSession(impersonate="chrome142") as session:
        for s in reachable:
            try:
                ok, detail = await _segment_serves(session, s.url)
            except Exception as e:  # noqa: BLE001 - a probe, report anything
                ok, detail = False, f"{type(e).__name__}: {e}"
            if ok:
                return (
                    f"{len(refs)} results, {len(servers)} servers, "
                    f"{len(reachable)} mobile-reachable, playing via {s.name} ({detail})"
                )
            failures.append(f"{s.name}/{s.group}: {detail}")

    raise RuntimeError(
        f"all {len(reachable)} mobile-reachable servers for ep 1 are dead "
        "(playlists resolve but no segments serve) -- " + "; ".join(failures)
    )


async def check_mkissa() -> str:
    from mkissa import MkissaProvider

    prov = MkissaProvider()
    refs = await prov.search(SEARCH_QUERY)
    if not refs:
        raise RuntimeError(f"search '{SEARCH_QUERY}' returned 0 results")
    info = await prov.get(refs[0].id)
    if info is None or not info.episodes:
        raise RuntimeError(f"get('{refs[0].id}') returned no episodes")
    # Stream resolution exercises the aaReq crypto token AND the response
    # decrypt — the July 2026 build rotation broke exactly this while search
    # and get kept working, so the old smoke test stayed green through it.
    servers, _ = await prov.streams(refs[0].id, 1)
    if not servers:
        raise RuntimeError(
            f"streams('{refs[0].id}', ep 1) resolved 0 servers "
            "(stale aaReq crypto constants? check bundle buildId/mask)"
        )
    return (
        f"{len(refs)} results, {info.title}: {len(info.episodes)} episodes, "
        f"{len(servers)} stream servers"
    )


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
    # streams resolution + a possible crypto-constant re-extraction crawl
    # push mkissa well past the old search+get budget. Non-fatal: mkissa is in
    # RETIRED_PROVIDERS and cannot be selected, so its aaReq rotations are
    # information, not an outage.
    await run_check("mkissa (retired)", check_mkissa(), timeout=180, fatal=False)
    await run_check("mangakatana", check_mangakatana(), timeout=60)
    await run_check("subsplease", check_subsplease(), timeout=45)
    await run_check("nyaa-rss", check_nyaa_rss(), timeout=45)

    failed = 0
    for name, ok, detail, fatal in results:
        if ok:
            status = "OK  "
        elif fatal:
            status = "FAIL"
            failed += 1
        else:
            status = "WARN"
        print(f"{status} {name}: {detail}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
