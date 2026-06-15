import re
import json
import hashlib
import base64
import logging
import urllib.parse
import asyncio
from dataclasses import dataclass, field
from typing import Optional, List, Tuple
from Crypto.Cipher import AES
from Crypto.Util import Counter
from curl_cffi import requests
from curl_cffi.requests import AsyncSession

log = logging.getLogger(__name__)

AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:150.0) Gecko/20100101 Firefox/150.0"
ALLANIME_REFR = "https://youtu-chan.com"
ALLANIME_BASE = "allanime.day"
ALLANIME_API = f"https://api.{ALLANIME_BASE}"
ALLANIME_KEY = hashlib.sha256(b"Xot36i3lK3:v1").hexdigest()

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


def decrypt(blob: str) -> Optional[str]:
    try:
        data = base64.b64decode(blob)
        iv = data[1:13]
        ct_len = len(data) - 13 - 16
        ciphertext = data[13 : 13 + ct_len]
        
        counter_block = iv + b'\x00\x00\x00\x02'
        initial_value = int.from_bytes(counter_block, byteorder='big')
        ctr = Counter.new(128, initial_value=initial_value)
        cipher = AES.new(bytes.fromhex(ALLANIME_KEY), AES.MODE_CTR, counter=ctr)
        decrypted = cipher.decrypt(ciphertext)
        return decrypted.decode('utf-8')
    except Exception as e:
        log.debug(f"Decryption failed: {e}")
        return None


async def get_mp4upload_links(session, page_url: str) -> list:
    all_links = []
    try:
        resp = await session.get(page_url, timeout=1)
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


async def get_filemoon_links(session, provider_path: str) -> list:
    all_links = []
    fetch_url = provider_path if provider_path.startswith('http') else f"https://{ALLANIME_BASE}{provider_path}"
    try:
        resp = await session.get(fetch_url, timeout=1)
        if resp.status_code == 200:
            fm_data = resp.json()
            if fm_data and 'iv' in fm_data and 'payload' in fm_data and 'key_parts' in fm_data:
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
        log.warning(f"filemoon extract failed: {e}")
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
        all_links.append({'resolution': 'Yt', 'url': provider_path, 'needsReferer': True})
        return all_links
        
    if 'mp4upload.com' in provider_path:
        return await get_mp4upload_links(session, provider_path)
        
    fetch_url = provider_path if provider_path.startswith('http') else f"https://{ALLANIME_BASE}{provider_path}"
    
    try:
        resp = await session.get(fetch_url, timeout=1)
        if resp.status_code == 200:
            provider_data = resp.json()
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
                    else:
                        all_links.append({'resolution': res, 'url': url})
            if 'hls' in provider_data and provider_data['hls'] and 'url' in provider_data['hls']:
                all_links.append({'resolution': 'hls', 'url': provider_data['hls']['url']})
    except Exception as e:
        log.warning(f"get_links failed: {e}")
    return all_links


def parse_source_lines(api_data: dict) -> list:
    resp_lines = []
    
    def unescape_source(s: str) -> str:
        return s.replace('\\u002F', '/').replace('\\/', '/').replace('\\u0026', '&').replace('\\u003D', '=').replace('\\', '')
        
    def extract_from_blob(blob: str):
        if not blob or len(blob) < 50:
            return
        plain = decrypt(blob)
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


