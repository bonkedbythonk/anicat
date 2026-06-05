"""Type definitions for AniNeko (GogoAnime successor) provider responses."""

from typing import TypedDict


class AniNekoSearchResult(TypedDict, total=False):
    id: str
    title: str
    poster: str | None
    type: str | None
    sub_count: int
    dub_count: int
    genres: list[str]


class AniNekoAnimeDetail(TypedDict, total=False):
    id: str
    title: str
    type: str | None
    status: str | None
    year: str | None
    episodes: list[str]
    poster: str | None
    has_sub: bool
    has_dub: bool


class AniNekoEpisodeServer(TypedDict, total=False):
    name: str
    embed_url: str
    subtitle_type: str
