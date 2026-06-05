from unittest.mock import patch
from anicat_media.libs.player.mpv.player import MpvPlayer
from anicat_media.libs.player.params import PlayerParams
from anicat_media.core.config.infrastructure import MpvConfig


def test_mpv_player_skip_times_brackets():
    config = MpvConfig(args="", pre_args="")
    player = MpvPlayer(config)

    params = PlayerParams(
        url="https://example.com/anime.m3u8",
        title="Test Anime",
        query="Test Anime",
        episode="1",
        skip_times=[
            {"type": "op", "start": 30, "end": 120},
            {"type": "ed", "start": 1200, "end": 1320},
        ],
    )

    args = player._create_mpv_cli_options(params)

    # Assert that the skip_times option was formatted with bracket quoting
    expected_opt = "--script-opts=anicat_ui-skip_times=[op,30,120;ed,1200,1320]"
    assert expected_opt in args


def test_mpv_player_shader_profile():
    config = MpvConfig(args="", pre_args="")
    player = MpvPlayer(config)

    # Mock os.path.exists to return True so shader path generation runs
    # even when the shaders folder is not present on clean CI hosts.
    with patch("anicat_media.libs.player.mpv.player.os.path.exists", return_value=True):
        # Test balanced (On) - should load S shaders
        params_balanced = PlayerParams(
            url="https://example.com/anime.m3u8",
            title="Test Anime",
            query="Test Anime",
            episode="1",
            shader_profile="balanced",
        )
        args_balanced = player._create_mpv_cli_options(params_balanced)
        assert any("Anime4K_Restore_CNN_S.glsl" in arg for arg in args_balanced)

        # Test off (No shaders)
        params_off = PlayerParams(
            url="https://example.com/anime.m3u8",
            title="Test Anime",
            query="Test Anime",
            episode="1",
            shader_profile="off",
        )
        args_off = player._create_mpv_cli_options(params_off)
        assert not any("--glsl-shaders" in arg for arg in args_off)

