from dataclasses import dataclass, field
from typing import List, Optional
from enum import Enum


class MangaProviderName(Enum):
    MANGADEX = "mangadex"
    MANGAKATANA = "mangakatana"


@dataclass(frozen=True)
class MangaChapter:
    number: str
    title: Optional[str] = None
    url: Optional[str] = None


@dataclass(frozen=True)
class Manga:
    id: str
    title: str
    chapters: List[MangaChapter] = field(default_factory=list)
    cover_image: Optional[str] = None
    description: Optional[str] = None


@dataclass(frozen=True)
class MangaSearchResult:
    id: str
    title: str
    cover_image: Optional[str] = None


@dataclass(frozen=True)
class MangaSearchResults:
    results: List[MangaSearchResult] = field(default_factory=list)
