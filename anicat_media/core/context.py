import logging
from dataclasses import dataclass
from typing import Any, Optional

from anicat_media.core.config import AppConfig

logger = logging.getLogger(__name__)


@dataclass
class Context:
    config: AppConfig
    _provider: Optional[Any] = None
    _manga_provider: Optional[Any] = None
    _media_api: Optional[Any] = None
    _download: Optional[Any] = None
    _player: Optional[Any] = None
    _media_registry: Optional[Any] = None
    _watch_history: Optional[Any] = None
    _session: Optional[Any] = None
    _auth: Optional[Any] = None
    _updater: Optional[Any] = None

    is_offline: bool = False
    data_version: int = 0

    def __post_init__(self):
        import threading
        self._provider_lock = threading.Lock()
        self._manga_provider_lock = threading.Lock()

    @property
    def manga_provider(self) -> Any:
        if self._manga_provider is not None:
            return self._manga_provider

        with self._manga_provider_lock:
            if self._manga_provider is not None:
                return self._manga_provider

            from anicat_media.libs.provider.manga.provider import create_manga_provider
            self._manga_provider = create_manga_provider(
                self.config.general.manga_provider
            )
        return self._manga_provider

    @property
    def provider(self) -> Any:
        if self._provider is not None:
            return self._provider

        with self._provider_lock:
            if self._provider is not None:
                return self._provider

            from anicat_media.libs.provider.anime.fallback import FallbackAnimeProvider
            from anicat_media.libs.provider.anime.provider import create_provider

            primary = create_provider(self.config.general.provider)
            fallback_names = self.config.general.provider_fallbacks

            if fallback_names:
                fallback_providers = []
                seen = {self.config.general.provider}
                for name in fallback_names:
                    if name not in seen:
                        try:
                            fallback_providers.append(create_provider(name))
                            seen.add(name)
                        except Exception as e:
                            logger.warning(
                                f"Failed to load fallback provider '{name.value}': {e}"
                            )
                if fallback_providers:
                    self._provider = FallbackAnimeProvider([primary] + fallback_providers)
                else:
                    self._provider = primary
            else:
                self._provider = primary

        return self._provider

    @property
    def media_api(self) -> Any:
        if not self._media_api:
            import httpx

            from anicat_media.libs.media_api.api import create_api_client

            media_api = create_api_client(self.config.general.media_api, self.config)

            token = self.config.anilist.token
            if token:
                try:
                    p = media_api.authenticate(token)
                    if p:
                        logger.debug(f"Authenticated as {p.name}")
                except httpx.RequestError as e:
                    logger.warning(f"It seems you are offline: {e}")
                    self.is_offline = True
                except httpx.HTTPStatusError as e:
                    status_code = (
                        e.response.status_code if e.response is not None else 0
                    )
                    if status_code >= 500:
                        self.is_offline = True
            self._media_api = media_api

        return self._media_api

    @property
    def download(self) -> Any:
        if not self._download:
            from anicat_media.core.service.download.service import DownloadService

            self._download = DownloadService(
                self.config, self.media_registry, self.media_api, self.provider
            )
        return self._download

    @property
    def player(self) -> Any:
        if not self._player:
            from anicat_media.core.service.player import PlayerService

            self._player = PlayerService(
                self.config, self.provider, self.media_registry
            )
        return self._player

    @property
    def media_registry(self) -> Any:
        if not self._media_registry:
            from anicat_media.core.service.registry.service import MediaRegistryService

            self._media_registry = MediaRegistryService(
                self.config.general.media_api, self.config.media_registry
            )
        return self._media_registry

    @property
    def watch_history(self) -> Any:
        if not self._watch_history:
            from anicat_media.core.service.watch_history.service import (
                WatchHistoryService,
            )

            self._watch_history = WatchHistoryService(
                self.config, self.media_registry, self.media_api
            )
        return self._watch_history

    @property
    def session(self) -> Any:
        if not self._session:
            from anicat_media.core.service.session.service import SessionsService

            self._session = SessionsService(self.config.sessions)
        return self._session

    @property
    def auth(self) -> Any:
        if not self._auth:
            from anicat_media.core.service.auth.service import AuthService

            self._auth = AuthService(self.config.general.media_api)
        return self._auth

    @property
    def updater(self) -> Any:
        if not self._updater:
            from anicat_media.core.service.updater.service import (
                UpdaterService,
            )

            self._updater = UpdaterService(self.config)
        return self._updater
