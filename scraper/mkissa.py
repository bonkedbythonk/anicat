import re
import json
import hashlib
import base64
import logging
import time
import urllib.parse
import asyncio
from dataclasses import dataclass, field
from typing import Optional, List, Tuple
from Crypto.Cipher import AES
from Crypto.Util import Counter
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from curl_cffi.requests import AsyncSession

from diagnostics import warn_empty

log = logging.getLogger(__name__)

AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0"
MKISSA_REFR = "https://mkissa.to"
MKISSA_BASE = "allanime.day"
MKISSA_API = f"https://api.{MKISSA_BASE}"
MKISSA_KEY = hashlib.sha256(b"Xot36i3lK3:v1").hexdigest()
# Raw digest (not hex string) of the same legacy string — this is the actual
# AES-GCM key the client uses to decrypt the sourceUrls blob (verified by
# instrumenting crypto.subtle in a real browser session: the site tries the
# partB^mask key first, that call throws, and it silently falls back to this
# static key, which succeeds — independent of buildId/partB/epoch entirely).
# So unlike the signing token below, this one doesn't rotate.
MKISSA_RESPONSE_KEY = hashlib.sha256(b"Xot36i3lK3:v1").digest()

# allanime.day's client-crypto (aaReq) constants, lifted from the site's JS
# bundle (chunks/*.js: `const zr="13"` is the build id, `$n="..."` the XOR
# mask). Both rotate every so often; when the API starts returning
# AA_CRYPTO_STALE / AA_CRYPTO_BUILD_MISMATCH again, re-read them from the
# current bundle. The mask is XORed against the fetched partB to derive the
# AES key used only for signing the request token (aaReq) — NOT for
# decrypting the response; see MKISSA_RESPONSE_KEY above for that.
MKISSA_BUILD_ID = "20"
MKISSA_MASK_HEX = "52735823afe9a3eb96958a8b8981254d8b70d2ebc3ae1999960b1a7ab7fbbe5b"

# Persisted query hash for episode embeds (from ani-cli v4.14.0)
EPISODE_QUERY_HASH = "d405d0edd690624b66baba3068e0edc3ac90f1597d898a1ec8db4e5c43c00fec"


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


def b64url_decode(s: str) -> bytes:
    padded = s
    mod = len(padded) % 4
    if mod == 2:
        padded += '=='
    elif mod == 3:
        padded += '='
    b64 = padded.replace('-', '+').replace('_', '/')
    return base64.b64decode(b64)


def decrypt(blob: str, key: bytes) -> Optional[str]:
    try:
        data = base64.b64decode(blob)
        if data[0] != 1:
            print(f"Decryption failed: unsupported version {data[0]}")
            return None
        iv = data[1:13]
        ciphertext = data[13:]
        
        cipher = AESGCM(key)
        decrypted = cipher.decrypt(iv, ciphertext, None)
        return decrypted.decode('utf-8')
    except Exception as e:
        log.warning(f"Decryption failed: {e}")
        return None


async def get_mp4upload_links(session, page_url: str) -> list:
    all_links = []
    try:
        resp = await session.get(page_url, timeout=5)
        if resp.status_code == 200:
            m = re.search(r'(?:src|file):\s*"([^"]+\.mp4[^"]*)"', resp.text, re.IGNORECASE)
            if m:
                mp4_url = m.group(1).replace(r'\u0026', '&').replace('\\', '')
                all_links.append({
                    'resolution': 'Mp4',
                    'url': mp4_url,
                    'referer': 'https://www.mp4upload.com/'
                })
    except Exception as e:
        log.warning(f"mp4upload extract failed: {e}")
    return all_links


def _is_filemoon_payload(data: dict) -> bool:
    return bool(data) and 'iv' in data and 'payload' in data and 'key_parts' in data


