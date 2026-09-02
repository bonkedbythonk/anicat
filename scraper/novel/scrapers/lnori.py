"""Scraper for Lnori (lnori.com), which shares RanobeDB's series and book ids.

A volume on Lnori is a single page: the whole book's text lives inline under
`article.content-body`, split into `section.chapter#pageNN`, with an in-page
table of contents in `nav#toc-list`. So a "chapter" URL here is the book URL
plus a `#pageNN` fragment, and fetching a chapter means fetching (or reusing)
the book page and slicing one section out of it.
"""

import re
import time
import threading
import urllib.parse
from typing import Dict, List, Optional, Tuple
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter, SeriesInfo
from ..api import RanobeDBClient


LNORI_ORIGIN = "https://lnori.com"
SERIES_SITEMAP = f"{LNORI_ORIGIN}/sitemap/sitemap-series.xml"

# Lnori 404s on a bare `/series/<id>` — the title slug is part of the path — so
# the series sitemap is the id -> URL map. It is ~80KB and changes rarely.
_SITEMAP_TTL = 6 * 60 * 60
_sitemap_lock = threading.Lock()
_sitemap_cache: Tuple[float, Dict[int, str]] = (0.0, {})

# One volume page is ~500KB and holds every chapter, so reading a volume
# straight through would otherwise refetch it once per chapter.
_PAGE_TTL = 15 * 60
_page_lock = threading.Lock()
_page_cache: Dict[str, Tuple[float, str]] = {}


def _label_rank(label: str) -> Tuple[int, int]:
    return (1 if re.search(r"\d", label) else 0, len(label))


