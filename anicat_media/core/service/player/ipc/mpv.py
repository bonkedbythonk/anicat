"""
IPC-based MPV Player implementation for Anicat.
This provides advanced features like episode navigation, quality switching, and auto-next.
"""

import json
import logging
import os
import signal
import socket
import sys
import subprocess
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from queue import Empty, Queue
from typing import Any, Callable, Dict, List, Literal, Optional

from .....core.config.model import StreamConfig
from .....core.exceptions import AnicatError
from .....core.utils import formatter
from .....libs.media_api.types import MediaItem
from .....libs.player.base import BasePlayer
from .....libs.player.params import PlayerParams
from .....libs.player.types import PlayerResult
from .....libs.provider.anime.base import BaseAnimeProvider
from .....libs.provider.anime.params import EpisodeStreamsParams
from .....libs.provider.anime.types import Anime, ProviderServer, Server
from ....service.registry.models import DownloadStatus
from ...registry import MediaRegistryService
from .base import BaseIPCPlayer

logger = logging.getLogger(__name__)


class MPVIPCError(AnicatError):
    """Exception raised for MPV IPC communication errors."""

    pass


class MPVIPCClient:
    """Client for communicating with MPV via IPC socket with a dedicated reader thread."""

    def __init__(self, socket_path: str):
        self.socket_path = socket_path
        self.socket: Optional[Any] = None
        self._request_id_counter = 0
        self._lock = threading.Lock()

        self._reader_thread: Optional[threading.Thread] = None
        self._stop_event = threading.Event()
        self._message_buffer = b""

        self._event_queue: Queue = Queue()
        self._response_dict: Dict[int, Any] = {}
        self._response_events: Dict[int, threading.Event] = {}

    @staticmethod
    def _is_windows_named_pipe(path: str) -> bool:
        return path.startswith("\\\\.\\pipe\\")

    @staticmethod
    def _supports_unix_sockets() -> bool:
        return hasattr(socket, "AF_UNIX")

    @staticmethod
    def _open_windows_named_pipe(path: str):
        # MPV's JSON IPC on Windows uses named pipes like: \\.\pipe\mpvpipe
        # Opening the pipe as a binary file supports read/write.
        f = open(path, "r+b", buffering=0)

        class _PipeConn:
            def __init__(self, fileobj):
                self._f = fileobj

            def recv(self, n: int) -> bytes:
                return self._f.read(n)

            def sendall(self, data: bytes) -> None:
                self._f.write(data)
                self._f.flush()

            def close(self) -> None:
                self._f.close()

        return _PipeConn(f)

    def connect(self, timeout: float = 5.0) -> None:
        """Connect to MPV IPC socket and start the reader thread."""

        start_time = time.time()
        while time.time() - start_time < timeout:
            try:
                if self._supports_unix_sockets() and not self._is_windows_named_pipe(
                    self.socket_path
                ):
                    self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)  # type: ignore (type error on Windows but this code path won't be used there)
                    self.socket.connect(self.socket_path)
                else:
                    if os.name != "nt" or not self._is_windows_named_pipe(
                        self.socket_path
                    ):
                        raise MPVIPCError(
                            "MPV IPC requires Unix domain sockets (AF_UNIX) or a Windows named pipe path "
                            "like \\\\.\\pipe\\mpvpipe. Got: "
                            f"{self.socket_path}"
                        )
                    self.socket = self._open_windows_named_pipe(self.socket_path)
                logger.info(f"Connected to MPV IPC socket at {self.socket_path}")
                self._start_reader_thread()
                return
            except (ConnectionRefusedError, FileNotFoundError, OSError):
                time.sleep(0.2)
        raise MPVIPCError(f"Failed to connect to MPV IPC socket at {self.socket_path}")

    def disconnect(self) -> None:
        """Disconnect from MPV IPC socket and stop the reader thread."""
        self._stop_event.set()
        if self._reader_thread and self._reader_thread.is_alive():
            self._reader_thread.join(timeout=2.0)
        if self.socket:
            try:
                self.socket.close()
            except Exception:
                pass
            self.socket = None

    def _start_reader_thread(self):
        """Starts the background thread to read messages from the socket."""
        self._stop_event.clear()
        self._reader_thread = threading.Thread(target=self._read_loop, daemon=True)
        self._reader_thread.start()

    def _read_loop(self):
        """Continuously reads data from the socket and processes messages."""
        while not self._stop_event.is_set():
            try:
                if not self.socket:
                    break
                # A blocking recv is efficient as the thread will sleep until data is available.
                data = self.socket.recv(4096)
                if not data:
                    logger.info("MPV IPC socket closed.")
                    # Put a special event to signal the main loop that MPV has shut down.
                    self._event_queue.put({"event": "shutdown"})
                    break

                self._message_buffer += data
                self._process_buffer()
            except (socket.timeout, BlockingIOError):
                continue
            except Exception as e:
                if not self._stop_event.is_set():
                    logger.error(f"Error in IPC read loop: {e}")
                break

    def _process_buffer(self):
        """Processes the internal buffer to extract full JSON messages."""
        while b"\n" in self._message_buffer:
            message_data, self._message_buffer = self._message_buffer.split(b"\n", 1)
            if not message_data:
                continue

            try:
                message = json.loads(message_data.decode("utf-8"))
                # Responses have a 'request_id' and 'error' field, events do not.
                if "request_id" in message and "error" in message:
                    req_id = message["request_id"]
                    with self._lock:
                        self._response_dict[req_id] = message
                        if req_id in self._response_events:
                            self._response_events[req_id].set()
                else:  # It's an event
                    self._event_queue.put(message)
            except (json.JSONDecodeError, UnicodeDecodeError) as e:
                logger.warning(
                    f"Failed to decode MPV message: {message_data[:100]}... Error: {e}"
                )

    def get_event(self, block: bool = True, timeout: Optional[float] = None) -> Any:
        """Retrieves an event from the event queue."""
        try:
            return self._event_queue.get(block=block, timeout=timeout)
        except Empty:
            return None

    def send_command(self, command: List[Any], timeout: float = 5.0) -> Dict[str, Any]:
        """Send a command and wait for a specific response."""
        if not self.socket:
            raise MPVIPCError("Not connected to MPV")

        with self._lock:
            self._request_id_counter += 1
            request_id = self._request_id_counter

            request = {"command": command, "request_id": request_id}

            response_event = threading.Event()
            self._response_events[request_id] = response_event

        try:
            message = json.dumps(request) + "\n"
            self.socket.sendall(message.encode("utf-8"))

            if response_event.wait(timeout=timeout):
                with self._lock:
                    return self._response_dict.pop(request_id, {})
            else:
                raise MPVIPCError(f"Timeout waiting for response to command: {command}")
        finally:
            with self._lock:
                self._response_events.pop(request_id, None)