def _parse_filemoon_payload(fm_data: dict) -> list:
    """Decrypt a filemoon-style clock.json response (AES-128-CTR, key split
    across two base64url parts) into a list of {resolution, url} links."""
    all_links = []
    try:
        kp1_bytes = b64url_decode(fm_data['key_parts'][0])
        kp2_bytes = b64url_decode(fm_data['key_parts'][1])
        key_bytes = kp1_bytes + kp2_bytes

        iv_bytes = b64url_decode(fm_data['iv'])
        counter_block = iv_bytes + b'\x00' * (16 - len(iv_bytes))
        counter_block = bytearray(counter_block)
        counter_block[15] = 2

        payload_bytes = b64url_decode(fm_data['payload'])
        ct_len = len(payload_bytes) - 16
        ciphertext = payload_bytes[:ct_len]

        initial_value = int.from_bytes(counter_block, byteorder='big')
        ctr = Counter.new(128, initial_value=initial_value)
        cipher = AES.new(key_bytes, AES.MODE_CTR, counter=ctr)
        decrypted = cipher.decrypt(ciphertext)
        plain = decrypted.decode('utf-8')

        parts = re.sub(r'[{}\[\]]', '\n', plain).split('\n')
        for part in parts:
            m1 = re.search(r'"url":"([^"]*)".*"height":(\d+)', part)
            m2 = re.search(r'"height":(\d+).*"url":"([^"]*)"', part)
            if m1:
                url = m1.group(1).replace(r'\u0026', '&').replace(r'\u003D', '=')
                all_links.append({'resolution': m1.group(2) + 'p', 'url': url})
            elif m2:
                url = m2.group(2).replace(r'\u0026', '&').replace(r'\u003D', '=')
                all_links.append({'resolution': m2.group(1) + 'p', 'url': url})
    except Exception as e:
        log.warning(f"filemoon decrypt failed: {e}")
    return all_links


def decode_provider_id(hex_str: str) -> str:
    try:
        dec = bytes([int(hex_str[i:i+2], 16) ^ 56 for i in range(0, len(hex_str), 2)])
        return dec.decode('utf-8', errors='ignore').replace('/clock', '/clock.json')
    except Exception:
        return ""


async def get_links(session, provider_path: str) -> list:
    all_links = []
    
    if 'tools.fast4speed.rsvp' in provider_path:
        all_links.append({'resolution': 'mp4', 'url': provider_path, 'needsReferer': True})
        return all_links
        
    if 'mp4upload.com' in provider_path:
        return await get_mp4upload_links(session, provider_path)

    clock_timeout = 2 if '/clock.' in provider_path else 1
    fetch_url = provider_path if provider_path.startswith('http') else f"https://{MKISSA_BASE}{provider_path}"
    
    try:
        resp = await session.get(fetch_url, timeout=clock_timeout)
        if resp.status_code != 200:
            return all_links
        provider_data = resp.json()
        if _is_filemoon_payload(provider_data):
            # Some clock.json sources return an AES-encrypted payload instead
            # of the plain {links/hls} shape — without this branch these
            # sources silently resolved to zero links.
            return _parse_filemoon_payload(provider_data)
        if 'links' in provider_data and isinstance(provider_data['links'], list):
            for link in provider_data['links']:
                url = link.get('link')
                res = link.get('resolutionStr') or 'unknown'
                if not url:
                    continue
                if 'repackager.wixmp.com' in url:
                    cleaned = url.replace('repackager.wixmp.com/', '').split('.urlset')[0]
                    qualities_match = re.search(r'/,([^/]*),/mp4', url)
                    if qualities_match:
                        qualities = qualities_match.group(1).split(',')
                        for q in qualities:
                            q_url = re.sub(r',[^/]*', q, cleaned, count=1)
                            all_links.append({'resolution': q, 'url': q_url})
                else:
                    all_links.append({'resolution': res, 'url': url})
        if 'hls' in provider_data and provider_data['hls'] and 'url' in provider_data['hls']:
            all_links.append({'resolution': 'hls', 'url': provider_data['hls']['url']})
    except Exception:
        pass
    return all_links


