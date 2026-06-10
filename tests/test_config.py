from anicat_media.core.config import AppConfig
from anicat_media.libs.provider.anime.types import ProviderName
from anicat_media.libs.provider.manga.types import MangaProviderName


def test_sanitize_invalid_providers():
    # Construct config dict with invalid provider and fallback values
    config_dict = {
        "general": {
            "provider": "hianime",  # Invalid (removed) provider
            "provider_fallbacks": [
                "gogoanime",
                "hianime",  # Invalid
                "anizone",
                "nonexistent",  # Invalid
            ],
            "manga_provider": "invalid_manga_provider",  # Invalid
        }
    }

    # Should validate successfully because of the custom field validators
    app_config = AppConfig.model_validate(config_dict)

    # Check that provider fallback value was used
    assert app_config.general.provider == ProviderName.ANIZONE

    # Check that invalid fallbacks were removed and valid ones preserved
    assert app_config.general.provider_fallbacks == [
        ProviderName.GOGOANIME,
        ProviderName.ANIZONE,
    ]

    # Check that invalid manga provider fallback was used
    assert app_config.general.manga_provider == MangaProviderName.MANGAKATANA


def test_provider_server_dynamic():
    from anicat_media.libs.provider.anime.types import ProviderServer

    # Should dynamically support arbitrary server names
    server_name = "AniNeko - HD-1 Sort Sub"
    ps = ProviderServer(server_name)
    assert ps == server_name
    assert isinstance(ps, ProviderServer)
    assert ps.value == server_name

    # Validate that AppConfig stream config supports it via Pydantic model validation
    config_dict = {"stream": {"server": "AniNeko - HD-1 Sort Sub"}}
    app_config = AppConfig.model_validate(config_dict)
    assert app_config.stream.server == "AniNeko - HD-1 Sort Sub"
