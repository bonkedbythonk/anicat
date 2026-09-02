"""Factory for instantiating the appropriate scraper for a given URL."""

from typing import List, Type
from .base import BaseScraper
from .lnori import LnoriScraper
from .syosetu import SyosetuScraper
from .kakuyomu import KakuyomuScraper
from .hameln import HamelnScraper
from .royalroad import RoyalRoadScraper
from .bakatsuki import BakaTsukiScraper
from .generic import GenericScraper

ALL_SCRAPERS: List[Type[BaseScraper]] = [
    LnoriScraper,
    SyosetuScraper,
    KakuyomuScraper,
    HamelnScraper,
    RoyalRoadScraper,
    BakaTsukiScraper,
    GenericScraper,
]


def get_scraper_for_url(url: str, **kwargs) -> BaseScraper:
    """Return an initialized scraper capable of handling the provided URL."""
    for scraper_cls in ALL_SCRAPERS:
        try:
            instance = scraper_cls(**kwargs)
            if instance.can_handle(url):
                return instance
        except Exception:
            continue
    return GenericScraper(**kwargs)