def parse_source_lines(api_data: dict, key: bytes) -> list:
    resp_lines = []
    
    def unescape_source(s: str) -> str:
        return s.replace('\\u002F', '/').replace('\\/', '/').replace('\\u0026', '&').replace('\\u003D', '=').replace('\\', '')
        
    def extract_from_blob(blob: str):
        if not blob or len(blob) < 50:
            return
        plain = decrypt(blob, key)
        if not plain:
            return
        
        parts = re.sub(r'[{}]', '\n', plain).split('\n')
        for part in parts:
            m = re.search(r'"sourceUrl":"([^"]*)".*"sourceName":"([^"]*)"', part)
            if m:
                source_url = unescape_source(m.group(1))
                source_name = m.group(2)
                if source_url.startswith('--'):
                    resp_lines.append({'sourceName': source_name, 'hex': source_url[2:]})
                elif source_url.startswith('http') or source_url.startswith('/'):
                    resp_lines.append({'sourceName': source_name, 'directUrl': source_url})
                else:
                    resp_lines.append({'sourceName': source_name, 'hex': source_url})
                    
    data_dict = api_data.get('data', {})
    if data_dict and '_m' in data_dict and len(data_dict['_m']) > 10:
        extract_from_blob(data_dict['_m'])
    if data_dict and 'tobeparsed' in data_dict:
        extract_from_blob(data_dict['tobeparsed'])
    if 'tobeparsed' in api_data:
        extract_from_blob(api_data['tobeparsed'])
        
    if data_dict and 'episode' in data_dict and data_dict['episode'] and 'sourceUrls' in data_dict['episode']:
        raw = json.dumps(data_dict['episode']['sourceUrls'])
        cleaned = unescape_source(raw)
        parts = re.sub(r'[{}]', '\n', cleaned).split('\n')
        for part in parts:
            m = re.search(r'"sourceUrl":"([^"]*)".*"sourceName":"([^"]*)"', part)
            if m:
                source_url = m.group(1)
                source_name = m.group(2)
                if source_url.startswith('--'):
                    resp_lines.append({'sourceName': source_name, 'hex': source_url[2:]})
                elif source_url.startswith('http') or source_url.startswith('/'):
                    resp_lines.append({'sourceName': source_name, 'directUrl': source_url})
                else:
                    resp_lines.append({'sourceName': source_name, 'hex': source_url})
                    
    return resp_lines


async def get_okru_links(session, embed_url: str) -> list:
    all_links = []
    try:
        resp = await session.get(embed_url, timeout=5)
        if resp.status_code == 200:
            html = resp.text
            m3u8_urls = re.findall(r'https?://[^"\'\\` <>]+\.m3u8[^"\'\\` <>]*', html)
            mp4_urls = re.findall(r'https?://[^"\'\\` <>]+\.mp4[^"\'\\` <>]*', html)
            for url in m3u8_urls:
                url = url.replace('\\/', '/')
                all_links.append({'resolution': 'hls', 'url': url, 'referer': 'https://ok.ru/'})
            for url in mp4_urls:
                url = url.replace('\\/', '/')
                all_links.append({'resolution': 'mp4', 'url': url, 'referer': 'https://ok.ru/'})
    except Exception as e:
        log.warning(f"ok.ru extract failed: {e}")
    return all_links