@dataclass
class PlayerState:
    """Represents the dynamic state of the media player."""

    stream_config: StreamConfig
    query: str
    episode: str
    servers: Dict[ProviderServer, Server] = field(default_factory=dict)
    server_name: Optional[ProviderServer] = None
    media_item: Optional[MediaItem] = None
    stop_time_secs: float = 0
    total_time_secs: float = 0

    @property
    def episode_title(self) -> str:
        if self.media_item:
            if (
                self.media_item.streaming_episodes
                and self.episode in self.media_item.streaming_episodes
            ):
                return (
                    self.media_item.streaming_episodes[self.episode].title
                    or f"Episode {self.episode}"
                )
            return f"{self.media_item.title.english or self.media_item.title.romaji} - Episode {self.episode}"
        if server := self.server:
            return server.episode_title or f"Episode {self.episode}"
        return f"Episode {self.episode}"

    @property
    def server(self) -> Optional[Server]:
        if not self.servers:
            logger.warning("Attempt to access server when servers are unavailable.")
            return None

        server_name = self.stream_config.server
        if server_name not in self.servers:
            if self.server_name and self.server_name in self.servers:
                server_name = self.server_name
            else:
                server_name = list(self.servers.keys())[0]
                self.server_name = server_name

        return self.servers.get(server_name)

    @property
    def stream_url(self) -> Optional[str]:
        if server := self.server:
            preferred_quality = self.stream_config.quality
            selected_link = next(
                (link for link in server.links if link.quality == preferred_quality),
                None,
            )
            if not selected_link:
                try:
                    selected_link = sorted(
                        server.links, key=lambda x: int(x.quality), reverse=True
                    )[0]
                except Exception:
                    selected_link = server.links[-1]
            raw_url = selected_link.link
            if raw_url.startswith("http://") or raw_url.startswith("https://"):
                import json
                import urllib.parse
                from anicat_media.core.constants import LOCAL_API_ORIGIN
                
                headers_str = json.dumps(server.headers or {})
                proxied_url = (
                    f"{LOCAL_API_ORIGIN}/api/actions/proxy"
                    f"?url={urllib.parse.quote(raw_url)}"
                    f"&headers={urllib.parse.quote(headers_str)}"
                )
                return proxied_url
            return raw_url
        return None

    @property
    def stream_subtitles(self) -> List[str]:
        if not self.server:
            return []
        import json
        import urllib.parse
        from anicat_media.core.constants import LOCAL_API_ORIGIN
        
        proxied_subs = []
        for sub in self.server.subtitles:
            url = sub.url
            if url.startswith("http://") or url.startswith("https://"):
                headers_str = json.dumps(self.server.headers or {})
                proxied_url = (
                    f"{LOCAL_API_ORIGIN}/api/actions/proxy"
                    f"?url={urllib.parse.quote(url)}"
                    f"&headers={urllib.parse.quote(headers_str)}"
                )
                proxied_subs.append(proxied_url)
            else:
                proxied_subs.append(url)
        return proxied_subs

    @property
    def stream_headers(self) -> Dict[str, str]:
        return self.server.headers if self.server else {}

    @property
    def stop_time(self) -> Optional[str]:
        return (
            formatter.format_time(self.stop_time_secs)
            if self.stop_time_secs > 0
            else None
        )

    @property
    def total_time(self) -> Optional[str]:
        return (
            formatter.format_time(self.total_time_secs)
            if self.total_time_secs > 0
            else None
        )

    def reset(self):
        self.stop_time_secs = 0
        self.total_time_secs = 0


