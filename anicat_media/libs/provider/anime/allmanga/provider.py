import logging
from typing import TYPE_CHECKING, Iterator

from .....core.utils.graphql import execute_graphql_query_with_get_request
from ..base import BaseAnimeProvider
from ..params import AnimeParams, EpisodeStreamsParams, SearchParams
from ..types import Anime, SearchResults, Server
from ..utils.debug import debug_provider
from .constants import (
    ANIME_GQL,
    API_GRAPHQL_ENDPOINT,
    API_GRAPHQL_REFERER,
    EPISODE_GQL,
    SEARCH_GQL,
)
from .mappers import map_to_anime_result, map_to_search_results

if TYPE_CHECKING:
    from .types import AllAnimeEpisode

logger = logging.getLogger(__name__)


class AllManga(BaseAnimeProvider):
    """Anime provider for allmanga.to.

    AllManga.to is a different web frontend that shares the exact same GraphQL
    API backend as allanime.to (api.allanime.day). The only difference is the
    HTTP Referer header. All extractors, mappers and GQL query files are
    therefore re-used from the allanime provider.
    """

    HEADERS = {"Referer": API_GRAPHQL_REFERER}

    @debug_provider
    def search(self, params: SearchParams) -> SearchResults | None:
        response = execute_graphql_query_with_get_request(
            API_GRAPHQL_ENDPOINT,
            self.client,
            SEARCH_GQL,
            variables={
                "search": {
                    "allowAdult": params.allow_nsfw,
                    "allowUnknown": params.allow_unknown,
                    "query": params.query,
                },
                "limit": params.page_limit,
                "page": params.current_page,
                "translationtype": params.translation_type,
                "countryorigin": params.country_of_origin,
            },
        )
        return map_to_search_results(response)

    @debug_provider
    def get(self, params: AnimeParams) -> Anime | None:
        response = execute_graphql_query_with_get_request(
            API_GRAPHQL_ENDPOINT,
            self.client,
            ANIME_GQL,
            variables={"showId": params.id},
        )
        return map_to_anime_result(response)

    @debug_provider
    def episode_streams(self, params: EpisodeStreamsParams) -> Iterator[Server] | None:
        # Import the allanime extractor directly — the source format is identical.
        from ..allanime.extractors import extract_server

        episode_response = execute_graphql_query_with_get_request(
            API_GRAPHQL_ENDPOINT,
            self.client,
            EPISODE_GQL,
            variables={
                "showId": params.anime_id,
                "translationType": params.translation_type,
                "episodeString": params.episode,
            },
        )
        episode: AllAnimeEpisode = episode_response.json()["data"]["episode"]
        for source in episode["sourceUrls"]:
            if server := extract_server(self.client, params.episode, episode, source):
                yield server


if __name__ == "__main__":
    from ..utils.debug import test_anime_provider

    test_anime_provider(AllManga)
