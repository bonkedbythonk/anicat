"""Web novel scrapers module."""

from .base import BaseScraper
from .lnori import LnoriScraper
from .syosetu import SyosetuScraper
from .kakuyomu import KakuyomuScraper
from .hameln import HamelnScraper
from .royalroad import RoyalRoadScraper
from .bakatsuki import BakaTsukiScraper
from .generic import GenericScraper
from .factory import get_scraper_for_url

__all__ = [
    "BaseScraper",
    "LnoriScraper",
    "SyosetuScraper",
    "KakuyomuScraper",
    "HamelnScraper",
    "RoyalRoadScraper",
    "BakaTsukiScraper",
    "GenericScraper",
    "get_scraper_for_url",
]
