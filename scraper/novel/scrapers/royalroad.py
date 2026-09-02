"""Scraper for Royal Road (royalroad.com)."""

import re
import urllib.parse
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter


class RoyalRoadScraper(BaseScraper):
    """Scraper for RoyalRoad web novels."""

    def can_handle(self, url: str) -> bool:
        netloc = urllib.parse.urlparse(url).netloc.lower()
        return "royalroad.com" in netloc

    def get_novel_info(self, url: str) -> Novel:
        html = self.fetch_html(url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one("h1")
        title = title_el.get_text(strip=True) if title_el else "Unknown RoyalRoad Novel"

        author_el = soup.select_one("h4 a[href*='/profile/']")
        author = author_el.get_text(strip=True) if author_el else "Unknown Author"

        desc_el = soup.select_one(".description")
        description = desc_el.get_text("\n", strip=True) if desc_el else ""

        cover_img = soup.select_one(".thumbnail[src]")
        cover_url = cover_img.get("src") if cover_img else None

        chapters = []
        idx = 0
        rows = soup.select("#chapters tbody tr")
        for tr in rows:
            a = tr.select_one("a[href*='/chapter/']")
            if a:
                href = urllib.parse.urljoin(url, a.get("href"))
                ch_title = a.get_text(strip=True)
                idx += 1
                chapters.append(Chapter(
                    index=idx,
                    title=ch_title,
                    url=href,
                ))

        return Novel(
            title=title,
            author=author,
            description=description,
            source_url=url,
            cover_image_url=cover_url,
            chapters=chapters,
            language="en",
        )

    def fetch_chapter_content(self, chapter: Chapter) -> Chapter:
        html = self.fetch_html(chapter.url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one(".chapter-heading h1, h1")
        if title_el and not chapter.title:
            chapter.title = title_el.get_text(strip=True)

        body_el = soup.select_one(".chapter-inner, .chapter-content")
        if body_el:
            cleaned = self.clean_html_body(body_el)
            chapter.content_html = f'<div class="chapter-body">{cleaned}</div>'
            chapter.content_text = body_el.get_text()
        else:
            chapter.content_html = "<p>No content found.</p>"
            chapter.content_text = ""

        return chapter
