from abc import ABC, abstractmethod
from typing import TYPE_CHECKING, ClassVar, Dict, Optional

from .params import MangaParams, MangaSearchParams

if TYPE_CHECKING:
    from httpx import Client
    from .types import Manga, MangaSearchResults


class BaseMangaProvider(ABC):
    HEADERS: ClassVar[Dict[str, str]] = {}

    def __init__(self, client: "Client") -> None:
        self.client = client

    @abstractmethod
    def search(self, params: MangaSearchParams) -> "MangaSearchResults | None":
        pass

    @abstractmethod
    def get(self, params: MangaParams) -> "Manga | None":
        pass

    @abstractmethod
    def get_chapter_thumbnails(self, manga_id: str, chapter: str) -> Optional[dict]:
        pass
