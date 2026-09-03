"""Parser-contract tests for the MangaDex provider."""

import logging
from mangadex import MangaDexProvider


SAMPLE_SEARCH_JSON = {
    "data": [
        {
            "id": "manga-uuid-1",
            "attributes": {
                "title": {"en": "Sousou no Frieren", "ja-ro": "Frieren"},
                "links": {"al": "118586"}
            },
            "relationships": [
                {
                    "type": "cover_art",
                    "attributes": {"fileName": "frieren-cover.jpg"}
                }
            ]
        },
        {
            "id": "manga-uuid-2",
            "attributes": {
                "title": {"en": "Frieren Doujinshi"},
                "links": {}
            },
            "relationships": []
        }
    ]
}

SAMPLE_FEED_DATA = [
    {
        "id": "ch-uuid-1",
        "attributes": {
            "chapter": "1",
            "title": "The End of the Adventure",
            "pages": 50,
            "externalUrl": None
        }
    },
    {
        "id": "ch-uuid-1-dup",
        "attributes": {
            "chapter": "1",
            "title": "The End of the Adventure (Alt Scan)",
            "pages": 48,
            "externalUrl": None
        }
    },
    {
        "id": "ch-uuid-2",
        "attributes": {
            "chapter": "2",
            "title": "Priest's Lie",
            "pages": 45,
            "externalUrl": None
        }
    },
    {
        "id": "ch-uuid-ext",
        "attributes": {
            "chapter": "3",
            "title": "External link",
            "pages": 0,
            "externalUrl": "https://example.com/reader"
        }
    }
]

SAMPLE_AT_HOME_JSON = {
    "baseUrl": "https://cmdxd98sb0x3yprd.mangadex.network",
    "chapter": {
        "hash": "abc123hash",
        "data": ["page1.jpg", "page2.jpg"]
    }
}


def test_parse_search_results_with_anilist_match():
    results = MangaDexProvider._parse_search_results(SAMPLE_SEARCH_JSON, anilist_id=118586)
    assert len(results) == 2
    assert results[0]["id"] == "manga-uuid-1"
    assert results[0]["title"] == "Sousou no Frieren"
    assert results[0]["cover_image"] == "https://uploads.mangadex.org/covers/manga-uuid-1/frieren-cover.jpg.512.jpg"


def test_parse_search_results_empty(caplog):
    with caplog.at_level(logging.WARNING):
        results = MangaDexProvider._parse_search_results({"data": []})
    assert results == []
    assert any("search results" in r.message for r in caplog.records)


def test_parse_feed_deduplicates_and_sorts():
    info = MangaDexProvider._parse_feed(SAMPLE_FEED_DATA, "Frieren", "cover.jpg")
    assert info["title"] == "Frieren"
    # Chapter 3 was external so excluded; chapter 1 has 2 scanlations, picked higher page count (50)
    assert len(info["chapters"]) == 2
    assert info["chapters"][0]["number"] == 1
    assert info["chapters"][0]["url"] == "ch-uuid-1"
    assert info["chapters"][1]["number"] == 2
    assert info["chapters"][1]["url"] == "ch-uuid-2"


def test_parse_at_home_constructs_urls():
    pages = MangaDexProvider._parse_at_home(SAMPLE_AT_HOME_JSON, "ch-uuid-1")
    assert pages is not None
    assert len(pages["thumbnails"]) == 2
    assert pages["thumbnails"][0] == "https://cmdxd98sb0x3yprd.mangadex.network/data/abc123hash/page1.jpg"
    assert pages["thumbnails"][1] == "https://cmdxd98sb0x3yprd.mangadex.network/data/abc123hash/page2.jpg"