class MkissaProvider:
    def __init__(self):
        self.session = AsyncSession(impersonate="chrome131")
        self.session.headers.update({
            "User-Agent": AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": MKISSA_REFR,
            "Origin": MKISSA_REFR,
        })
        self.auth_data = None

    async def _ensure_authconfigs(self):
        # The site's own auth blob carries its rotation schedule (epoch,
        # switchAt in epoch-ms, graceMs) — its JS explicitly re-fetches once
        # switchAt passes ("epoch switchAt passed — reset cache"). We only
        # ever fetched once per scraper process before; on a long-running
        # session (this normally self-heals via the ~60s idle sidecar
        # restart, but doesn't during a long binge) the signing token would
        # start using a stale epoch and every stream request would silently
        # fail. Re-fetch once we're past switchAt, same as the site does.
        if self.auth_data:
            switch_at = self.auth_data.get('switchAt')
            try:
                if switch_at is None or time.time() * 1000 < float(switch_at):
                    return
            except (ValueError, TypeError):
                pass
            log.info("mkissa: epoch switchAt passed, refreshing auth config")
        try:
            resp = await self.session.get(f"{MKISSA_REFR}/", timeout=5)
            import re
            m = re.search(r'\{[^{}]*"partB":"[^"]+"[^{}]*\}', resp.text)
            if m:
                self.auth_data = json.loads(m.group(0))
            else:
                log.warning("Could not find auth_data in HTML.")
                self.auth_data = {}
        except Exception as e:
            log.warning(f"Failed to fetch auth configs from HTML: {e}")
            self.auth_data = {}

    def _get_crypto_token(self, query_hash: str) -> str:
        import time
        from hashlib import sha256
        import json
        
        epoch = self.auth_data.get('epoch', 0)
        partB = self.auth_data.get('partB', '')
        cr = MKISSA_BUILD_ID

        try:
            Dn = bytes.fromhex(MKISSA_MASK_HEX)
            partB_bytes = base64.b64decode(partB)
            key = bytes([partB_bytes[i] ^ Dn[i] for i in range(32)])
            
            ts = int(time.time() * 1000 / 300000) * 300000
            i_str = f"{epoch}:{cr}:{query_hash}:{ts}"
            iv = sha256(i_str.encode()).digest()[:12]
            
            a = json.dumps({"v": 1, "ts": ts, "epoch": epoch, "buildId": cr, "qh": query_hash}, separators=(',', ':'))
            
            cipher = AES.new(key, AES.MODE_GCM, nonce=iv)
            ciphertext, tag = cipher.encrypt_and_digest(a.encode())
            s = ciphertext + tag
            
            c = bytearray(13 + len(s))
            c[0] = 1
            c[1:13] = iv
            c[13:] = s
            return base64.b64encode(c).decode()
        except Exception as e:
            log.error(f"Crypto token generation failed: {e}")
            return ""

    async def _post_api(self, payload: dict, timeout: int = 8, attempts: int = 3) -> dict:
        """POST to the Mkissa GraphQL API, retrying transient failures.

        Mkissa intermittently returns 5xx or drops the connection. A single
        failure here used to make the whole provider fall back to AniNeko, so
        retry a few times with a short backoff before giving up. Client errors
        (4xx) are not transient and are raised immediately.
        """
        last_exc: Optional[Exception] = None
        for attempt in range(attempts):
            try:
                resp = await self.session.post(f"{MKISSA_API}/api", json=payload, timeout=timeout)
                if resp.status_code >= 500:
                    # Log the body so a recurring 5xx is diagnosable (Cloudflare
                    # block pages, JSON error bodies, etc.) rather than opaque.
                    body = ""
                    try:
                        body = resp.text[:300]
                    except Exception:
                        pass
                    log.warning(f"Mkissa API HTTP {resp.status_code} (attempt {attempt + 1}/{attempts}); body: {body!r}")
                    raise RuntimeError(f"HTTP {resp.status_code}")
                resp.raise_for_status()
                return resp.json()
            except Exception as e:
                last_exc = e
                log.warning(f"Mkissa API request error (attempt {attempt + 1}/{attempts}): {type(e).__name__}: {e}")
                if attempt < attempts - 1:
                    await asyncio.sleep(0.6 * (attempt + 1))
        raise last_exc if last_exc else RuntimeError("Mkissa API request failed")

    async def search(self, query: str) -> list[AnimeRef]:
        # Clean query: Mkissa's GraphQL API fails when search queries contain apostrophes.
        # We replace "'s" (case-insensitive) with an empty string and then remove remaining apostrophes.
        cleaned_query = re.sub(r"'s\b", "", query, flags=re.IGNORECASE)
        cleaned_query = cleaned_query.replace("'", "")
        
        search_gql = """query($search: SearchInput $limit: Int $page: Int $translationType: VaildTranslationTypeEnumType $countryOrigin: VaildCountryOriginEnumType) {
            shows( search: $search limit: $limit page: $page translationType: $translationType countryOrigin: $countryOrigin ) {
                edges {
                    _id
                    name
                    englishName
                    nativeName
                    availableEpisodes
                    __typename
                }
            }
        }"""
        
        try:
            payload = {
                "variables": {
                    "search": {
                        "allowAdult": False,
                        "allowUnknown": False,
                        "query": cleaned_query
                    },
                    "limit": 40,
                    "page": 1,
                    "translationType": "sub",
                    "countryOrigin": "ALL"
                },
                "query": search_gql
            }
            
            data = await self._post_api(payload)
            return self._extract_search_results(data)
        except Exception as e:
            log.error(f"Mkissa search failed: {e}")
            return []

    @staticmethod
    def _extract_search_results(data: dict) -> list[AnimeRef]:
        shows = data.get("data", {}).get("shows", {}).get("edges", [])
        if not shows:
            warn_empty("mkissa", "data.shows.edges", "search results")
            return []
        results = []
        for show in shows:
            show_id = show.get("_id")
            title = show.get("englishName") or show.get("name", "").replace('\\"', '"')
            if not show_id or not title:
                continue
            results.append(AnimeRef(id=show_id, title=title))
        return results

    async def get(self, slug: str) -> Optional[AnimeInfo]:
        query = """query ($showId: String!) {
            show( _id: $showId ) {
                _id
                name
                englishName
                nativeName
                thumbnail
                description
                status
                availableEpisodes
                availableEpisodesDetail
            }
        }"""
        try:
            payload = {
                "variables": {"showId": slug},
                "query": query
            }
            data = await self._post_api(payload)
            show = data.get("data", {}).get("show")
            if not show:
                return None

            title = show.get("englishName") or show.get("name")

            eps_detail = show.get("availableEpisodesDetail", {}) or {}
            sub_eps = eps_detail.get("sub", []) or []
            dub_eps = eps_detail.get("dub", []) or []

            all_ep_strings = sorted(list(set(sub_eps + dub_eps)), key=lambda x: float(x) if x else 0.0)
            episodes = []
            for ep_str in all_ep_strings:
                try:
                    if not ep_str:
                        continue
                    ep_num = int(float(ep_str))
                    if ep_num not in [e.number for e in episodes]:
                        episodes.append(Episode(number=ep_num))
                except ValueError:
                    continue

            # availableEpisodesDetail sometimes comes back empty even when the
            # show has episodes (transient API quirk). Fall back to the simpler
            # availableEpisodes count so we can at least build a numbered list.
            if not episodes:
                counts = show.get("availableEpisodes", {}) or {}
                ep_count = max(
                    counts.get("sub", 0) or 0,
                    counts.get("dub", 0) or 0,
                )
                if ep_count > 0:
                    log.warning(
                        "mkissa: availableEpisodesDetail empty for slug %s "
                        "but availableEpisodes reports %d — synthesising list",
                        slug, ep_count,
                    )
                    episodes = [Episode(number=n) for n in range(1, ep_count + 1)]

            return AnimeInfo(title=title, episodes=episodes)
        except Exception as e:
            log.error(f"Mkissa get failed: {e}")
            return None

    async def streams(self, slug: str, episode: int, debug: bool = False) -> Tuple[List[StreamServer], List[dict]]:
        debug_log = []
        ep_no = str(episode)

        episode_embed_gql = """query ($showId: String!, $translationType: VaildTranslationTypeEnumType!, $episodeString: String!) {
            episode( showId: $showId translationType: $translationType episodeString: $episodeString ) {
                episodeString
                sourceUrls
            }
        }"""

        async def resolve_entry(entry, mode):
            source_name = entry.get('sourceName', 'Unknown')
            resolved_path = None
            if 'directUrl' in entry:
                resolved_path = entry['directUrl']
            elif 'hex' in entry:
                resolved_path = decode_provider_id(entry['hex'])

            if not resolved_path:
                return []

            if 'ok.ru' in resolved_path or 'okcdn' in resolved_path:
                links = await get_okru_links(self.session, resolved_path)
            elif 'tools.fast4speed.rsvp' in resolved_path:
                links = [{'resolution': 'mp4', 'url': resolved_path, 'needsReferer': True}]
            elif 'mp4upload.com' in resolved_path:
                links = await get_mp4upload_links(self.session, resolved_path)
            else:
                links = await get_links(self.session, resolved_path)

            resolved_servers = []
            for link in links:
                url = link.get('url')
                res = link.get('resolution') or 'unknown'
                if not url:
                    continue

                final_url = re.sub(r'([^:])//', r'\1/', url)

                headers = {}
                if link.get('needsReferer') or 'tools.fast4speed.rsvp' in final_url:
                    headers['Referer'] = MKISSA_REFR
                elif link.get('referer'):
                    headers['Referer'] = link['referer']

                if 'wixmp' in final_url and 'Referer' not in headers:
                    headers['Referer'] = "https://allanime.day/"

                # Sources like mp4upload, filemoon, and fast4speed serve
                # raw video without burned-in subs even under the "sub"
                # translation type.  Only wixmp/sharepoint/ok.ru streams
                # carry actual hardsubs.  Tag the rest as "soft_sub" so
                # the picker prefers real hardsub sources.
                if mode == "sub":
                    url_lc = final_url.lower()
                    if any(h in url_lc for h in ('wixmp', 'wixstatic', 'sharepoint', 'okcdn', 'ok.ru')):
                        group = "hard_sub"
                    else:
                        group = "soft_sub"
                else:
                    group = mode

                resolved_servers.append(StreamServer(
                    name=f"Mkissa - {source_name} ({res}) - {mode.capitalize()}",
                    url=final_url,
                    quality=res,
                    is_m3u8=bool(".m3u8" in final_url or "master.m3u8" in final_url),
                    headers=headers if headers else None,
                    group=group,
                    source_type="mkissa"
                ))
            return resolved_servers

        async def fetch_mode(mode):
            api_data = None
            try:
                await self._ensure_authconfigs()
                crypto_token = self._get_crypto_token(EPISODE_QUERY_HASH)
                
                query_vars = json.dumps({"showId": slug, "translationType": mode, "episodeString": ep_no}, separators=(',', ':'))
                query_ext = json.dumps({"persistedQuery": {"version": 1, "sha256Hash": EPISODE_QUERY_HASH}, "aaReq": crypto_token}, separators=(',', ':'))
                api_url = f"{MKISSA_API}/api?variables={urllib.parse.quote(query_vars)}&extensions={urllib.parse.quote(query_ext)}"

                get_resp = await self.session.get(api_url, headers={
                    'User-Agent': AGENT,
                    'Referer': MKISSA_REFR,
                    'Origin': MKISSA_REFR,
                    'x-build-id': MKISSA_BUILD_ID
                }, timeout=3)
                if get_resp.status_code == 200:
                    raw_text = get_resp.text
                    if raw_text and ('tobeparsed' in raw_text or '"_m"' in raw_text):
                        api_data = get_resp.json()
            except Exception as e:
                log.warning(f"Mkissa GET persisted query failed for {mode}: {e}")

            if not api_data:
                try:
                    payload = {
                        "variables": {
                            "showId": slug,
                            "translationType": mode,
                            "episodeString": ep_no
                        },
                        "query": episode_embed_gql
                    }
                    post_resp = await self.session.post(f"{MKISSA_API}/api", json=payload, timeout=8)
                    post_resp.raise_for_status()
                    api_data = post_resp.json()
                except Exception as e:
                    log.warning(f"Mkissa POST failed for {mode}: {e}")

            if not api_data:
                return []

            resp_lines = parse_source_lines(api_data, MKISSA_RESPONSE_KEY)
            
            if not resp_lines:
                return []

            tasks = []
            for entry in resp_lines:
                tasks.append(resolve_entry(entry, mode))
            return tasks

        mode_results = await asyncio.gather(fetch_mode("sub"), fetch_mode("dub"), return_exceptions=True)

        all_tasks = []
        for res in mode_results:
            if isinstance(res, list):
                all_tasks.extend(res)
            elif isinstance(res, Exception):
                log.warning(f"Mode fetch failed: {res}")

        all_resolved_servers = []
        if all_tasks:
            results = await asyncio.gather(*all_tasks, return_exceptions=True)
            for res in results:
                if isinstance(res, list):
                    all_resolved_servers.extend(res)
                elif isinstance(res, Exception):
                    log.warning(f"Task failed: {res}")

        seen_urls = set()
        unique_servers = []
        for server in all_resolved_servers:
            if server.url not in seen_urls:
                seen_urls.add(server.url)
                unique_servers.append(server)

        return unique_servers, debug_log
