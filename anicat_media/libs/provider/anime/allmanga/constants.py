from .....core.constants import GRAPHQL_DIR

# AllManga.to uses the same GraphQL API backend as AllAnime.to (api.allanime.day).
# The only difference is the HTTP Referer header.
API_BASE_URL = "allanime.day"
API_GRAPHQL_REFERER = "https://allmanga.to/"
API_GRAPHQL_ENDPOINT = f"https://api.{API_BASE_URL}/api/"

# Re-use the same GraphQL query files as AllAnime — the API is identical.
_GQL_QUERIES = GRAPHQL_DIR / "allanime" / "queries"
SEARCH_GQL = _GQL_QUERIES / "search.gql"
ANIME_GQL = _GQL_QUERIES / "anime.gql"
EPISODE_GQL = _GQL_QUERIES / "episodes.gql"
