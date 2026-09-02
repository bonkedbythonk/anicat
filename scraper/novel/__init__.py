"""Anicat Light Novel Engine with CrossPoint E-Ink EPUB Optimization."""

from .models import Novel, Chapter, SeriesInfo, BookInfo, StaffMember, Publisher, Tag
from .api import RanobeDBClient
from .image_engine import optimize_image_for_eink, split_landscape_double_spread
from .content_cleaner import clean_chapter_html
from .metadata_sanitizer import sanitize_ascii_text, format_crosspoint_filename
from .epub_builder import build_novel_epub
from .scrapers import get_scraper_for_url

__all__ = [
    "Novel",
    "Chapter",
    "SeriesInfo",
    "BookInfo",
    "StaffMember",
    "Publisher",
    "Tag",
    "RanobeDBClient",
    "optimize_image_for_eink",
    "split_landscape_double_spread",
    "clean_chapter_html",
    "sanitize_ascii_text",
    "format_crosspoint_filename",
    "build_novel_epub",
    "get_scraper_for_url",
]
