"""AniNeko provider — verified against the live site 2026-08-12.

anineko is server-rendered PHP + jQuery: no SPA, no hydration, and every piece
of data this provider needs is either in the HTML or behind a plain JSON
endpoint. There is exactly one place to look for each thing.

  Search        GET /ajax/search?q=<query>
                -> {"success": true, "results": [{title, url, image, meta}]}
                `url` is /watch/<slug>; `meta` reads "TV - 28 Episodes".
                The multi-attempt fan-out in `search()` is still needed: the
                site indexes by its own English titles, so an AniList romaji
                title can miss entirely while a truncation of it hits.

  Episodes      GET /watch/<slug>
                article.nv-info-episode-item > a.nv-info-episode-main,
                with an /ep-(\\d+) href fallback for the number.

  Servers       GET /watch/<slug>/ep-<n>
                <div class="... server-items lang-group" data-id="sub|dub">
                  <button class="nv-server-btn server-video"
                          data-video="<embed url>?sub=<vtt>">
                    HD-1 <span>Sort Sub</span>
                The name is a bare text node, not a <strong>; the group comes
                from the panel's data-id; the VTT rides in the query string.

Embed hosts, and which of them the mobile PWA can play (see `browser_ok`):
  vivibebe.site   /<token> -> /public/stream/<token>/master.m3u8, derivable
                  with no fetch at all. Proxy-allowlisted, so this is the one
                  server that works on mobile.
  otakuhg.site,   jwplayer behind packed JS. Their `links` object now offers
  otakuvid.online only hls3/hls2, both on throwaway domains that rotate per
                  request -- unallowlistable, therefore desktop-only.
  bibiemb.xyz     resolves onto *.workers.dev; desktop-only.
  playmogo.com    Cloudflare-challenged, unresolvable without a browser.

Cloudflare: anineko challenges only intermittently (it was serving plain
requests throughout the 2026-08-12 verification). `_cf_get` therefore tries
curl_cffi first and only opens Chrome on an actual 403. `_CF_COOKIE_TTL` must
stay under the sidecar's `IDLE_TIMEOUT_SECS` in scraper/client.rs, since the
clearance dies with this process.
"""

import re
import asyncio
import json
import logging
import time
from urllib.parse import urljoin, urlparse, parse_qs
from dataclasses import dataclass, field
from typing import Optional, List, Tuple
from curl_cffi import requests
from selectolax.parser import HTMLParser

from diagnostics import warn_empty

log = logging.getLogger(__name__)

BASE_URL = "https://anineko.to"


def clean_title_for_search(title: str) -> str:
    """Remove season/part/cour suffixes that AniNeko slugs won't match."""
    title = re.sub(
        r'\s*([-–]\s*)?('
        r'season\s*\d+|part\s*\d+|cour\s*\d+|\d+(st|nd|rd|th)\s*season'
        r'|2nd year.*|1st semester.*|ichi gakki.*|ni gakki.*'
        r'|[-–:]\s*\w+\s*arc|\(\d{4}\)'
        r')\s*$',
        '', title, flags=re.IGNORECASE,
    ).strip()
    title = re.sub(r'\s*[\(\[].*?[\)\]]\s*$', '', title).strip()
    title = re.sub(r'\s+', ' ', title).strip()
    return title


@dataclass
class AnimeRef:
    id: str
    title: str
    year: Optional[int] = None


@dataclass
class Episode:
    number: int
    title: Optional[str] = None
    image: Optional[str] = None


@dataclass
class AnimeInfo:
    title: str
    episodes: list[Episode] = field(default_factory=list)


@dataclass
class StreamServer:
    name: str
    url: str
    quality: Optional[str] = None
    is_m3u8: Optional[bool] = None
    headers: Optional[dict] = None
    group: str = "unknown"
    source_type: str = "unknown"
    subtitle_url: Optional[str] = None
    #: Whether a browser `<video>` element can actually play this server.
    #:
    #: Not a codec judgement — a proxy-reachability one. The mobile PWA fetches
    #: every byte through anicat's proxy, which only talks to an allowlisted set
    #: of hosts. Most of anineko's embeds resolve to throwaway CDN domains that
    #: rotate per request and can never be listed, so those servers are dead on
    #: the phone no matter how healthy they are. mpv fetches directly and is
    #: unaffected, which is why this has to be per-server rather than global.
    browser_ok: bool = False


