from dataclasses import dataclass
from typing import List, Optional


@dataclass(frozen=True)
class MangaSearchParams:
    """Parameters for searching manga."""

    query: str
    page: int = 1
    per_page: int = 20
    allow_nsfw: bool = True
    allow_unknown: bool = True


@dataclass(frozen=True)
class MangaParams:
    """Parameters for fetching manga details."""

    id: str
    query: str
