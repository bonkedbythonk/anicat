"""Parser-contract tests for the MangaKatana provider.

These exercise the pure HTML parsers against fixtures shaped like the real
pages. They lock the selector contract (a rename to #book_list .item or
.chapters .chapter a fails here) and assert that an unrecognised page logs a
warn_empty diagnostic instead of silently returning nothing.
"""

import logging

from mangakatana import MangaKatanaProvider

SEARCH_HTML = """
<div id="book_list">
  <div class="item">
    <div class="title"><a href="/manga/naruto.123">Naruto</a></div>
    <img src="https://cdn.mangakatana.com/naruto.jpg" />
  </div>
  <div class="item">
    <div class="title"><a href="https://mangakatana.com/manga/bleach.456">Bleach</a></div>
    <img src="https://cdn.mangakatana.com/bleach.jpg" />
  </div>
</div>
"""

MANGA_PAGE_HTML = """
<h1 class="heading">One Piece</h1>
<div class="cover"><img src="https://cdn.mangakatana.com/op.jpg" /></div>
<div class="chapters">
  <div class="chapter"><a href="/manga/op/c3">Chapter 3: Morgan</a></div>
  <div class="chapter"><a href="/manga/op/c2">Chapter 2: Buggy</a></div>
  <div class="chapter"><a href="/manga/op/c1">Chapter 1: Romance Dawn</a></div>
</div>
"""


def test_parse_search_results_extracts_items():
    results = MangaKatanaProvider._parse_search_results(SEARCH_HTML)
    assert len(results) == 2
    assert results[0]["title"] == "Naruto"
    # Relative hrefs are absolutised, absolute ones are left alone.
    assert results[0]["id"] == "https://mangakatana.com/manga/naruto.123"
    assert results[1]["id"] == "https://mangakatana.com/manga/bleach.456"
    assert results[0]["cover_image"].endswith("naruto.jpg")


def test_parse_search_results_empty_logs_warning(caplog):
    with caplog.at_level(logging.WARNING):
        results = MangaKatanaProvider._parse_search_results("<html><body>nope</body></html>")
    assert results == []
    assert any("#book_list .item" in r.message for r in caplog.records)


def test_parse_manga_page_extracts_chapters_ascending():
    info = MangaKatanaProvider._parse_manga_page(MANGA_PAGE_HTML)
    assert info["title"] == "One Piece"
    assert info["cover_image"].endswith("op.jpg")
    nums = [c["number"] for c in info["chapters"]]
    # Page lists newest-first; parser returns ascending.
    assert nums == [1, 2, 3]
    assert info["chapters"][0]["url"] == "https://mangakatana.com/manga/op/c1"


def test_parse_manga_page_no_chapters_logs_warning(caplog):
    with caplog.at_level(logging.WARNING):
        info = MangaKatanaProvider._parse_manga_page("<h1>Lonely Manga</h1>")
    assert info["chapters"] == []
    assert any(".chapters .chapter a" in r.message for r in caplog.records)
