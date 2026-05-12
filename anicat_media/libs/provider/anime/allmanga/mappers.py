# Re-export AllAnime mappers unchanged — the AllManga API response format is identical.
from ..allanime.mappers import map_to_anime_result, map_to_search_results

__all__ = ["map_to_anime_result", "map_to_search_results"]