class LnoriScraper(BaseScraper):
    """Scraper for Lnori (lnori.com) light novels."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.rndb_client = RanobeDBClient()

    def can_handle(self, url: str) -> bool:
        netloc = urllib.parse.urlparse(url).netloc.lower()
        return "lnori.com" in netloc

    # ── URL helpers ──────────────────────────────────────────────

    def extract_series_id(self, url: str) -> Optional[int]:
        match = re.search(r"/series/(\d+)", url)
        return int(match.group(1)) if match else None

    def _extract_book_id(self, url: str) -> Optional[int]:
        match = re.search(r"/book/(\d+)", url)
        return int(match.group(1)) if match else None

    def _load_series_sitemap(self) -> Dict[int, str]:
        global _sitemap_cache
        with _sitemap_lock:
            stamp, cached = _sitemap_cache
            if cached and (time.time() - stamp) < _SITEMAP_TTL:
                return cached
        xml = self.fetch_html(SERIES_SITEMAP)
        mapping = {
            int(sid): f"{LNORI_ORIGIN}/series/{sid}/{slug}"
            for sid, slug in re.findall(r"/series/(\d+)/([^<\s]+)", xml)
        }
        with _sitemap_lock:
            _sitemap_cache = (time.time(), mapping)
        return mapping

    def resolve_series_url(self, series_id: int) -> Optional[str]:
        """Map a RanobeDB series id onto its Lnori URL, or None if not carried."""
        try:
            return self._load_series_sitemap().get(int(series_id))
        except Exception:
            return None

    def fetch_page(self, url: str) -> str:
        """Fetch a Lnori page, reusing a recent copy when there is one."""
        key = url.split("#", 1)[0]
        now = time.time()
        with _page_lock:
            hit = _page_cache.get(key)
            if hit and (now - hit[0]) < _PAGE_TTL:
                return hit[1]
        html = self.fetch_html(key)
        with _page_lock:
            _page_cache[key] = (time.time(), html)
            if len(_page_cache) > 8:
                oldest = min(_page_cache, key=lambda k: _page_cache[k][0])
                _page_cache.pop(oldest, None)
        return html

    # ── Novel / volume parsing ───────────────────────────────────

    def get_novel_info(self, url: str) -> Novel:
        parsed = urllib.parse.urlparse(url)

        if "/book/" in parsed.path:
            return self._parse_single_book(url)
        if "/series/" in parsed.path:
            return self._parse_series(url)
        raise ValueError(f"Unsupported Lnori URL format: {url}. Provide a /series/ or /book/ URL.")

    def _fetch_ranobedb_series_info(self, series_id: int) -> Optional[SeriesInfo]:
        try:
            return self.rndb_client.get_series(series_id)
        except Exception:
            return None

    def _parse_single_book(self, book_url: str) -> Novel:
        html = self.fetch_page(book_url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one("#book-title") or soup.select_one("h1")
        title = title_el.get_text(strip=True) if title_el else ""

        author_el = soup.select_one("#book-author")
        author = author_el.get_text(strip=True) if author_el else ""

        book_id = self._extract_book_id(book_url)
        series_info = None
        if book_id:
            try:
                book = self.rndb_client.get_book(book_id)
                if book.title:
                    title = book.title
            except Exception:
                pass

        if not title:
            doc_title = soup.select_one("title")
            title = doc_title.get_text(strip=True).split(" | ")[0] if doc_title else f"Book {book_id}"
        if not author:
            author = "Unknown Author"

        desc_el = soup.select_one("meta[name='description']")
        description = desc_el.get("content", "") if desc_el else ""

        return Novel(
            title=title,
            author=author,
            description=description,
            source_url=book_url,
            cover_image_url=f"https://img.lnori.com/{book_id}-01.jpg" if book_id else None,
            chapters=self.extract_toc(soup, book_url),
            series_info=series_info,
            language="en",
        )

    def list_volumes(self, series_url: str) -> List[Tuple[int, str, str]]:
        """Return (book_id, title, url) for every volume linked from a series page."""
        soup = BeautifulSoup(self.fetch_page(series_url), "html.parser")
        found: Dict[int, Tuple[str, str]] = {}
        for a in soup.select("a[href*='/book/']"):
            href = a.get("href", "")
            book_id = self._extract_book_id(href)
            if not book_id:
                continue
            # The same volume is linked from its card and from a "Start Reading"
            # call to action. A volume label carries its number, so prefer one
            # that does, and among those the most descriptive.
            label = a.get("title") or a.get_text(strip=True) or ""
            previous = found.get(book_id)
            if previous and _label_rank(previous[0]) >= _label_rank(label):
                continue
            found[book_id] = (label, urllib.parse.urljoin(LNORI_ORIGIN, href))
        return [
            (book_id, label or f"Volume {idx}", url)
            for idx, (book_id, (label, url)) in enumerate(sorted(found.items()), start=1)
        ]

    def _parse_series(self, series_url: str) -> Novel:
        soup = BeautifulSoup(self.fetch_page(series_url), "html.parser")

        title_el = soup.select_one("h1")
        title = title_el.get_text(strip=True) if title_el else "Lnori Series"

        series_id = self.extract_series_id(series_url)
        series_info = self._fetch_ranobedb_series_info(series_id) if series_id else None

        author = ", ".join(series_info.authors) if (series_info and series_info.authors) else "Unknown Author"
        description = series_info.description if series_info else ""

        cover_img = soup.select_one("img[src*='img.lnori.com']")
        cover_url = cover_img.get("src") if cover_img else (series_info.primary_cover_url if series_info else None)

        # One entry per volume, pointing at the volume page as a whole. Opening
        # every volume just to list its sections would be dozens of ~500KB
        # fetches; callers that want a volume's sections ask for its own TOC.
        all_chapters = [
            Chapter(index=v_idx, title=v_name or f"Volume {v_idx:02d}", url=v_url, volume_name=v_name)
            for v_idx, (_book_id, v_name, v_url) in enumerate(self.list_volumes(series_url), start=1)
        ]

        return Novel(
            title=title,
            author=author,
            description=description,
            source_url=series_url,
            cover_image_url=cover_url,
            chapters=all_chapters,
            series_info=series_info,
            language="en",
        )

    def extract_toc(self, soup: BeautifulSoup, book_url: str, volume_name: Optional[str] = None) -> List[Chapter]:
        """Build the chapter list for one volume from its in-page table of contents."""
        base = book_url.split("#", 1)[0]
        if volume_name is None:
            title_el = soup.select_one("#book-title")
            volume_name = title_el.get_text(strip=True) if title_el else None

        chapters: List[Chapter] = []
        seen = set()
        for a in soup.select("nav#toc-list a[href^='#'], .toc-view a[href^='#']"):
            frag = a.get("href", "")
            if len(frag) < 2 or frag in seen:
                continue
            seen.add(frag)
            chapters.append(Chapter(
                index=len(chapters) + 1,
                title=a.get("title") or a.get_text(strip=True) or f"Chapter {len(chapters) + 1}",
                url=f"{base}{frag}",
                volume_name=volume_name,
            ))

        # No table of contents: fall back to the sections themselves.
        if not chapters:
            for section in soup.select("article.content-body section[id], #main-content section[id]"):
                sec_id = section.get("id")
                if not sec_id:
                    continue
                heading = section.find(["h1", "h2", "h3"])
                chapters.append(Chapter(
                    index=len(chapters) + 1,
                    title=heading.get_text(strip=True) if heading else f"Section {len(chapters) + 1}",
                    url=f"{base}#{sec_id}",
                    volume_name=volume_name,
                ))

        return chapters

    # ── Chapter text ─────────────────────────────────────────────

    def fetch_chapter_content(self, chapter: Chapter) -> Chapter:
        base, _, fragment = (chapter.url or "").partition("#")
        soup = BeautifulSoup(self.fetch_page(base), "html.parser")

        content_el = None
        if fragment:
            content_el = soup.find(id=fragment)
        if content_el is None:
            content_el = soup.select_one("article.content-body") or soup.select_one("#main-content")

        if content_el is None:
            chapter.content_html = None
            chapter.content_text = ""
            return chapter

        for img in content_el.find_all("img"):
            src = img.get("src") or img.get("data-src")
            if src:
                img["src"] = urllib.parse.urljoin(base, src)
        for source in content_el.find_all("source"):
            srcset = source.get("srcset")
            if srcset:
                parts = srcset.split()
                parts[0] = urllib.parse.urljoin(base, parts[0])
                source["srcset"] = " ".join(parts)

        text = content_el.get_text("\n", strip=True)
        chapter.content_html = self.clean_html_body(content_el) if text or content_el.find("img") else None
        chapter.content_text = text
        return chapter