#: Host suffixes whose streams the anicat proxy can actually reach, and which
#: are therefore playable in the mobile PWA. Kept deliberately narrow: an entry
#: here is a promise that the same host also appears in `ALLOWED_DOMAINS` in
#: `web/src-tauri/src/proxy/server.rs`. Adding one without the other produces a
#: server the phone offers and then fails to play.
_BROWSER_REACHABLE_HOSTS = (
    "vivibebe.site",
    "vibeplayer.site",
    "anizara.store",
    # HD-2. Resolves off bibiemb.xyz onto one fixed Cloudflare Workers
    # subdomain -- `morning-credit-3bcc.vibevibe.workers.dev` was identical
    # across every episode and both audio groups when this was measured, and
    # playlist, variants and segments all stay on it. Listing the full
    # `vibevibe.workers.dev` is as narrow as any other entry here (it is one
    # account's namespace); listing bare `workers.dev` would open the proxy to
    # anyone's Worker and must not be done.
    #
    # This matters because HD-2 is the one server that covers the episodes
    # HD-1 loses: HD-1's segments sit on an ad CDN that revokes them per
    # asset, and on a ten-episode sample four were dead -- HD-2 served 200 on
    # all four.
    "vibevibe.workers.dev",
)


def _host_is_browser_reachable(url: str) -> bool:
    try:
        host = urlparse(url).hostname or ""
    except Exception:
        return False
    host = host.lower()
    return any(host == h or host.endswith("." + h) for h in _BROWSER_REACHABLE_HOSTS)


_CF_COOKIE_TTL = 1500  # 25 minutes (Cloudflare typically gives 30 min)


class CloudflareSolver:
    """Solve Cloudflare JS challenges using nodriver (headless Chrome).

    Launches a real Chrome instance via the DevTools Protocol, navigates to
    anineko.to, waits for the cf_clearance cookie to appear, then returns
    the cookies + User-Agent so curl_cffi can reuse them.
    """

    def __init__(self):
        self._cf_clearance: Optional[str] = None
        self._cookies: dict[str, str] = {}
        self._user_agent: Optional[str] = None
        self._solved_at: float = 0

    @property
    def is_valid(self) -> bool:
        return (
            self._cf_clearance is not None
            and (time.monotonic() - self._solved_at) < _CF_COOKIE_TTL
        )

    def invalidate(self):
        """Force re-solve on next request."""
        self._cf_clearance = None
        self._cookies = {}
        self._solved_at = 0

    async def solve(self) -> tuple[dict[str, str], str]:
        """Solve the Cloudflare challenge and return (cookies_dict, user_agent).

        Attempts headless solve first. If that fails (or times out), it falls back
        to headed mode (where Chrome briefly pops up to solve Turnstile and auto-closes).
        """
        try:
            log.info("Solving Cloudflare challenge: trying headless mode...")
            return await self._solve_once(headless=True)
        except Exception as e:
            log.warning("Headless Cloudflare solve failed: %s. Retrying in headed mode...", e)
            try:
                return await self._solve_once(headless=False)
            except Exception as ee:
                log.error("Headed Cloudflare solve failed: %s", ee)
                raise RuntimeError(f"Cloudflare solve failed in both headless and headed modes: {ee}")

    async def _solve_once(self, headless: bool) -> tuple[dict[str, str], str]:
        import nodriver as uc

        browser = None
        try:
            browser_args = [
                "--disable-gpu",
                "--no-first-run",
                "--no-default-browser-check",
            ]
            if headless:
                browser_args.extend([
                    "--headless=new",
                    "--window-size=400,300",
                    "--window-position=-2000,-2000",
                ])
            else:
                browser_args.extend([
                    "--window-size=800,600",
                ])

            browser = await uc.start(
                headless=headless,
                browser_args=browser_args,
            )
            page = await browser.get(f"{BASE_URL}/home")

            cf_clearance = None
            for attempt in range(24):  # up to ~12 seconds
                await asyncio.sleep(0.5)
                try:
                    cookies = await browser.cookies.get_all()
                except Exception:
                    continue
                for c in cookies:
                    if c.name == "cf_clearance":
                        cf_clearance = c.value
                        break
                if cf_clearance:
                    break

            if not cf_clearance:
                raise RuntimeError(
                    "Failed to obtain cf_clearance cookie after challenge"
                )

            all_cookies = {}
            try:
                cookies = await browser.cookies.get_all()
                for c in cookies:
                    all_cookies[c.name] = c.value
            except Exception:
                all_cookies["cf_clearance"] = cf_clearance

            ua = None
            try:
                ua = await page.evaluate("navigator.userAgent")
            except Exception:
                pass

            self._cf_clearance = cf_clearance
            self._cookies = all_cookies
            self._user_agent = ua
            self._solved_at = time.monotonic()

            log.info("Cloudflare challenge solved (cookie=%s...)", cf_clearance[:20])
            return all_cookies, ua or ""

        finally:
            if browser:
                try:
                    result = browser.stop()
                    # nodriver's stop() may return a coroutine or None
                    if asyncio.iscoroutine(result) or asyncio.isfuture(result):
                        await result
                except Exception:
                    pass


