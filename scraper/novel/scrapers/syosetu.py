"""Scraper for Shousetsuka ni Narou (Syosetu / Novel18)."""

import re
import urllib.parse
from typing import List, Optional
from bs4 import BeautifulSoup

from .base import BaseScraper
from ..models import Novel, Chapter


class SyosetuScraper(BaseScraper):
    """Scraper for Syosetu (ncode.syosetu.com and novel18.syosetu.com)."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.session.cookies.set("over18", "yes", domain=".syosetu.com")

    def can_handle(self, url: str) -> bool:
        netloc = urllib.parse.urlparse(url).netloc.lower()
        return "syosetu.com" in netloc and "syosetu.org" not in netloc

    def _normalize_base_url(self, url: str) -> str:
        """Extract base novel URL like https://ncode.syosetu.com/n2267be/"""
        parsed = urllib.parse.urlparse(url)
        match = re.search(r"/(n[0-9a-z]+)/?", parsed.path)
        if match:
            ncode = match.group(1)
            return f"{parsed.scheme}://{parsed.netloc}/{ncode}/"
        return url

    def get_novel_info(self, url: str) -> Novel:
        base_url = self._normalize_base_url(url)
        first_page_html = self.fetch_html(base_url)
        soup = BeautifulSoup(first_page_html, "html.parser")

        # Novel Title
        title_el = soup.select_one(".novel_title") or soup.select_one(".p-novel__title") or soup.select_one("h1")
        title = title_el.get_text(strip=True) if title_el else "Unknown Syosetu Novel"

        # Author
        author_el = soup.select_one(".novel_writername") or soup.select_one(".p-novel__author")
        author = author_el.get_text(strip=True).replace("作者：", "").strip() if author_el else "Unknown Author"

        # Synopsis
        ex_el = soup.select_one("#novel_ex") or soup.select_one(".p-novel__summary")
        description = ex_el.get_text("\n", strip=True) if ex_el else ""

        # Check if single short story (tanpen)
        is_short = soup.select_one("#novel_honbun") is not None and not soup.select(".novel_sublist2, .p-eplist__sublist, dd.subtitle")
        if is_short:
            chapter = Chapter(
                index=1,
                title=title,
                url=base_url,
                volume_name=None,
            )
            return Novel(
                title=title,
                author=author,
                description=description,
                source_url=base_url,
                chapters=[chapter],
                language="ja",
            )

        # Multi-chapter series: collect all TOC pages
        chapters = []
        current_volume = None

        total_pages = 1
        for link in soup.select("a[href*='?p=']"):
            href = link.get("href", "")
            match = re.search(r"\?p=(\d+)", href)
            if match:
                page_num = int(match.group(1))
                if page_num > total_pages:
                    total_pages = page_num

        def parse_toc_page(page_soup: BeautifulSoup, start_idx: int) -> int:
            nonlocal current_volume
            idx = start_idx
            items = page_soup.select(".index_box > *, .p-eplist > *")
            if not items:
                sublist = page_soup.select(".novel_sublist2, .p-eplist__sublist, dd.subtitle")
                for item in sublist:
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
                return idx

            for item in items:
                if "chapter_title" in item.get("class", []) or "p-eplist__chapter-title" in item.get("class", []):
                    current_volume = item.get_text(strip=True)
                elif "novel_sublist2" in item.get("class", []) or "p-eplist__sublist" in item.get("class", []) or item.name == "dd":
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
            return idx

        curr_idx = parse_toc_page(soup, 0)

        for p in range(2, total_pages + 1):
            page_url = f"{base_url}?p={p}"
            page_html = self.fetch_html(page_url)
            page_soup = BeautifulSoup(page_html, "html.parser")
            curr_idx = parse_toc_page(page_soup, curr_idx)

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

        title_el = soup.select_one(".novel_subtitle") or soup.select_one(".p-novel__title")
        if title_el and not chapter.title:
            chapter.title = title_el.get_text(strip=True)

        foreword_el = soup.select_one("#novel_p") or soup.select_one(".p-novel__text--preface")
        body_el = soup.select_one("#novel_honbun") or soup.select_one(".p-novel__body") or soup.select_one(".p-novel__text")
        afterword_el = soup.select_one("#novel_a") or soup.select_one(".p-novel__text--afterword")

        sections = []
        if foreword_el:
            foreword_cleaned = self.clean_html_body(foreword_el)
            sections.append(f'<div class="preface"><hr class="divider" />{foreword_cleaned}<hr class="divider" /></div>')

        if body_el:
            body_cleaned = self.clean_html_body(body_el)
            sections.append(f'<div class="chapter-body">{body_cleaned}</div>')
        else:
            sections.append('<p>No content extracted.</p>')

        if afterword_el:
            afterword_cleaned = self.clean_html_body(afterword_el)
            sections.append(f'<div class="afterword"><hr class="divider" />{afterword_cleaned}</div>')

        full_html = "\n".join(sections)
        chapter.content_html = full_html
        chapter.content_text = soup.get_text()
        return chapter
