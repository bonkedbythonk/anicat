"""
MPV player integration for Anicat.

This module provides the MpvPlayer class, which implements the BasePlayer interface for the MPV media player.
"""

import logging
import os
import re
import shutil
import subprocess
import sys
from ....utils.subprocess import run_cmd

from ....core.config import MpvConfig
from ....core.exceptions import AnicatError
from ....core.patterns import TORRENT_REGEX, YOUTUBE_REGEX
from ....core.utils import detect
from ..base import BasePlayer
from ..params import PlayerParams
from ..types import PlayerResult

logger = logging.getLogger(__name__)

MPV_AV_TIME_PATTERN = re.compile(r"AV: ([0-9:]*) / ([0-9:]*) \(([0-9]*)%\)")


class MpvPlayer(BasePlayer):
    """
    MPV player implementation for Anicat.

    Provides playback functionality using the MPV media player, supporting desktop, mobile, torrents, and syncplay.
    """

    def __init__(self, config: MpvConfig):
        """
        Initialize the MpvPlayer with the given MPV configuration.

        Args:
            config: MpvConfig object containing MPV-specific settings.
        """
        self.config = config
        self.executable = None

        # 1. Prioritize native system-wide MPV for maximum operating system compatibility
        self.executable = shutil.which("mpv")
        
        # macOS specific: check common native package installation directories
        if not self.executable and sys.platform == "darwin":
            common_paths = [
                "/opt/homebrew/bin/mpv",
                "/usr/local/bin/mpv",
                "/Applications/mpv.app/Contents/MacOS/mpv",
                os.path.expanduser("~/Applications/mpv.app/Contents/MacOS/mpv")
            ]
            for path in common_paths:
                if os.path.exists(path):
                    self.executable = path
                    logger.info(f"Native system-wide MPV discovered at: {self.executable}")
                    break

        # 2. Fall back to bundled MPV inside the app resources if not installed on system
        if not self.executable and sys.platform == "darwin":
            # For packaged Tauri apps, sys.executable is Anicat.app/Contents/MacOS/anicat-server
            app_dir = os.path.dirname(sys.executable)
            bundled_paths = [
                # Inside Tauri v2 resources folder
                os.path.abspath(os.path.join(app_dir, "..", "Resources", "resources", "mpv")),
                # Directly in Resources folder
                os.path.abspath(os.path.join(app_dir, "..", "Resources", "mpv")),
                # Development fallback inside repository workspace
                os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "..", "web", "src-tauri", "resources", "mpv")),
            ]
            for path in bundled_paths:
                if os.path.exists(path):
                    self.executable = path
                    logger.info(f"Bundled MPV fallback discovered inside app resources at: {self.executable}")
                    break
        
        if self.executable:
            logger.info(f"MPV executable discovered at: {self.executable}")
        else:
            logger.warning("MPV executable NOT FOUND in standard locations.")

    def play(self, params):
        """
        Play the given media using MPV, handling desktop, mobile, torrent, and syncplay scenarios.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            PlayerResult: Information about the playback session.
        """
        if TORRENT_REGEX.match(params.url) and detect.is_running_in_termux():
            raise AnicatError("Unable to play torrents on termux")
        elif params.syncplay and detect.is_running_in_termux():
            raise AnicatError("Unable to play with syncplay on termux")
        elif detect.is_running_in_termux():
            return self._play_on_mobile(params)
        else:
            return self._play_on_desktop(params)

    def _play_on_mobile(self, params) -> PlayerResult:
        """
        Play media on a mobile device using Android intents.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            PlayerResult: Information about the playback session.
        """
        if YOUTUBE_REGEX.match(params.url):
            args = [
                "nohup",
                "am",
                "start",
                "--user",
                "0",
                "-a",
                "android.intent.action.VIEW",
                "-d",
                params.url,
                "-n",
                "com.google.android.youtube/.UrlActivity",
            ]
        else:
            args = [
                "nohup",
                "am",
                "start",
                "--user",
                "0",
                "-a",
                "android.intent.action.VIEW",
                "-d",
                params.url,
                "-n",
                "is.xyz.mpv/.MPVActivity",
            ]

        # Use `run_cmd` to enforce timeouts and avoid uncaught exceptions
        run_cmd(args, timeout=10, capture_output=False, env=detect.get_clean_env())

        return PlayerResult(params.episode)

    def _play_on_desktop(self, params) -> PlayerResult:
        """
        Play media on a desktop environment using MPV.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            PlayerResult: Information about the playback session.
        """
        if not self.executable:
            raise AnicatError("MPV executable not found in PATH.")

        if TORRENT_REGEX.search(params.url):
            return self._stream_on_desktop_with_webtorrent_cli(params)
        elif params.syncplay:
            return self._stream_on_desktop_with_syncplay(params)
        else:
            return self._stream_on_desktop_with_subprocess(params)

    def _stream_on_desktop_with_subprocess(self, params: PlayerParams) -> PlayerResult:
        """
        Stream media using MPV via subprocess, capturing playback times.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            PlayerResult: Information about the playback session, including stop and total time.
        """
        mpv_args = [self.executable, params.url]

        mpv_args.extend(self._create_mpv_cli_options(params))

        pre_args = self.config.pre_args.split(",") if self.config.pre_args else []

        stop_time = None
        total_time = None

        rc, out, err = run_cmd(
            pre_args + mpv_args,
            timeout=600,
            capture_output=True,
            env=detect.get_clean_env(),
        )
        if out:
            for line in reversed(out.split("\n")):
                match = MPV_AV_TIME_PATTERN.search(line.strip())
                if match:
                    stop_time = match.group(1)
                    total_time = match.group(2)
                    break
        return PlayerResult(
            episode=params.episode, total_time=total_time, stop_time=stop_time
        )

    def play_with_ipc(self, params: PlayerParams, socket_path: str) -> subprocess.Popen:
        """
        Stream using MPV with IPC (Inter-Process Communication) for enhanced features.

        Args:
            params: PlayerParams object containing playback parameters.
            socket_path: Path to the IPC socket for player control.

        Returns:
            subprocess.Popen: The running MPV process.
        """
        if not self.executable:
            raise AnicatError("MPV executable not found in PATH. Please install MPV to use the dashboard.")

        mpv_args = [
            self.executable,
            f"--input-ipc-server={socket_path}",
            "--idle=yes",
            "--force-window=yes",
            params.url,
        ]

        # Add custom MPV arguments
        mpv_args.extend(self._create_mpv_cli_options(params))

        # Add pre-args if configured
        pre_args = self.config.pre_args.split(",") if self.config.pre_args else []

        # Set up a dedicated debug log file for MPV output
        log_dir = os.path.expanduser("~/Library/Caches/anicat/logs")
        if sys.platform != "darwin":
            log_dir = os.path.expanduser("~/.cache/anicat/logs")
        
        try:
            os.makedirs(log_dir, exist_ok=True)
            mpv_log_path = os.path.join(log_dir, "mpv.log")
            mpv_log_file = open(mpv_log_path, "w", encoding="utf-8")
            logger.info(f"Redirecting MPV process stdout/stderr to: {mpv_log_path}")
        except Exception as e:
            logger.warning(f"Could not create MPV log file: {e}. Falling back to DEVNULL.")
            mpv_log_file = subprocess.DEVNULL

        full_cmd = pre_args + mpv_args
        logger.info(f"Starting MPV with IPC socket: {socket_path}")
        logger.info(f"MPV Command: {' '.join(full_cmd)}")
        logger.info(f"MPV Environment (clean): {detect.get_clean_env()}")

        try:
            process = subprocess.Popen(
                full_cmd,
                env=detect.get_clean_env(),
                stdout=mpv_log_file,
                stderr=mpv_log_file,
            )
        except Exception as e:
            logger.error(f"Failed to spawn MPV process: {e}", exc_info=True)
            raise AnicatError(f"Failed to spawn MPV player process: {e}")

        return process

    def _stream_on_desktop_with_webtorrent_cli(
        self, params: PlayerParams
    ) -> PlayerResult:
        """
        Stream torrent media using the webtorrent CLI and MPV.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            PlayerResult: Information about the playback session.
        """
        WEBTORRENT_CLI = shutil.which("webtorrent")
        if not WEBTORRENT_CLI:
            raise AnicatError("Please Install webtorrent cli inorder to stream torrents")

        args = [WEBTORRENT_CLI, params.url, "--mpv"]
        if mpv_args := self._create_mpv_cli_options(params):
            args.append("--player-args")
            args.extend(mpv_args)

        run_cmd(args, timeout=300, capture_output=False, env=detect.get_clean_env())
        return PlayerResult(params.episode)

    def _stream_on_desktop_with_syncplay(self, params: PlayerParams) -> PlayerResult:
        """
        Stream media using Syncplay for synchronized playback with friends.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            PlayerResult: Information about the playback session.
        """
        SYNCPLAY_EXECUTABLE = shutil.which("syncplay")
        if not SYNCPLAY_EXECUTABLE:
            raise AnicatError(
                "Please install syncplay to be able to stream with your friends"
            )
        args = [SYNCPLAY_EXECUTABLE, params.url]
        if mpv_args := self._create_mpv_cli_options(params):
            args.append("--")
            args.extend(mpv_args)
        run_cmd(args, timeout=300, capture_output=False, env=detect.get_clean_env())

        return PlayerResult(params.episode)

    def _create_mpv_cli_options(self, params: PlayerParams) -> list[str]:
        """
        Create a list of MPV CLI options based on playback parameters.

        Args:
            params: PlayerParams object containing playback parameters.

        Returns:
            list[str]: List of MPV CLI arguments.
        """
        # Locate the bundled configuration directory inside the application bundle resources
        bundled_config = None
        if sys.platform == "darwin":
            # For packaged Tauri apps, the sidecar is at Anicat.app/Contents/MacOS/anicat-server
            # The Resources folder is at Anicat.app/Contents/Resources
            app_dir = os.path.dirname(sys.executable)
            config_search_paths = [
                os.path.abspath(os.path.join(app_dir, "..", "Resources", "resources", "mpv_config")),
                os.path.abspath(os.path.join(app_dir, "..", "Resources", "mpv_config")),
                os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "..", "web", "src-tauri", "resources", "mpv_config")),
            ]
            for path in config_search_paths:
                if os.path.exists(path):
                    bundled_config = path
                    break
        else:
            # Non-macOS fallback inside workspace
            fallback_path = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "..", "..", "..", "web", "src-tauri", "resources", "mpv_config"))
            if os.path.exists(fallback_path):
                bundled_config = fallback_path

        # If a bundled config directory is found, dynamically load uosc skin and Anime4K shaders
        if bundled_config:
            mpv_args.append(f"--config-dir={bundled_config}")
            logger.info(f"Using isolated premium bundled MPV configuration from: {bundled_config}")

            # Dynamically map and inject real-time upscaling shaders based on user's performance preference
            shader_profile = getattr(params, "shader_profile", "balanced") or "balanced"
            if shader_profile != "off":
                bundled_shaders_dir = os.path.join(bundled_config, "shaders")
                if os.path.exists(bundled_shaders_dir):
                    if shader_profile == "balanced":
                        # Energy-efficient upscaling for MacBook Air & maximum battery life
                        shader_path = os.path.join(bundled_shaders_dir, "Anime4K_Upscale_CNN_x2_M.glsl")
                        if os.path.exists(shader_path):
                            mpv_args.append(f"--glsl-shaders={shader_path}")
                            logger.info("Using balanced energy-efficient Anime4K upscaling shaders (Tier M).")
                    elif shader_profile == "high":
                        # Premium upscaling and clean line restoration for MacBook Pro
                        upscale_path = os.path.join(bundled_shaders_dir, "Anime4K_Upscale_CNN_x2_H.glsl")
                        restore_path = os.path.join(bundled_shaders_dir, "Anime4K_Auto_Restore_VL.glsl")
                        shaders_to_load = []
                        if os.path.exists(upscale_path):
                            shaders_to_load.append(upscale_path)
                        if os.path.exists(restore_path):
                            shaders_to_load.append(restore_path)
                        if shaders_to_load:
                            mpv_args.append(f"--glsl-shaders={':'.join(shaders_to_load)}")
                            logger.info("Using high-performance Anime4K upscaling and line restoration shaders (Tier H).")
                    elif shader_profile == "ultra":
                        # Ultra multi-pass upscaling and clean line recovery for High-End GPUs
                        upscale_path = os.path.join(bundled_shaders_dir, "Anime4K_Upscale_CNN_x2_UL.glsl")
                        restore_path = os.path.join(bundled_shaders_dir, "Anime4K_Restore_CNN_UL.glsl")
                        shaders_to_load = []
                        if os.path.exists(upscale_path):
                            shaders_to_load.append(upscale_path)
                        if os.path.exists(restore_path):
                            shaders_to_load.append(restore_path)
                        if shaders_to_load:
                            mpv_args.append(f"--glsl-shaders={':'.join(shaders_to_load)}")
                            logger.info("Using ultra-high fidelity multi-pass Anime4K shaders (Tier UL).")
            else:
                logger.info("GPU upscaling shaders are disabled (Battery Saver / Low-End profile).")

        if params.headers:
            # mpv prefers no spaces after commas and colons in http-header-fields
            headers_list = []
            for k, v in params.headers.items():
                # Clean value of newlines and extra spaces
                clean_v = v.strip().replace("\n", "").replace("\r", "")
                headers_list.append(f"{k}:{clean_v}")
            
            header_str = ",".join(headers_list)
            mpv_args.append(f"--http-header-fields={header_str}")

        if params.subtitles:
            for sub in params.subtitles:
                mpv_args.append(f"--sub-file={sub}")

        if params.start_time:
            mpv_args.append(f"--start={params.start_time}")

        if params.title:
            mpv_args.append(f"--title={params.title}")

        if self.config.args:
            mpv_args.extend(self.config.args.split(","))
        return mpv_args


if __name__ == "__main__":
    from ....core.constants import APP_ASCII_ART

    print(APP_ASCII_ART)
    url = input("Enter the url you would like to stream: ")
    mpv = MpvPlayer(MpvConfig())
    player_result = mpv.play(PlayerParams(episode="", query="", url=url, title=""))
    print(player_result)
