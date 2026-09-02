"""RanobeDB API client for searching and retrieving series/book metadata and cover art."""

from typing import List, Optional, Dict, Any
import requests

from .models import SeriesInfo, BookInfo


class RanobeDBClient:
    """REST API client for RanobeDB (https://ranobedb.org)."""

    BASE_URL = "https://ranobedb.org/api/v0"

    def __init__(self, timeout: int = 15):
        self.session = requests.Session()
        self.session.headers.update({
            "User-Agent": "Anicat/5.0 (LightNovel-CrossPoint; +https://github.com/bonkedbythonk/anicat)",
            "Accept": "application/json",
        })
        self.timeout = timeout

    def search_series(self, query: str, limit: int = 20, offset: int = 0) -> List[SeriesInfo]:
        """Search RanobeDB series by title (supports Japanese, Romaji, and English)."""
        url = f"{self.BASE_URL}/series"
        params = {
            "q": query,
            "limit": limit,
            "offset": offset,
        }
        resp = self.session.get(url, params=params, timeout=self.timeout)
        resp.raise_for_status()
        data = resp.json()
        series_list = data.get("series", [])
        return [SeriesInfo.from_dict(item) for item in series_list]

    def get_series(self, series_id: int) -> SeriesInfo:
        """Fetch full details, book/volume lists, and staff for a series ID."""
        url = f"{self.BASE_URL}/series/{series_id}"
        resp = self.session.get(url, timeout=self.timeout)
        resp.raise_for_status()
        data = resp.json()
        series_data = data.get("series", {})
        return SeriesInfo.from_dict(series_data)

    def get_book(self, book_id: int) -> BookInfo:
        """Fetch details for a single book/volume."""
        url = f"{self.BASE_URL}/book/{book_id}"
        resp = self.session.get(url, timeout=self.timeout)
        resp.raise_for_status()
        data = resp.json()
        book_data = data.get("book", {})
        return BookInfo.from_dict(book_data)

    def download_image(self, url: str) -> Optional[bytes]:
        """Download raw image bytes."""
        try:
            resp = self.session.get(url, timeout=self.timeout)
            if resp.status_code == 200:
                return resp.content
        except requests.RequestException:
            pass
        return None
