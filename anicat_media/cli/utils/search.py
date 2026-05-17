"""Search functionality."""

import re
from typing import Union

from anicat_media.core.utils.fuzzy import fuzz
from anicat_media.core.utils.normalizer import normalize_title
from anicat_media.libs.media_api.types import MediaItem
from anicat_media.libs.provider.anime.types import ProviderName, SearchResult
from anicat_media.libs.provider.manga.types import MangaProviderName


def _extract_trailing_season_number(title: str) -> int | None:
    match = re.search(r"(?:\bseason\s*)?(\d+)(?:st|nd|rd|th)?\s*$", title.strip().lower())
    if not match:
        return None

    try:
        return int(match.group(1))
    except ValueError:
        return None


def _normalize_season(value: str | None) -> str:
    if not value:
        return ""
    return value.strip().lower()


def _score_candidate(
    provider_title: str,
    provider_result: SearchResult,
    provider: Union[ProviderName, MangaProviderName],
    media_item: MediaItem,
) -> tuple[int, int, int, int, int]:
    normalized_title = normalize_title(provider_title, provider.value).lower()
    title_score = max(
        fuzz.ratio(normalized_title, (media_item.title.romaji or "").lower()),
        fuzz.ratio(normalized_title, (media_item.title.english or "").lower()),
    )

    season_match = (
        1
        if _normalize_season(provider_result.season)
        == _normalize_season(media_item.season)
        and provider_result.season
        else 0
    )

    year_match = 0
    if media_item.season_year and provider_result.year:
        try:
            year_match = (
                1 if int(provider_result.year) == int(media_item.season_year) else 0
            )
        except (TypeError, ValueError):
            year_match = 0

    media_sequel = _extract_trailing_season_number(
        media_item.title.english or media_item.title.romaji or ""
    )
    provider_sequel = _extract_trailing_season_number(provider_title)
    sequel_match = (
        1 if media_sequel and provider_sequel and media_sequel == provider_sequel else 0
    )

    exact_title_match = 1 if normalized_title in {
        (media_item.title.romaji or "").lower(),
        (media_item.title.english or "").lower(),
    } else 0

    return (sequel_match, season_match, year_match, exact_title_match, title_score)


def find_best_match_title(
    provider_results_map: dict[str, SearchResult],
    provider: Union[ProviderName, MangaProviderName],
    media_item: MediaItem,
) -> str:
    """Find the best match title using fuzzy matching for both the english AND romaji title.

    Parameters:
        provider_results_map (dict[str, SearchResult]): The map of provider results.
        provider (ProviderName): The provider name from the config.
        media_item (MediaItem): The media item to match.

    Returns:
        str: The best match title.
    """
    return max(
        provider_results_map.keys(),
        key=lambda p_title: _score_candidate(
            p_title,
            provider_results_map[p_title],
            provider,
            media_item,
        ),
    )