class MpvIPCPlayer(BaseIPCPlayer):
    """MPV Player implementation using IPC for advanced features."""

    stream_config: StreamConfig
    mpv_process: Optional[subprocess.Popen]
    ipc_client: Optional[MPVIPCClient]
    player_state: PlayerState
    player_fetching: bool = False
    player_first_run: bool = True
    auto_next_triggered: bool = False
    event_handlers: Dict[str, List[Callable]] = {}
    property_observers: Dict[str, List[Callable]] = {}
    key_bindings: Dict[str, Callable] = {}
    message_handlers: Dict[str, Callable] = {}
    provider: Optional[BaseAnimeProvider] = None
    anime: Optional[Anime] = None
    media_item: Optional[MediaItem] = None

    registry: Optional[MediaRegistryService] = None

    def __init__(self, stream_config: StreamConfig):
        super().__init__(stream_config)
        self.socket_path: Optional[str] = None
        self._fetch_thread: Optional[threading.Thread] = None
        self._fetch_result_queue: Queue = Queue()
        self.ipc_client: Optional[MPVIPCClient] = None
        self.mpv_process: Optional[subprocess.Popen] = None

    def play(
        self,
        player: BasePlayer,
        player_params: PlayerParams,
        provider: Optional[BaseAnimeProvider] = None,
        anime: Optional[Anime] = None,
        registry: Optional[MediaRegistryService] = None,
        media_item: Optional[MediaItem] = None,
    ) -> PlayerResult:
        self.provider = provider
        self.anime = anime
        self.media_item = media_item
        self.registry = registry
        if player_params.translation_type:
            self.stream_config.translation_type = player_params.translation_type
        self.player_state = PlayerState(
            self.stream_config,
            player_params.query,
            player_params.episode,
            media_item=media_item,
        )

        return self._play_with_ipc(player, player_params)

    def _play_with_ipc(self, player: BasePlayer, params: PlayerParams) -> PlayerResult:
        """Play media using MPV IPC."""
        try:
            self._start_mpv_process(player, params)
            self._connect_ipc()
            self._setup_event_handling()
            self._setup_key_bindings()
            self._setup_message_handlers()

            # Explicitly load the initial local file if registry is present (local playback)
            # or if the URL does not start with http/https. This ensures MPV bypasses the
            # idle state (especially on macOS) and plays the local file immediately.
            is_local = self.registry is not None or not (
                params.url.startswith("http://") or params.url.startswith("https://")
            )
            if is_local and self.ipc_client:
                logger.info(f"Explicitly loading local file via IPC: {params.url}")
                self.ipc_client.send_command(["loadfile", params.url])

            self._wait_for_playback()

            return PlayerResult(
                episode=self.player_state.episode,
                stop_time=self.player_state.stop_time,
                total_time=self.player_state.total_time,
            )
        except MPVIPCError as e:
            logger.warning(
                f"IPC connection failed: {e}. Falling back to non-IPC playback."
            )
            is_interactive = sys.stdin and sys.stdin.isatty()
            if not is_interactive:
                logger.info(
                    "Non-interactive session: automatically falling back to standard playback."
                )
                return player.play(params)

            if (
                input("Failed to play with IPC. Continue without it? (Y/n): ").lower()
                != "n"
            ):
                return player.play(params)
            else:
                return PlayerResult(
                    episode=params.episode, stop_time=None, total_time=None
                )
        finally:
            self._cleanup()

    def _start_mpv_process(self, player: BasePlayer, params: PlayerParams) -> None:
        """Start MPV process with IPC enabled.

        L2: Uses a random hex suffix to prevent predictable socket paths
        that could be targeted by other local processes.
        """
        if hasattr(socket, "AF_UNIX"):
            import secrets

            temp_dir = Path(tempfile.gettempdir())
            rand_hex = secrets.token_hex(8)
            self.socket_path = str(
                temp_dir / f"mpv_ipc_{int(time.time())}_{rand_hex}.sock"
            )
        else:
            # Windows MPV IPC uses named pipes.
            import secrets

            rand_hex = secrets.token_hex(8)
            self.socket_path = (
                f"\\\\.\\pipe\\mpv_ipc_{int(time.time() * 1000)}_{rand_hex}"
            )
        self.mpv_process = player.play_with_ipc(params, self.socket_path)
        time.sleep(1.0)

    def _connect_ipc(self):
        if not self.socket_path:
            raise MPVIPCError("Socket path not set")
        self.ipc_client = MPVIPCClient(self.socket_path)
        self.ipc_client.connect()

    def _setup_event_handling(self):
        if not self.ipc_client:
            return
        self.ipc_client.send_command(["request_log_messages", "info"])
        self.ipc_client.send_command(["observe_property", 1, "time-pos"])
        self.ipc_client.send_command(["observe_property", 2, "duration"])
        self.ipc_client.send_command(["observe_property", 3, "percent-pos"])
        self.ipc_client.send_command(["observe_property", 4, "filename"])

    def _bind_key(self, key, command, description):
        if not self.ipc_client:
            return
        try:
            response = self.ipc_client.send_command(["keybind", key, command])
            if response.get("error") != "success":
                logger.warning(f"Failed to bind key {key}: {response.get('error')}")
                self._show_text(f"Error binding '{description}' key", duration=3000)
        except Exception as e:
            logger.error(f"Exception binding key {key}: {e}")

    def _setup_key_bindings(self):
        key_bindings = {
            "shift+n": ("script-message anicat-next-episode", "Next Episode"),
            "N": ("script-message anicat-next-episode", "Next Episode"),
            "shift+p": (
                "script-message anicat-previous-episode",
                "Previous Episode",
            ),
            "P": (
                "script-message anicat-previous-episode",
                "Previous Episode",
            ),
            "shift+a": (
                "script-message anicat-toggle-auto-next",
                "Toggle Auto-Next",
            ),
            "shift+t": (
                "script-message anicat-toggle-translation",
                "Toggle Translation",
            ),
            "shift+r": ("script-message anicat-reload-episode", "Reload Episode"),
        }
        for key, (command, description) in key_bindings.items():
            self._bind_key(key, command, description)

        self._show_text("Anicat IPC: Shift+N=Next, Shift+P=Prev, Shift+R=Reload", 3000)

    def _setup_message_handlers(self):
        self.message_handlers.update(
            {
                "anicat-next-episode": self._next_episode,
                "anicat-previous-episode": self._previous_episode,
                "anicat-reload-episode": self._reload_episode,
                "anicat-toggle-auto-next": self._toggle_auto_next,
                "anicat-toggle-translation": self._toggle_translation_type,
                "select-episode": self._handle_select_episode,
                "select-server": self._handle_select_server,
                "select-quality": self._handle_select_quality,
            }
        )

    def _wait_for_playback(self):
        """A non-blocking loop that checks for MPV process exit and processes events."""
        if not self.ipc_client:
            return

        should_stop = False
        try:
            while not should_stop:
                if self.mpv_process and self.mpv_process.poll() is not None:
                    logger.info("MPV process has exited.")
                    break

                while True:
                    message = self.ipc_client.get_event(block=False)
                    if message is None:
                        break

                    if message.get("event") == "shutdown":
                        should_stop = True
                        break

                    self._handle_mpv_message(message)

                try:
                    fetch_result = self._fetch_result_queue.get(block=False)
                    self._handle_fetch_result(fetch_result)
                except Empty:
                    pass

                if should_stop:
                    break
                time.sleep(0.05)

        except KeyboardInterrupt:
            logger.info("Playback interrupted by user")

    def _handle_mpv_message(self, message: Dict[str, Any]):
        event = message.get("event")
        if event == "property-change":
            self._handle_property_change(message)
        elif event == "client-message":
            self._handle_client_message(message)
        elif event == "file-loaded":
            time.sleep(0.1)
            self._configure_player()
        elif event == "end-of-file":
            if message.get("reason") == "eof":
                self._auto_next_episode()
        elif event:
            logger.debug(f"MPV event: {event}")

    def _handle_property_change(self, message: Dict[str, Any]):
        name = message.get("name")
        data = message.get("data")
        if name == "time-pos" and isinstance(data, (int, float)):
            self.player_state.stop_time_secs = data
            self._check_and_auto_track()
        elif name == "duration" and isinstance(data, (int, float)):
            self.player_state.total_time_secs = data
            self._check_and_auto_track()
        elif name == "percent-pos" and isinstance(data, (int, float)):
            # Percentage position changed
            pass

    def _check_and_auto_track(self):
        if not self.media_item or self.player_fetching:
            return

        stop_secs = self.player_state.stop_time_secs
        total_secs = self.player_state.total_time_secs

        if total_secs <= 0 or stop_secs <= 0:
            return

        complete_percent = self.stream_config.episode_complete_at
        pct = (stop_secs / total_secs) * 100

        if pct >= complete_percent:
            self._trigger_progress_sync()

    def _trigger_progress_sync(self):
        current_ep = self.player_state.episode
        if not current_ep:
            return
        
        # Avoid double-triggering for the same episode
        if getattr(self.player_state, "synced_episode", None) == current_ep:
            return

        self.player_state.synced_episode = current_ep

        # Spawn background sync thread to prevent blocking player control UI
        threading.Thread(
            target=self._sync_progress_task,
            args=(current_ep, self.player_state.stop_time_secs, self.player_state.total_time_secs),
            daemon=True
        ).start()

    def _sync_progress_task(self, episode: str, stop_secs: float, total_secs: float):
        try:
            from anicat_media.core.context import get_ctx
            ctx = get_ctx()
            if not self.media_item:
                return

            # 1. Update local watch history
            from .....libs.player.types import PlayerResult

            def _to_hhmmss(sec) -> str | None:
                if sec is None or sec <= 0:
                    return None
                try:
                    total_sec = int(float(sec))
                    h = total_sec // 3600
                    m = (total_sec % 3600) // 60
                    s = total_sec % 60
                    return f"{h:02d}:{m:02d}:{s:02d}"
                except (ValueError, TypeError):
                    return None

            result = PlayerResult(
                episode=episode,
                stop_time=_to_hhmmss(stop_secs),
                total_time=_to_hhmmss(total_secs),
            )
            ctx.watch_history.track(self.media_item, result)

            # 2. Update local registry and remote AniList tracking
            try:
                ep_num = int(float(episode))
            except ValueError:
                ep_num = 0

            # Re-fetch media item from AniList to get latest user status
            media_item = ctx.media_api.get_media_item(self.media_item.id)
            if media_item:
                self.media_item = media_item
                current_progress = (
                    media_item.user_status.progress if media_item.user_status else 0
                )
            else:
                current_progress = 0

            if ep_num > current_progress:
                # Update progress in local registry
                ctx.media_registry.update_media_index_entry(
                    media_id=self.media_item.id, progress=str(ep_num)
                )

                # Sync with AniList
                from .....libs.media_api.params import UpdateUserMediaListEntryParams
                params = UpdateUserMediaListEntryParams(
                    media_id=self.media_item.id, progress=str(ep_num)
                )
                ctx.media_api.update_list_entry(params)

            # Increment data version to notify frontend immediately
            ctx.data_version += 1
            logger.info(f"Automatically tracked and synced episode {episode} progress.")

        except Exception as e:
            logger.error(f"Error in automatic background progress tracking: {e}", exc_info=True)

    def _save_current_position_history(self):
        try:
            if not self.media_item or not self.player_state.episode:
                return
            from anicat_media.core.context import get_ctx
            ctx = get_ctx()

            def _to_hhmmss(sec) -> str | None:
                if sec is None or sec <= 0:
                    return None
                try:
                    total_sec = int(float(sec))
                    h = total_sec // 3600
                    m = (total_sec % 3600) // 60
                    s = total_sec % 60
                    return f"{h:02d}:{m:02d}:{s:02d}"
                except (ValueError, TypeError):
                    return None

            from .....libs.player.types import PlayerResult
            result = PlayerResult(
                episode=self.player_state.episode,
                stop_time=_to_hhmmss(self.player_state.stop_time_secs),
                total_time=_to_hhmmss(self.player_state.total_time_secs),
            )
            ctx.watch_history.track(self.media_item, result)
            ctx.data_version += 1
            logger.info(f"Saved intermediate watch history for episode {self.player_state.episode}")
        except Exception as e:
            logger.error(f"Failed to save intermediate watch history: {e}")

    def _handle_client_message(self, message: Dict[str, Any]):
        args = message.get("args", [])
        if args:
            handler_name = args[0]
            handler_args = args[1:]
            handler = self.message_handlers.get(handler_name)
            if handler:
                try:
                    handler(*handler_args)
                except Exception as e:
                    logger.error(f"Error in message handler for '{handler_name}': {e}")

    def _cleanup(self):
        if self.ipc_client:
            self.ipc_client.disconnect()
        if self.mpv_process:
            try:
                # Send SIGTERM first for a graceful shutdown that releases
                # VideoToolbox decoder sessions.
                logger.info("Terminating MPV process pid=%d", self.mpv_process.pid)
                self.mpv_process.terminate()
                try:
                    self.mpv_process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    # SIGTERM didn't work — try SIGKILL.  This is critical on
                    # macOS to free hardware decoder slots that other apps
                    # (including Safari/Chrome for Netflix) need.
                    logger.warning(
                        "MPV process pid=%d did not exit after SIGTERM, sending SIGKILL",
                        self.mpv_process.pid,
                    )
                    self.mpv_process.kill()
                    try:
                        self.mpv_process.wait(timeout=2)
                    except subprocess.TimeoutExpired:
                        logger.error(
                            "MPV process pid=%d still alive after SIGKILL",
                            self.mpv_process.pid,
                        )
            except Exception as e:
                logger.error("Error during MPV process cleanup: %s", e)
                # Last resort — try os.kill directly in case the Popen object
                # is stale but the pid is still valid.
                if self.mpv_process and self.mpv_process.pid:
                    try:
                        os.kill(self.mpv_process.pid, signal.SIGKILL)
                    except (ProcessLookupError, PermissionError):
                        pass
        if (
            self.socket_path
            and not self.socket_path.startswith("\\\\.\\pipe\\")
            and Path(self.socket_path).exists()
        ):
            Path(self.socket_path).unlink(missing_ok=True)

    def _get_episode(
        self,
        episode_type: Literal["next", "previous", "reload", "custom"],
        ep_no: Optional[str] = None,
    ):
        if self.player_fetching:
            self._show_text("Player is busy. Please wait.")
            return

        self.player_fetching = True
        self._show_text(f"Fetching {episode_type} episode...")

        self._fetch_thread = threading.Thread(
            target=self._fetch_episode_task, args=(episode_type, ep_no), daemon=True
        )
        self._fetch_thread.start()

    def _fetch_episode_task(
        self,
        episode_type: Literal["next", "previous", "reload", "custom"],
        ep_no: Optional[str] = None,
    ):
        """This function runs in a background thread to fetch episode streams."""
        try:
            self._save_current_position_history()
            if self.anime and self.provider:
                available_episodes = getattr(
                    self.anime.episodes, self.stream_config.translation_type
                )
                if not available_episodes:
                    raise ValueError(
                        f"No {self.stream_config.translation_type} episodes available."
                    )

                current_index = available_episodes.index(self.player_state.episode)

                if episode_type == "next":
                    if current_index >= len(available_episodes) - 1:
                        raise ValueError("Already at the last episode.")
                    target_episode = available_episodes[current_index + 1]
                elif episode_type == "previous":
                    if current_index <= 0:
                        raise ValueError("Already at first episode")
                    target_episode = available_episodes[current_index - 1]
                elif episode_type == "reload":
                    target_episode = self.player_state.episode
                elif episode_type == "custom":
                    if not ep_no or ep_no not in available_episodes:
                        raise ValueError(
                            f"Invalid episode. Available: {', '.join(available_episodes)}"
                        )
                    target_episode = ep_no
                else:
                    return

                stream_params = EpisodeStreamsParams(
                    anime_id=self.anime.id,
                    query=self.player_state.query,
                    episode=target_episode,
                    translation_type=self.stream_config.translation_type,
                )
                # This is the blocking network call, now safely in a thread
                episode_streams = list(
                    self.provider.episode_streams(stream_params) or []
                )
                if not episode_streams:
                    raise ValueError(f"No streams found for episode {target_episode}")

                result = {
                    "type": "success",
                    "target_episode": target_episode,
                    "servers": {ProviderServer(s.name): s for s in episode_streams},
                }
                self._fetch_result_queue.put(result)
            elif self.registry and self.media_item:
                record = self.registry.get_media_record(self.media_item.id)
                if not record or not record.media_episodes:
                    logger.warning("No downloaded episodes found for this anime.")
                    return

                downloaded_episodes = {
                    ep.episode_number: ep.file_path
                    for ep in record.media_episodes
                    if ep.download_status == DownloadStatus.COMPLETED
                    and ep.file_path
                    and ep.file_path.exists()
                }
                available_episodes = list(sorted(downloaded_episodes.keys(), key=float))
                current_index = available_episodes.index(self.player_state.episode)

                if episode_type == "next":
                    if current_index >= len(available_episodes) - 1:
                        raise ValueError("Already at the last episode.")
                    target_episode = available_episodes[current_index + 1]
                elif episode_type == "previous":
                    if current_index <= 0:
                        raise ValueError("Already at first episode")
                    target_episode = available_episodes[current_index - 1]
                elif episode_type == "reload":
                    target_episode = self.player_state.episode
                elif episode_type == "custom":
                    if not ep_no or ep_no not in available_episodes:
                        raise ValueError(
                            f"Invalid episode. Available: {', '.join(available_episodes)}"
                        )
                    target_episode = ep_no
                else:
                    return
                file_path = downloaded_episodes[target_episode]

                self.player_state.reset()
                self.player_state.episode = target_episode
                if self.ipc_client:
                    self.ipc_client.send_command(["loadfile", str(file_path)])
                self._show_text(f"Fetched {file_path}")
                self.player_fetching = False

                # Update frontend Now Playing status
                if self.media_item:
                    try:
                        from anicat_media.api.routers.status import set_playback
                        set_playback(
                            media_id=self.media_item.id,
                            media_title=self.media_item.title.english or self.media_item.title.romaji,
                            episode=target_episode,
                        )
                        from anicat_media.core.context import get_ctx
                        get_ctx().data_version += 1
                    except Exception as e:
                        logger.error(f"Failed to update playback status on next local episode: {e}")

        except Exception as e:
            logger.error(f"Episode fetch task failed: {e}")
            self._fetch_result_queue.put({"type": "error", "message": str(e)})

    def _handle_fetch_result(self, result: Dict[str, Any]):
        """Handles the result from the background fetch thread in the main thread."""
        self.player_fetching = False
        if result["type"] == "success":
            self.player_state.episode = result["target_episode"]
            self.player_state.servers = result["servers"]
            self.player_state.reset()
            self._show_text(f"Fetched {self.player_state.episode_title}")
            self._load_current_stream()

            # Update frontend Now Playing status
            if self.media_item:
                try:
                    from anicat_media.api.routers.status import set_playback
                    set_playback(
                        media_id=self.media_item.id,
                        media_title=self.media_item.title.english or self.media_item.title.romaji,
                        episode=result["target_episode"],
                    )
                    from anicat_media.core.context import get_ctx
                    get_ctx().data_version += 1
                except Exception as e:
                    logger.error(f"Failed to update playback status on next episode: {e}")
        else:
            self._show_text(f"Error: {result['message']}")

    def _next_episode(self):
        self._get_episode("next")

    def _previous_episode(self):
        self._get_episode("previous")

    def _reload_episode(self):
        self._get_episode("reload")

    def _auto_next_episode(self):
        if self.stream_config.auto_next:
            self._next_episode()

    def _load_current_stream(self):
        if self.ipc_client and self.player_state and self.player_state.stream_url:
            self.ipc_client.send_command(["loadfile", self.player_state.stream_url])

    def _show_text(self, text: str, duration: int = 2000):
        if self.ipc_client:
            self.ipc_client.send_command(["show-text", text, str(duration)])

    def _configure_player(self):
        if not self.ipc_client or self.player_first_run:
            self.player_first_run = False
            return

        self.auto_next_triggered = False

        self.ipc_client.send_command(["seek", 0, "absolute"])
        self.ipc_client.send_command(
            ["set_property", "title", self.player_state.episode_title]
        )
        self._add_episode_subtitles()

        # Send initial auto-next status to Lua overlay
        val = "yes" if self.stream_config.auto_next else "no"
        try:
            self.ipc_client.send_command(
                ["script-message", "anicat-set-auto-next", val]
            )
        except Exception as e:
            logger.debug(f"Failed to send initial auto-next status to MPV: {e}")

    def _add_episode_subtitles(self):
        if not self.ipc_client or not self.player_state.stream_subtitles:
            return

        time.sleep(0.5)
        for i, sub_url in enumerate(self.player_state.stream_subtitles):
            flag = "select" if i == 0 else "auto"
            self.ipc_client.send_command(["sub-add", sub_url, flag])

    def _toggle_auto_next(self):
        self.stream_config.auto_next = not self.stream_config.auto_next
        val = "yes" if self.stream_config.auto_next else "no"
        if self.ipc_client:
            try:
                self.ipc_client.send_command(
                    ["script-message", "anicat-set-auto-next", val]
                )
            except Exception as e:
                logger.debug(f"Failed to send auto-next update to MPV: {e}")
        self._show_text(
            f"Auto-next {'enabled' if self.stream_config.auto_next else 'disabled'}"
        )

    def _toggle_translation_type(self):
        new_type = "sub" if self.stream_config.translation_type == "dub" else "dub"
        self._show_text(f"Switching to {new_type}...")
        self.stream_config.translation_type = new_type
        self._reload_episode()

    def _handle_select_episode(self, episode: Optional[str] = None):
        if episode:
            self._get_episode("custom", episode)

    def _handle_select_server(self, server: Optional[str] = None):
        if not server or not self.player_state:
            return
        try:
            provider_server = ProviderServer(server)
            if provider_server in self.player_state.servers:
                self.player_state.server_name = provider_server
                self._reload_episode()
            else:
                self._show_text(f"Server '{server}' not available.")
        except ValueError:
            available_servers = ", ".join(
                [s.value for s in self.player_state.servers.keys()]
            )
            self._show_text(
                f"Invalid server name: {server}. Available: {available_servers}"
            )

    def _handle_select_quality(self, quality: Optional[str] = None):
        self._show_text("Quality switching is not yet implemented.")
