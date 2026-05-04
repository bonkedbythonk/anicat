import hashlib
import json
import logging
import time
from pathlib import Path
from typing import TYPE_CHECKING, Optional

from httpx import Client, Response

from ..constants import APP_CACHE_DIR
from .networking import TIMEOUT

if TYPE_CHECKING:
    from httpx import Client

logger = logging.getLogger(__name__)

GRAPHQL_CACHE_DIR = APP_CACHE_DIR / "network" / "graphql"


class GraphQLCache:
    """A simple file-based cache for GraphQL responses."""

    def __init__(self, cache_dir: Path = GRAPHQL_CACHE_DIR):
        self.cache_dir = cache_dir
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def _get_cache_key(self, url: str, query: str, variables: dict) -> str:
        """Generate a unique key for the request."""
        key_data = f"{url}:{query}:{json.dumps(variables, sort_keys=True)}"
        return hashlib.sha256(key_data.encode()).hexdigest()

    def get(self, url: str, query: str, variables: dict, ttl: int) -> Optional[dict]:
        """Retrieve a cached response if it exists and is not expired."""
        key = self._get_cache_key(url, query, variables)
        cache_file = self.cache_dir / f"{key}.json"

        if not cache_file.exists():
            return None

        try:
            with cache_file.open("r", encoding="utf-8") as f:
                data = json.load(f)

            cached_at = data.get("cached_at", 0)
            if time.time() - cached_at > ttl:
                return None

            return data.get("response")
        except Exception as e:
            logger.debug(f"Failed to read cache file {cache_file}: {e}")
            return None

    def set(self, url: str, query: str, variables: dict, response_data: dict):
        """Store a response in the cache."""
        key = self._get_cache_key(url, query, variables)
        cache_file = self.cache_dir / f"{key}.json"

        try:
            data = {
                "cached_at": time.time(),
                "response": response_data,
                "url": url,
                "variables": variables,
            }
            with cache_file.open("w", encoding="utf-8") as f:
                json.dump(data, f)
        except Exception as e:
            logger.warning(f"Failed to write cache file {cache_file}: {e}")

    def invalidate(self, url: str, query: str, variables: dict):
        """Manually invalidate a cache entry."""
        key = self._get_cache_key(url, query, variables)
        cache_file = self.cache_dir / f"{key}.json"
        if cache_file.exists():
            try:
                cache_file.unlink()
                logger.debug(f"Invalidated cache for {key}")
            except Exception as e:
                logger.warning(f"Failed to invalidate cache file {cache_file}: {e}")


_cache = GraphQLCache()


def load_graphql_from_file(file: Path) -> str:
    """
    Reads and returns the content of a .gql file.

    Args:
        file: The Path object pointing to the .gql file.

    Returns:
        The string content of the file.
    """
    try:
        return file.read_text(encoding="utf-8")
    except FileNotFoundError:
        logger.error(f"GraphQL file not found at: {file}")
        raise


def execute_graphql_query_with_get_request(
    url: str, httpx_client: Client, graphql_file: Path, variables: dict
) -> Response:
    query = load_graphql_from_file(graphql_file)
    params = {"query": query, "variables": json.dumps(variables)}
    response = httpx_client.get(url, params=params, timeout=TIMEOUT)
    return response


def execute_graphql(
    url: str,
    httpx_client: Client,
    graphql_file: Path,
    variables: dict,
    headers: dict | None = None,
    use_cache: bool = False,
    ttl: int = 3600,
    force_refresh: bool = False,
) -> Response:
    query = load_graphql_from_file(graphql_file)

    if use_cache and not force_refresh:
        cached_data = _cache.get(url, query, variables, ttl)
        if cached_data:
            logger.debug(f"Returning cached response for {graphql_file.name}")
            return Response(
                status_code=200,
                content=json.dumps(cached_data).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )

    json_body = {"query": query, "variables": variables}
    response = httpx_client.post(url, json=json_body, headers=headers, timeout=TIMEOUT)

    if use_cache and response.status_code == 200:
        try:
            _cache.set(url, query, variables, response.json())
        except Exception as e:
            logger.warning(f"Failed to cache response: {e}")

    return response


def invalidate_graphql_cache(url: str, graphql_file: Path, variables: dict):
    """Utility to invalidate a specific cache entry from outside."""
    query = load_graphql_from_file(graphql_file)
    _cache.invalidate(url, query, variables)