class AniNekoProvider:
    def __init__(self):
        self._solver = CloudflareSolver()
        self.session = requests.Session(impersonate="chrome142")
        self.session.headers.update(
            {
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/142.0.0.0 Safari/537.36"
                ),
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
            }
        )
        self._clearance_lock = asyncio.Lock()

    async def _ensure_clearance(self):
        """Ensure we have a valid cf_clearance cookie, solving if needed."""
        if self._solver.is_valid:
            return
        async with self._clearance_lock:
            if self._solver.is_valid:
                return
            cookies, ua = await self._solver.solve()
            # Match impersonation to the Chrome version that solved the challenge
            ver_match = re.search(r'Chrome/(\d+)', ua or "")
            if ver_match:
                chrome_ver = ver_match.group(1)
                new_session = requests.Session(impersonate=f"chrome{chrome_ver}")
                new_session.headers.update(self.session.headers)
                new_session.cookies.update(self.session.cookies)
                self.session = new_session
            for name, value in cookies.items():
                self.session.cookies.set(name, value, domain=".anineko.to")
            # Match the User-Agent that solved the challenge
            if ua:
                self.session.headers["User-Agent"] = ua

    def _handle_cf_block(self, resp) -> bool:
        """Check if response is a Cloudflare challenge. Returns True if blocked."""
        if resp.status_code == 403:
            if "cf-mitigated" in resp.headers.get("cf-mitigated", "") or \
               "Just a moment" in resp.text[:500]:
                log.warning("Cloudflare challenge detected, invalidating clearance")
                self._solver.invalidate()
                return True
            # Any 403 from anineko.to is likely CF
            self._solver.invalidate()
            return True
        return False

    async def _cf_get(self, url: str, **kwargs) -> requests.Response:
        """HTTP GET with automatic Cloudflare challenge handling.

        Tries curl_cffi first. Only opens Chrome to solve the challenge if
        Cloudflare is actually blocking (403). When CF isn't challenging,
        no browser is needed at all.
        """
        kwargs.setdefault("timeout", 20)
        if self._solver.is_valid:
            pass  # cookies already in session from last solve
        resp = self.session.get(url, **kwargs)
        if self._handle_cf_block(resp):
            await self._ensure_clearance()
            resp = self.session.get(url, **kwargs)
        return resp

    async def search(self, query: str) -> list[AnimeRef]:
        attempts = self._build_search_attempts(query)

        # `/ajax/search` is the site's own autocomplete endpoint and answers
        # with JSON, so this no longer parses search-result HTML at all — one
        # whole class of selector breakage gone.
        #
        # The multi-attempt fan-out stays, because it is doing real work: the
        # site indexes by its own English titles, so an AniList romaji title
        # like "Kaguya-sama wa Kokurasetai: Ultra Romantic" returns *zero*
        # results while the truncated "Kaguya-sama wa Kokurasetai" returns the
        # right show. Verified against both endpoints — this is a property of
        # the index, not of the old HTML scrape.
        async def run_attempt(attempt: str) -> list[AnimeRef]:
            try:
                resp = await self._cf_get(
                    f"{BASE_URL}/ajax/search",
                    params={"q": attempt},
                    timeout=15,
                    headers={"X-Requested-With": "XMLHttpRequest"},
                )
                resp.raise_for_status()
                return self._parse_ajax_search(resp.text)
            except Exception as e:
                log.warning("Search attempt for '%s' failed: %s", attempt, e)
                return []

        tasks = [run_attempt(att) for att in attempts]
        all_results = await asyncio.gather(*tasks)

        # Merge results, preserving priority of attempts and removing duplicates
        merged = []
        seen = set()
        for results in all_results:
            for ref in results:
                if ref.id not in seen:
                    seen.add(ref.id)
                    merged.append(ref)
        return merged

    def _build_search_attempts(self, title: str) -> list[str]:
        attempts = []
        cleaned = clean_title_for_search(title)
        attempts.append(cleaned)
        words = cleaned.split()
        if len(words) > 5:
            attempts.append(" ".join(words[:5]))
        if len(words) > 3:
            attempts.append(" ".join(words[:3]))
        base = re.sub(
            r"\s*(season\s*\d+|s\d+|\biv\b|\biii\b|\bii\b)\s*$",
            "", cleaned, flags=re.IGNORECASE,
        ).strip()
        if base and base != cleaned:
            attempts.append(base)
        seen = set()
        return [x for x in attempts if x and not (x in seen or seen.add(x))]

    async def get(self, slug: str) -> Optional[AnimeInfo]:
        for attempt in range(3):
            try:
                resp = await self._cf_get(f"{BASE_URL}/watch/{slug}", timeout=20)
                resp.raise_for_status()
                return self._parse_anime(resp.text)
            except Exception as e:
                if attempt == 2:
                    raise RuntimeError(f"Get failed after 3 attempts: {e}")
                await self._sleep(1 + attempt)
        return None

    async def streams(
        self, slug: str, episode: int, debug: bool = False
    ) -> Tuple[List[StreamServer], List[dict]]:
        """Multi-pass extraction with optional debug output."""
        debug_log = []
        url = f"{BASE_URL}/watch/{slug}/ep-{episode}"

        for attempt in range(3):
            try:
                resp = await self._cf_get(url, timeout=30)
                resp.raise_for_status()
                html = resp.text
                page_title = self._extract_title(html)

                if debug:
                    debug_log.append({
                        "pass": "request",
                        "status": resp.status_code,
                        "final_url": str(resp.url),
                        "html_length": len(html),
                        "page_title": page_title,
                    })

                servers, debug_panels = self._parse_servers(html)
                if debug:
                    debug_log.append(debug_panels)

                # Dedupe on the embed URL. The panel markup is already clean,
                # so this is cheap insurance rather than the load-bearing
                # filter it had to be when four passes fed into it.
                seen = set()
                unique = []
                for s in servers:
                    if s.url and s.url not in seen:
                        seen.add(s.url)
                        unique.append(s)

                loop = asyncio.get_running_loop()

                def resolve_server(s: StreamServer) -> StreamServer:
                    direct = self._try_extract_direct_url(s.url)
                    if direct:
                        s.url = direct
                        s.is_m3u8 = bool(
                            ".m3u8" in direct
                            or "master.txt" in direct
                            or "master.m3u8" in direct
                        )
                    # Judged on the *resolved* URL: the embed host tells you
                    # nothing, since otakuhg.site resolves onto a different,
                    # rotating domain every time.
                    s.browser_ok = _host_is_browser_reachable(s.url)
                    return s

                tasks = [loop.run_in_executor(None, resolve_server, s) for s in unique]
                resolved_servers = await asyncio.gather(*tasks)

                if not any(s.browser_ok for s in resolved_servers):
                    # Not fatal on desktop (mpv bypasses the proxy entirely),
                    # but it means the phone has nothing to play for this
                    # episode, which is worth a line in the log.
                    log.warning(
                        "anineko %s ep %s: none of the %d servers are proxy-reachable "
                        "(mobile will have no playable source)",
                        slug, episode, len(resolved_servers),
                    )

                if debug:
                    return resolved_servers, debug_log
                return resolved_servers, []

            except Exception as e:
                if attempt == 2:
                    if debug:
                        return [], [{"pass": "error", "error": str(e)}]
                    raise RuntimeError(
                        f"Stream resolution failed after 3 attempts: {e}"
                    )
                await self._sleep(1 + attempt)

        return [], []

    @staticmethod
    def _parse_ajax_search(body: str) -> list[AnimeRef]:
        """Parse `/ajax/search?q=` — the site's own autocomplete JSON.

        Shape: {"success": true, "results": [{title, url, image, meta}]},
        where `url` is `/watch/<slug>` and `meta` reads like "TV - 28 Episodes".
        Replaces the old `article.nv-anime-card` scrape; a JSON contract is far
        less likely to move than a class name, and this endpoint matched the
        HTML one on every title tested (and beat it on short/ambiguous ones).
        """
        try:
            data = json.loads(body)
        except (ValueError, TypeError):
            warn_empty("anineko", "/ajax/search", "search results (not JSON)")
            return []
        items = data.get("results") if isinstance(data, dict) else None
        if not items:
            return []
        results = []
        for item in items:
            if not isinstance(item, dict):
                continue
            url = (item.get("url") or "").strip()
            title = (item.get("title") or "").strip()
            if not url or not title:
                continue
            slug = url.rsplit("/watch/", 1)[-1].strip("/")
            if not slug or "/" in slug:
                continue
            results.append(AnimeRef(id=slug, title=title))
        if not results:
            warn_empty("anineko", "/ajax/search", "search results (empty)")
        return results

    @staticmethod
    def _parse_anime(html: str) -> Optional[AnimeInfo]:
        tree = HTMLParser(html)
        title = ""
        h1 = tree.css_first("h1")
        if h1:
            title = h1.text(strip=True)
        if not title:
            m = re.search(r"<title>([^-]+)", html)
            if m:
                title = m.group(1).strip()
        if not title:
            return None

        ep_cards = tree.css("article.nv-info-episode-item")
        if not ep_cards:
            warn_empty("anineko", "article.nv-info-episode-item", f"detail page '{title}'")

        episodes = []
        for ep_card in ep_cards:
            ep_link = ep_card.css_first("a.nv-info-episode-main")
            if not ep_link:
                continue
            href = ep_link.attributes.get("href", "")
            number_el = ep_link.css_first("strong")
            title_el = ep_link.css_first("span")
            ep_num = 0
            if number_el:
                m = re.search(r"\d+", number_el.text(strip=True))
                if m:
                    ep_num = int(m.group())
            if ep_num == 0 and href:
                m = re.search(r"/ep-(\d+)", href)
                if m:
                    ep_num = int(m.group(1))
            if ep_num <= 0:
                continue
            episodes.append(
                Episode(
                    number=ep_num,
                    title=title_el.text(strip=True) if title_el else None,
                )
            )
        return AnimeInfo(title=title, episodes=episodes)

    def _extract_title(self, html: str) -> str:
        m = re.search(r"<title>([^<]+)</title>", html)
        return m.group(1).strip() if m else ""

    @staticmethod
    def _extract_subtitle_url(data_video_url: str) -> Optional[str]:
        """Pull the soft-sub VTT out of a `data-video` URL's query string.

        HD-1/HD-2 attach captions as a query param rather than burning them in
        (`...?sub=https://cdn.anizara.store/...vtt`). This used to guess at a
        fixed list of param names; now it takes any param whose value looks
        like a subtitle URL, so a rename doesn't silently drop captions.
        """
        try:
            params = parse_qs(urlparse(data_video_url).query)
        except Exception:
            return None
        for values in params.values():
            for value in values:
                if value.startswith("http") and (".vtt" in value or ".srt" in value or "/subtitle" in value):
                    return value
        return None

    def _parse_servers(self, html: str) -> Tuple[List[StreamServer], dict]:
        """Read the server list straight out of the watch page's own markup.

        anineko server-renders every server it has, so there is exactly one
        place to look and no guesswork:

            <div class="... server-items lang-group" data-id="sub|dub">
              <button class="nv-server-btn server-video" data-video="<embed url>">
                <strong>HD-1</strong> ...

        This replaces four overlapping extraction passes (DOM, a raw-HTML regex
        sweep, a script-JSON scan, and a second server-group pass). They existed
        to cover each other's gaps but mostly manufactured work: the regex pass
        matched *any* quoted .m3u8/.mp4//embed/ string on the page, which is how
        `https://anineko.to/img/logo.png` ended up in a live server list as
        `script_url` — and every invented URL then cost its own 15s embed fetch.
        One structural read produces the same 12 real servers with none of that.

        Group is taken from the panel (`sub`/`dub`) rather than sniffed from a
        label, so an unrecognised label can no longer silently become soft_sub.
        """
        tree = HTMLParser(html)
        panels = tree.css("div.server-items.lang-group")
        if not panels:
            warn_empty("anineko", "div.server-items.lang-group", "server panels")
        servers: List[StreamServer] = []
        for panel in panels:
            # data-id is "sub" or "dub"; anicat's own vocabulary is
            # soft_sub/hard_sub/dub, and anineko's sub tier carries an external
            # VTT, which is soft_sub by definition.
            panel_id = (panel.attributes.get("data-id") or "").strip().lower()
            group = "dub" if panel_id == "dub" else "soft_sub"
            for btn in panel.css("button[data-video]"):
                raw = (btn.attributes.get("data-video") or "").strip()
                if not raw.startswith("http"):
                    continue
                # The name is a bare text node sitting directly in the button,
                # ahead of a <span> holding the tier label:
                #     <button ...>  HD-1  <span>Sort Sub</span></button>
                # so `text()` would return "HD-1Sort Sub" and `<strong>` (which
                # the panel *heading* uses) doesn't exist here at all. Take only
                # the button's own text, and collapse the generous indentation
                # around it — the previous parser passed that through, which is
                # why server names reached the UI padded to 40 characters.
                label = " ".join(btn.text(deep=False).split())
                if not label:
                    strong = btn.css_first("strong")
                    if strong:
                        label = " ".join(strong.text().split())
                if not label:
                    label = " ".join(btn.text().split())
                servers.append(StreamServer(
                    name=(label or "Server").strip(),
                    url=raw,
                    group=group,
                    source_type="dom_panel",
                    subtitle_url=self._extract_subtitle_url(raw),
                ))
        return servers, {
            "pass": "panels",
            "panels": len(panels),
            "found": len(servers),
            "names": [s.name for s in servers],
        }

    #: Hosts that serve a playable stream at a URL derivable from the embed
    #: URL alone, so no fetch is needed. Maps host suffix -> path template
    #: taking the embed's token.
    #:
    #: This is the *fast* path and, not coincidentally, the only proxy-reachable
    #: one: vivibebe is the sole anineko server the mobile PWA can play. Kept as
    #: an explicit table rather than the previous inline two-host regex, whose
    #: own docstring admitted the list had gone stale.
    _DIRECT_SHAPE_HOSTS = {
        "vivibebe.site": "https://{host}/public/stream/{token}/master.m3u8",
        "vibeplayer.site": "https://{host}/public/stream/{token}/master.m3u8",
    }

    def _direct_shape_url(self, embed_url: str) -> Optional[str]:
        """Derive a stream URL from the embed URL without fetching anything."""
        try:
            parsed = urlparse(embed_url)
        except Exception:
            return None
        host = (parsed.hostname or "").lower()
        template = None
        for candidate, tmpl in self._DIRECT_SHAPE_HOSTS.items():
            if host == candidate or host.endswith("." + candidate):
                template = tmpl
                host = candidate
                break
        if not template:
            return None
        # Path is `/<token>` or `/embed/<token>`; the query string carries the
        # subtitle sidecar and must not leak into the token.
        token = parsed.path.strip("/").rsplit("/", 1)[-1]
        if not token or not re.fullmatch(r"[A-Za-z0-9]+", token):
            return None
        return template.format(host=host, token=token)

    def _try_extract_direct_url(self, embed_url: str) -> Optional[str]:
        """Resolve an embed page to a playable stream URL.

        Hosts with a derivable URL shape are handled first and cost **zero**
        HTTP requests — that is most of the wall-clock time of a play on the one
        server that actually works on mobile. Everything else falls back to
        fetching and unpacking the embed page.

        Note the ordering is the reverse of what it was. Page-extraction-first
        was introduced because otakuvid/otakuhg retired the `/public/stream/`
        shape, but that reasoning never applied to vivibebe, which still serves
        it (verified on both sub and dub tokens). Those hosts are now selected
        by an explicit table instead of being tried blindly, so putting the
        cheap path first can't resurrect the old bug.
        """
        shaped = self._direct_shape_url(embed_url)
        if shaped:
            return shaped
        return self._extract_from_embed_page(embed_url)

    def _extract_from_embed_page(self, embed_url: str) -> Optional[str]:
        try:
            resp = self.session.get(embed_url, timeout=15)  # embed URLs are third-party, no CF
            if resp.status_code != 200:
                return None
            text = resp.text

            packed_matches = re.finditer(
                r"eval\(function\(p,a,c,k,e,d\).*?\}\('(.*?)'\s*,\s*(\d+)\s*,\s*(\d+)\s*,\s*'(.*?)'\.split\('\|'\)\)\)",
                text,
                re.DOTALL
            )
            for match in packed_matches:
                p, a, c, k_str = match.groups()
                try:
                    unpacked = self._unpack_packed(p, int(a), int(c), k_str.split('|'))
                    text += "\n" + unpacked
                except Exception:
                    pass

            # jwplayer hosts (otakuvid/otakuhg and friends) declare
            # `var links={"hls2":...,"hls3":...,"hls4":...}` and then feed the
            # player `links.hls4||links.hls3||links.hls2`. Honour that order
            # rather than whichever key happens to appear first in the source:
            # hls4 is a *same-origin* relative path, so the playlist, its
            # variants and every segment stay on one host the proxy allowlist
            # already covers, while hls2/hls3 point at rotating throwaway CDN
            # domains that can never be allowlisted.
            links = self._extract_jwplayer_links(text)
            if links:
                return urljoin(embed_url, links)

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
        except Exception:
            pass
        return None

    @staticmethod
    def _extract_jwplayer_links(text: str) -> Optional[str]:
        """Pick the best entry out of a jwplayer `var links={...}` object."""
        m = re.search(r"\blinks\s*=\s*(\{.*?\})\s*;", text, re.DOTALL)
        if not m:
            return None
        try:
            obj = json.loads(m.group(1))
        except (json.JSONDecodeError, ValueError):
            return None
        if not isinstance(obj, dict):
            return None
        for key in ("hls4", "hls3", "hls2", "hls"):
            val = obj.get(key)
            if isinstance(val, str) and val.strip():
                return val.strip()
        return None

    def _decode_baseN(self, num: int, base: int) -> str:
        chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
        if num == 0:
            return "0"
        res = []
        while num > 0:
            res.append(chars[num % base])
            num //= base
        return "".join(reversed(res))

    def _unpack_packed(self, p: str, a: int, c: int, k: list[str]) -> str:
        for i in range(c - 1, -1, -1):
            if i < len(k) and k[i]:
                val = k[i]
                base_n_str = self._decode_baseN(i, a)
                pattern = r"\b" + re.escape(base_n_str) + r"\b"
                p = re.sub(pattern, val, p)
        return p

    async def _sleep(self, seconds: float):
        await asyncio.sleep(seconds)


