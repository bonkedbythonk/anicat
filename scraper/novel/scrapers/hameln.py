"""Scraper for Hameln (syosetu.org)."""

import re
import urllib.parse
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter


class HamelnScraper(BaseScraper):
    """Scraper for Hameln web novels."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.session.cookies.set("over18", "off", domain=".syosetu.org")

    def can_handle(self, url: str) -> bool:
        netloc = urllib.parse.urlparse(url).netloc.lower()
        return "syosetu.org" in netloc

    def _normalize_base_url(self, url: str) -> str:
        parsed = urllib.parse.urlparse(url)
        match = re.search(r"/novel/(\d+)/?", parsed.path)
        if match:
            nid = match.group(1)
            return f"https://syosetu.org/novel/{nid}/"
        return url

    def get_novel_info(self, url: str) -> Novel:
        base_url = self._normalize_base_url(url)
        html = self.fetch_html(base_url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one("span[itemprop='name']") or soup.select_one("h1")
        title = title_el.get_text(strip=True) if title_el else "Unknown Hameln Novel"

        author_el = soup.select_one("span[itemprop='author']") or soup.select_one("a[href*='/user/']")
        author = author_el.get_text(strip=True) if author_el else "Unknown Author"

        desc_el = soup.select_one("#synopsis") or soup.select_one(".ss")
        description = desc_el.get_text("\n", strip=True) if desc_el else ""

        chapters = []
        current_volume = None
        idx = 0

        rows = soup.select("table tr")
        for tr in rows:
            chapter_td = tr.select_one("td[colspan]")
            if chapter_td and not tr.select_one("a"):
                current_volume = chapter_td.get_text(strip=True)
                continue

            a = tr.select_one("a")
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

        if not chapters:
            body = soup.select_one("#honbun")
            if body:
                chapters.append(Chapter(
                    index=1,
                    title=title,
                    url=base_url,
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

        body_el = soup.select_one("#honbun")
        foreword_el = soup.select_one("#maegaki")
        afterword_el = soup.select_one("#atogaki")

        sections = []
        if foreword_el:
            sections.append(f'<div class="preface">{self.clean_html_body(foreword_el)}</div>')
        if body_el:
            sections.append(f'<div class="chapter-body">{self.clean_html_body(body_el)}</div>')
        else:
            sections.append("<p>No content found.</p>")
        if afterword_el:
            sections.append(f'<div class="afterword">{self.clean_html_body(afterword_el)}</div>')

        chapter.content_html = "\n".join(sections)
        chapter.content_text = soup.get_text()
        return chapter
