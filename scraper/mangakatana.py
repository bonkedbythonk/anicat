import re
from typing import Optional, List
from curl_cffi import requests
from selectolax.parser import HTMLParser
from urllib.parse import quote_plus

from diagnostics import warn_empty

BASE_URL = "https://mangakatana.com"

class MangaKatanaProvider:
    def __init__(self):
        self.session = requests.Session(impersonate="chrome131")
        self.session.headers.update(
            {
                "Referer": BASE_URL,
                "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                "Accept-Language": "en-US,en;q=0.9",
                "User-Agent": (
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/131.0.0.0 Safari/537.36"
                ),
            }
        )

    async def search(self, query: str) -> List[dict]:
        try:
            encoded_query = quote_plus(query)
            url = f"{BASE_URL}/?search={encoded_query}&search_by=book_name"
            resp = self.session.get(url, allow_redirects=True, timeout=20)
            if resp.status_code != 200:
                return []
            
            html = resp.text
            # If the search redirects directly to a manga page (single result),
            # handle that case
            if "/manga/" in str(resp.url) and "search" not in str(resp.url):
                return self._parse_single_result(html, str(resp.url))
            else:
                return self._parse_search_results(html)
        except Exception as e:
            print(f"[MANGAKATANA] Search error: {e}")
            return []

    @staticmethod
    def _parse_single_result(html: str, url: str) -> List[dict]:
        try:
            tree = HTMLParser(html)
            title_el = tree.css_first("h1")
            title = title_el.text(strip=True) if title_el else "Unknown"
            
            cover_el = tree.css_first(".cover img")
            cover_image = cover_el.attributes.get("src", "") if cover_el else ""
            
            return [{"id": url, "title": title, "cover_image": cover_image}]
        except Exception as e:
            print(f"[MANGAKATANA] Parse single result error: {e}")
            return [{"id": url, "title": "Unknown", "cover_image": ""}]

    @staticmethod
    def _parse_search_results(html: str) -> List[dict]:
        try:
            tree = HTMLParser(html)
            items = tree.css("#book_list .item")
            if not items:
                warn_empty("mangakatana", "#book_list .item", "search results")
                return []
            results = []
            for item in items:
                title_el = item.css_first(".title a")
                if not title_el:
                    continue

                manga_url = title_el.attributes.get("href", "")
                title = title_el.text(strip=True)
                if manga_url and not manga_url.startswith("http"):
                    manga_url = f"{BASE_URL}{manga_url}"

                cover_el = item.css_first("img")
                cover_image = cover_el.attributes.get("src", "") if cover_el else ""

                results.append({
                    "id": manga_url,
                    "title": title,
                    "cover_image": cover_image
                })
            return results
        except Exception as e:
            print(f"[MANGAKATANA] Parse search results error: {e}")
            return []

    async def get(self, url: str) -> Optional[dict]:
        try:
            resp = self.session.get(url, allow_redirects=True, timeout=20)
            if resp.status_code != 200:
                return None
            
            return self._parse_manga_page(resp.text)
        except Exception as e:
            print(f"[MANGAKATANA] Get manga error: {e}")
            return None

    @staticmethod
    def _parse_manga_page(html: str) -> dict:
        tree = HTMLParser(html)

        title_el = tree.css_first("h1.heading") or tree.css_first("h1")
        title = title_el.text(strip=True) if title_el else "Unknown"

        cover_el = tree.css_first(".cover img") or tree.css_first(".media img")
        cover_image = cover_el.attributes.get("src", "") if cover_el else ""

        chapter_links = tree.css(".chapters .chapter a")
        if not chapter_links:
            warn_empty("mangakatana", ".chapters .chapter a", f"detail page '{title}'")

        chapters = []
        for ch_el in chapter_links:
            ch_url = ch_el.attributes.get("href", "")
            ch_title = ch_el.text(strip=True)
            if ch_url and not ch_url.startswith("http"):
                ch_url = f"{BASE_URL}{ch_url}"
            if ch_url and ch_title:
                num_match = re.search(r"Chapter\s+(\d+\.?\d*)", ch_title)
                num = num_match.group(1) if num_match else "0"

                try:
                    num_val = int(float(num))
                except ValueError:
                    num_val = 0

                chapters.append({
                    "number": num_val,
                    "title": ch_title,
                    "url": ch_url
                })

        # Reverse chapters to be in ascending order (newest is first in MangaKatana)
        chapters.reverse()

        return {
            "title": title,
            "cover_image": cover_image,
            "chapters": chapters
        }

    async def get_pages(self, chapter_url: str) -> Optional[dict]:
        try:
            resp = self.session.get(chapter_url, allow_redirects=True, timeout=20)
            if resp.status_code != 200:
                return None
            
            html = resp.text
            js_array_pattern = re.compile(r"var\s+\w+\s*=\s*\[([^\]]+)\]\s*;", re.DOTALL)
            
            image_urls = []
            for match in js_array_pattern.finditer(html):
                array_content = match.group(1)
                url_pattern = re.compile(
                    r"['\"]([^'\"]+(?:\.jpg|\.png|\.webp|\.jpeg)[^'\"]*)['\"]",
                    re.IGNORECASE,
                )
                urls = url_pattern.findall(array_content)
                if urls and len(urls) > 1:
                    image_urls = urls
                    break
            
            if not image_urls:
                img_pattern = re.compile(
                    r'<img[^>]+src=["\']([^"\']+(?:\.jpg|\.png|\.webp|\.jpeg)[^"\']*)["\'][^>]*>',
                    re.IGNORECASE,
                )
                imgs_section = re.search(
                    r'id=["\']imgs["\'][^>]*>(.*?)</div>', html, re.DOTALL
                )
                if imgs_section:
                    image_urls = img_pattern.findall(imgs_section.group(1))
                else:
                    tree = HTMLParser(html)
                    all_imgs = [img.attributes.get("src", "") for img in tree.css("img")]
                    image_urls = [
                        url for url in all_imgs if "mangakatana" in url and "/manga/" in url
                    ]
            
            chapter_title = chapter_url.rstrip("/").split("/")[-1]
            return {
                "thumbnails": image_urls,
                "title": chapter_title
            }
        except Exception as e:
            print(f"[MANGAKATANA] Get chapter pages error: {e}")
            return None