class AllAnimeProvider:
    def __init__(self):
        self.session = AsyncSession(impersonate="chrome131")
        self.session.headers.update({
            "User-Agent": AGENT,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
            "Referer": ALLANIME_REFR,
            "Origin": ALLANIME_REFR,
        })
        self._episode_offsets: dict[str, int] = {}

    async def search(self, query: str) -> list[AnimeRef]:
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
                        "query": query
                    },
                    "limit": 40,
                    "page": 1,
                    "translationType": "sub",
                    "countryOrigin": "ALL"
                },
                "query": search_gql
            }
            
            resp = await self.session.post(f"{ALLANIME_API}/api", json=payload, timeout=8)
            resp.raise_for_status()
            data = resp.json()
            shows = data.get("data", {}).get("shows", {}).get("edges", [])
            
            results = []
            for show in shows:
                show_id = show.get("_id")
                title = show.get("englishName") or show.get("name", "").replace('\\"', '"')
                if not show_id or not title:
                    continue
                results.append(AnimeRef(id=show_id, title=title))
            return results
        except Exception as e:
            log.error(f"AllAnime search failed: {e}")
            return []

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
                availableEpisodesDetail
            }
        }"""
        try:
            payload = {
                "variables": {"showId": slug},
                "query": query
            }
            resp = await self.session.post(f"{ALLANIME_API}/api", json=payload, timeout=8)
            resp.raise_for_status()
            data = resp.json()
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

            # Detect split-season entries (e.g. "Season 2 Part 2") and offset
            # episode numbers so titles from AniZip/AniList align correctly.
            part_match = re.search(r'(?i)\bpart\s*(\d+|one|two|three)\b', title)
            if part_match and episodes:
                season_match = _re.search(r'(?i)(?:Season|S)\s*(\d+)', title)
                season_num = season_match.group(1) if season_match else None
                base_title = _re.sub(r'(?i)\s*[-–—]?\s*(?:Season\s*\d*\s*)?[-–—~]?\s*Part\s*\w+', '', title).strip()
                if base_title and base_title != title:
                    search_gql = """query($search: SearchInput $limit: Int) {
                        shows(search: $search limit: $limit) { edges { _id name englishName } }
                    }"""
                    search_payload = {
                        "variables": {
                            "search": {"allowAdult": False, "allowUnknown": False, "query": base_title},
                            "limit": 10
                        },
                        "query": search_gql
                    }
                    try:
                        search_resp = await self.session.post(f"{ALLANIME_API}/api", json=search_payload, timeout=8)
                        search_data = search_resp.json()
                        edges = search_data.get("data", {}).get("shows", {}).get("edges", [])
                        if season_num:
                            season_label = f"Season {season_num}"
                            edges.sort(key=lambda e: 0 if season_label in (e.get("englishName") or e.get("name", "")) else 1)
                        offset = 0
                        for edge in edges:
                            eid = edge.get("_id")
                            ename = edge.get("englishName") or edge.get("name", "")
                            if not eid or eid == slug:
                                continue
                            if re.search(r'(?i)\bpart\s', ename):
                                continue
                            if base_title not in ename and not ename.startswith(base_title):
                                continue
                            try:
                                ep_resp = await self.session.post(f"{ALLANIME_API}/api", json={
                                    "variables": {"showId": eid},
                                    "query": "query ($showId: String!) { show( _id: $showId ) { availableEpisodesDetail } }"
                                }, timeout=8)
                                ep_data = ep_resp.json()
                                prev_detail = ep_data.get("data", {}).get("show", {}).get("availableEpisodesDetail", {}) or {}
                                prev_subs = prev_detail.get("sub", []) or []
                                prev_dubs = prev_detail.get("dub", []) or []
                                prev_all = sorted(set(prev_subs + prev_dubs), key=lambda x: float(x) if x else 0.0)
                                if prev_all:
                                    prev_last = int(float(prev_all[-1]))
                                    if prev_last > 0:
                                        offset = prev_last
                                        break
                            except Exception:
                                continue
                        if offset > 0:
                            for ep in episodes:
                                ep.number += offset
                            self._episode_offsets[slug] = offset
                    except Exception:
                        pass

            return AnimeInfo(title=title, episodes=episodes)
        except Exception as e:
            log.error(f"AllAnime get failed: {e}")
            return None

    async def streams(self, slug: str, episode: int, debug: bool = False) -> Tuple[List[StreamServer], List[dict]]:
        debug_log = []
        offset = self._episode_offsets.get(slug, 0)
        ep_no = str(episode - offset if offset > 0 else episode)

        episode_embed_gql = """query ($showId: String!, $translationType: VaildTranslationTypeEnumType!, $episodeString: String!) {
            episode( showId: $showId translationType: $translationType episodeString: $episodeString ) {
                episodeString
                sourceUrls
            }
        }"""

        provider_defs = [
            { 'name': 'Default', 'filemoon': False },
            { 'name': 'Mp4', 'filemoon': False },
            { 'name': 'Yt-mp4', 'filemoon': False },
            { 'name': 'S-mp4', 'filemoon': False },
            { 'name': 'Fm-mp4', 'filemoon': True },
            { 'name': 'Fm-Hls', 'filemoon': True },
            { 'name': 'Luf-Mp4', 'filemoon': False }
        ]

        async def resolve_one(prov, entry, mode):
            resolved_path = None
            if 'directUrl' in entry:
                resolved_path = entry['directUrl']
            elif 'hex' in entry:
                resolved_path = decode_provider_id(entry['hex'])

            if not resolved_path:
                return []

            if prov['filemoon']:
                links = await get_filemoon_links(self.session, resolved_path)
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
                    headers['Referer'] = ALLANIME_REFR
                elif link.get('referer'):
                    headers['Referer'] = link['referer']

                if 'wixmp' in final_url and 'Referer' not in headers:
                    headers['Referer'] = "https://allanime.day/"

                resolved_servers.append(StreamServer(
                    name=f"AllAnime - {prov['name']} ({res}) - {mode.capitalize()}",
                    url=final_url,
                    quality=res,
                    is_m3u8=bool(".m3u8" in final_url or "master.m3u8" in final_url),
                    headers=headers if headers else None,
                    group="hard_sub" if mode == "sub" else mode,
                    source_type="allanime"
                ))
            return resolved_servers

        async def fetch_mode(mode):
            api_data = None
            try:
                query_vars = json.dumps({"showId": slug, "translationType": mode, "episodeString": ep_no})
                query_ext = json.dumps({"persistedQuery": {"version": 1, "sha256Hash": EPISODE_QUERY_HASH}})
                api_url = f"{ALLANIME_API}/api?variables={urllib.parse.quote(query_vars)}&extensions={urllib.parse.quote(query_ext)}"

                get_resp = await self.session.get(api_url, headers={
                    'User-Agent': AGENT,
                    'Referer': ALLANIME_REFR,
                    'Origin': ALLANIME_REFR
                }, timeout=3)

                if get_resp.status_code == 200:
                    raw_text = get_resp.text
                    if raw_text and ('tobeparsed' in raw_text or '"_m"' in raw_text):
                        api_data = get_resp.json()
            except Exception:
                log.debug(f"AllAnime GET persisted query failed for {mode}")

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
                    post_resp = await self.session.post(f"{ALLANIME_API}/api", json=payload, timeout=8)
                    post_resp.raise_for_status()
                    api_data = post_resp.json()
                except Exception:
                    pass

            if not api_data:
                return []

            resp_lines = parse_source_lines(api_data)
            if not resp_lines:
                return []

            tasks = []
            for prov in provider_defs:
                entry = next((r for r in resp_lines if r['sourceName'] == prov['name']), None)
                if entry:
                    tasks.append(resolve_one(prov, entry, mode))
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
