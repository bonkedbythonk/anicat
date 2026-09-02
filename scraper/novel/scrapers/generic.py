"""Generic web novel scraper fallback for blogs, WordPress, and standard readers."""

import re
import urllib.parse
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter


class GenericScraper(BaseScraper):
    """Fallback scraper for blogs, WordPress novel translations, and custom web readers."""

    def can_handle(self, url: str) -> bool:
        return True  # Fallback handles any valid HTTP URL

    def get_novel_info(self, url: str) -> Novel:
        html = self.fetch_html(url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one("h1, .entry-title, .post-title, title")
        title = title_el.get_text(strip=True) if title_el else "Web Novel"
        if " - " in title:
            title = title.split(" - ")[0]

        author_el = soup.select_one(".author, .byline, [rel='author']")
        author = author_el.get_text(strip=True) if author_el else "Unknown Author"

        desc_el = soup.select_one(".entry-content p, .description, meta[name='description']")
        description = desc_el.get("content", "") if desc_el and desc_el.name == "meta" else (desc_el.get_text(strip=True) if desc_el else "")

        # Look for chapter links
        chapters = []
        seen_urls = set()
        idx = 0

        for a in soup.select("a[href]"):
            href = a.get("href", "")
            full_href = urllib.parse.urljoin(url, href)
            txt = a.get_text(strip=True)
            if re.search(r"(chapter|episode|part|prologue|epilogue|act|vol|volume)\s*\d*", txt, re.IGNORECASE):
                if full_href not in seen_urls and full_href != url:
                    seen_urls.add(full_href)
                    idx += 1
                    chapters.append(Chapter(
                        index=idx,
                        title=txt,
                        url=full_href,
                    ))

        if not chapters:
            chapters.append(Chapter(
                index=1,
                title=title,
                url=url,
            ))

        return Novel(
            title=title,
            author=author,
            description=description,
            source_url=url,
            chapters=chapters,
            language="en",
        )

    def fetch_chapter_content(self, chapter: Chapter) -> Chapter:
        html = self.fetch_html(chapter.url)
        soup = BeautifulSoup(html, "html.parser")

        content_el = soup.select_one(".entry-content, .post-content, #content, article, main")
        if not content_el:
            content_el = soup.select_one("body")

        if content_el:
            cleaned = self.clean_html_body(content_el)
            chapter.content_html = f'<div class="chapter-body">{cleaned}</div>'
            chapter.content_text = content_el.get_text()
        else:
            chapter.content_html = "<p>No content found.</p>"
            chapter.content_text = ""

        return chapter
