"""Scraper for Baka-Tsuki (baka-tsuki.org)."""

import re
import urllib.parse
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter


class BakaTsukiScraper(BaseScraper):
    """Scraper for Baka-Tsuki wiki light novels."""

    def can_handle(self, url: str) -> bool:
        netloc = urllib.parse.urlparse(url).netloc.lower()
        return "baka-tsuki.org" in netloc

    def get_novel_info(self, url: str) -> Novel:
        html = self.fetch_html(url)
        soup = BeautifulSoup(html, "html.parser")

        title_el = soup.select_one("#firstHeading")
        title = title_el.get_text(strip=True) if title_el else "Baka-Tsuki Novel"

        # Look for author
        author = "Unknown Author"
        for li in soup.select("li"):
            txt = li.get_text(strip=True)
            if "Author:" in txt or "Author :" in txt or "Written by:" in txt:
                author = txt.split(":")[-1].strip()
                break

        desc_el = soup.select_one("#Story_Synopsis ~ p, #Synopsis ~ p, .mw-parser-output > p")
        description = desc_el.get_text("\n", strip=True) if desc_el else ""

        cover_img = soup.select_one(".thumbimage, img[src*='upload']")
        cover_url = urllib.parse.urljoin(url, cover_img.get("src")) if cover_img else None

        chapters = []
        current_volume = None
        idx = 0

        content_div = soup.select_one("#mw-content-text") or soup
        for el in content_div.find_all(["h2", "h3", "h4", "ul", "ol"]):
            if el.name in ["h2", "h3", "h4"]:
                headline = el.select_one(".mw-headline")
                if headline:
                    current_volume = headline.get_text(strip=True)
            elif el.name in ["ul", "ol"]:
                for a in el.select("a[href*='title=']"):
                    href = urllib.parse.urljoin(url, a.get("href", ""))
                    ch_title = a.get_text(strip=True)
                    if ch_title and not ch_title.startswith("File:") and not ch_title.startswith("Special:"):
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
            source_url=url,
            cover_image_url=cover_url,
            chapters=chapters,
            language="en",
        )

    def fetch_chapter_content(self, chapter: Chapter) -> Chapter:
        html = self.fetch_html(chapter.url)
        soup = BeautifulSoup(html, "html.parser")

        content = soup.select_one("#mw-content-text .mw-parser-output") or soup.select_one("#mw-content-text")
        if content:
            cleaned = self.clean_html_body(content)
            chapter.content_html = f'<div class="chapter-body">{cleaned}</div>'
            chapter.content_text = content.get_text()
        else:
            chapter.content_html = "<p>No content found.</p>"
            chapter.content_text = ""

        return chapter