if __name__ == "__main__":

    async def main():
        provider = AniNekoProvider()
        print("Testing AniNeko scraper...\n")

        print("Search: naruto")
        results = await provider.search("naruto")
        print(f"  Found {len(results)} results")
        for r in results[:3]:
            print(f"    {r.title[:50]}  (slug={r.id})")

        if not results:
            print("  FAILED: no search results")
            return

        slug = results[0].id
        print(f"\nGet episodes: {slug}")
        info = await provider.get(slug)
        if info:
            print(f"  Title: {info.title}")
            print(f"  Episodes: {len(info.episodes)}")
            for ep in info.episodes[:3]:
                print(f"    Ep {ep.number}: {ep.title or '(no title)'}")
        else:
            print("  FAILED: no anime info")

        slug2 = "classroom-of-the-elite-iv"
        print(f"\nDebug streams: {slug2} ep 1")
        sources, debug = await provider.streams(slug2, 1, debug=True)
        print(f"  Found {len(sources)} sources")
        for s in sources[:5]:
            print(f"    [{s.source_type}] {s.name}: {s.url[:80]}...")
        print(f"\n  Debug log: {len(debug)} passes")
        for d in debug:
            print(f"    {d.get('pass', 'unknown')}: {d.get('found', '?')} items")

    asyncio.run(main())
