"""Parser-contract tests for the Mkissa provider (GraphQL JSON)."""

import logging

from mkissa import MkissaProvider

SEARCH_RESPONSE = {
    "data": {
        "shows": {
            "edges": [
                {"_id": "abc123", "englishName": "Spy x Family", "name": "Spy x Family"},
                {"_id": "def456", "englishName": "", "name": "Kimetsu no Yaiba"},
                {"_id": "ghi789", "englishName": "No Title Here"},  # kept: has id + name fallback fails -> title from englishName
                {"englishName": "Missing Id"},  # skipped: no _id
            ]
        }
    }
}


def test_extract_search_results():
    results = MkissaProvider._extract_search_results(SEARCH_RESPONSE)
    ids = [r.id for r in results]
    # englishName preferred, name used when englishName is empty, entry without _id dropped.
    assert "abc123" in ids
    assert "def456" in ids
    assert "ghi789" in ids
    assert len(results) == 3
    by_id = {r.id: r.title for r in results}
    assert by_id["abc123"] == "Spy x Family"
    assert by_id["def456"] == "Kimetsu no Yaiba"


def test_extract_search_results_empty_logs_warning(caplog):
    with caplog.at_level(logging.WARNING):
        results = MkissaProvider._extract_search_results({"data": {"shows": {"edges": []}}})
    assert results == []
    assert any("data.shows.edges" in r.message for r in caplog.records)


def test_extract_search_results_malformed_payload_warns(caplog):
    with caplog.at_level(logging.WARNING):
        results = MkissaProvider._extract_search_results({})
    assert results == []
    assert any("data.shows.edges" in r.message for r in caplog.records)
