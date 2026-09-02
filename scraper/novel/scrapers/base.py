"""Abstract base class and utilities for web novel scrapers."""

from abc import ABC, abstractmethod
import time
import copy
import requests
from bs4 import BeautifulSoup

from ..models import Novel, Chapter


class BaseScraper(ABC):
    """Abstract base class for all novel source scrapers."""

    def __init__(self, timeout: int = 20, delay_between_requests: float = 0.2):
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            "Accept-Language": "ja,en-US;q=0.9,en;q=0.8",
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        })
        self.timeout = timeout
        self.delay_between_requests = delay_between_requests

    @abstractmethod
    def can_handle(self, url: str) -> bool:
        """Return True if this scraper can handle the given URL."""
        pass

    @abstractmethod
    def get_novel_info(self, url: str) -> Novel:
        """Fetch novel overview (title, author, synopsis, and list of chapters)."""
        pass

    @abstractmethod
    def fetch_chapter_content(self, chapter: Chapter) -> Chapter:
        """Fetch and populate chapter.content_html and chapter.content_text."""
        pass

    def fetch_html(self, url: str, retries: int = 3) -> str:
        """Fetch HTML content from a URL with retries and delay."""
        last_error = None
        for attempt in range(retries):
            try:
                if self.delay_between_requests > 0:
                    time.sleep(self.delay_between_requests)
                resp = self.session.get(url, timeout=self.timeout)
                resp.raise_for_status()
                # Ensure correct encoding (detect utf-8 / euc-jp / shift-jis if needed)
                if resp.encoding is None or resp.encoding.lower() == "iso-8859-1":
                    resp.encoding = resp.apparent_encoding or "utf-8"
                return resp.text
            except requests.RequestException as e:
                last_error = e
                time.sleep(1.0 * (attempt + 1))
        raise RuntimeError(f"Failed to fetch {url} after {retries} attempts: {last_error}")

    def clean_html_body(self, soup_element) -> str:
        """Clean and format soup element into clean HTML for EPUB."""
        if not soup_element:
            return "<p></p>"

        el = copy.copy(soup_element)
        for tag in el.find_all(["script", "style", "iframe", "button", "input", "form", "svg"]):
            tag.decompose()

        inner_html = "".join(str(c) for c in el.children)
        return f"<div>{inner_html}</div>"
