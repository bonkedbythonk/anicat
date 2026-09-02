"""Scraper for Kakuyomu (kakuyomu.jp)."""

import re
import urllib.parse
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter


class KakuyomuScraper(BaseScraper):
    """Scraper for Kakuyomu web novels."""

    def can_handle(self, url: str) -> bool:
        netloc = urllib.parse.urlparse(url).netloc.lower()
        return "kakuyomu.jp" in netloc

    def _normalize_base_url(self, url: str) -> str:
        parsed = urllib.parse.urlparse(url)
        match = re.search(r"/works/(\d+)", parsed.path)
        if match:
            work_id = match.group(1)
            return f"https://kakuyomu.jp/works/{work_id}"
        return url

    def get_novel_info(self, url: str) -> Novel:
        base_url = self._normalize_base_url(url)
        html = self.fetch_html(base_url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one("#workTitle, h1[class*='workTitle']")
        title = title_el.get_text(strip=True) if title_el else "Unknown Kakuyomu Novel"

        author_el = soup.select_one("#workAuthor-activityName, a[class*='activityName']")
        author = author_el.get_text(strip=True) if author_el else "Unknown Author"

        desc_el = soup.select_one("#introduction, .ui-truncateText-lines")
        description = desc_el.get_text("\n", strip=True) if desc_el else ""

        chapters = []
        current_volume = None
        idx = 0

        toc_items = soup.select(".widget-toc-items > *")
        if not toc_items:
            toc_items = soup.select("[class*='widget-toc-main'] > *, .widget-toc-episode")

        for item in toc_items:
            if "widget-toc-chapter" in item.get("class", []):
                current_volume = item.get_text(strip=True)
            elif "widget-toc-episode" in item.get("class", []):
                a = item.select_one("a")
                if a and a.get("href"):
                    href = urllib.parse.urljoin(base_url, a.get("href"))
                    ch_title = a.get_text(strip=True)
                    idx += 1
                    chapters.append(Chapter(
                        index=idx,
                        title=ch_title,
                        url=href,
                        volume_name=current_volume,
                    ))

        return Novel(
            title=title,
            author=author,
            description=description,
            source_url=base_url,
            chapters=chapters,
            language="ja",
        )

    def fetch_chapter_content(self, chapter: Chapter) -> Chapter:
        html = self.fetch_html(chapter.url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one(".widget-episodeTitle")
        if title_el and not chapter.title:
            chapter.title = title_el.get_text(strip=True)

        body_el = soup.select_one(".widget-episodeBody, .js-episode-body")
        if body_el:
            cleaned = self.clean_html_body(body_el)
            chapter.content_html = f'<div class="chapter-body">{cleaned}</div>'
            chapter.content_text = body_el.get_text()
        else:
            chapter.content_html = "<p>No content found.</p>"
            chapter.content_text = ""

        return chapter
