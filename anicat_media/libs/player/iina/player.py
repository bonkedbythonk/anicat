import subprocess
import logging
from typing import Optional

from ....core.config import StreamConfig
from ..base import BasePlayer
from ..params import PlayerParams
from ..types import PlayerResult

logger = logging.getLogger(__name__)

class IinaPlayer(BasePlayer):
    """
    IINA player implementation using macOS `open` command.
    """

    def __init__(self, config: StreamConfig):
        super().__init__(config)

    def play(self, params: PlayerParams) -> PlayerResult:
        """
        Play the media using IINA by executing it via the macOS open command.
        This call is blocking because it waits for the IINA process to close,
        which allows Anicat's auto_next loop to function natively.
        """
        # IINA is based on mpv and supports mpv-style arguments.
        # We pass these through the macOS 'open' command using --args.
        iina_args = []
        
        if params.headers:
            header_fields = []
            for k, v in params.headers.items():
                # mpv/IINA prefers "Field: Value" format in http-header-fields
                # We use "Referer" instead of "Referrer" for the header field name
                header_key = "Referer" if k.lower() == "referer" else k
                header_fields.append(f"{header_key}: {v}")
            
            if header_fields:
                iina_args.append(f'--http-header-fields="{",".join(header_fields)}"')

        if params.title:
            iina_args.append(f"--title={params.title}")

        if params.start_time:
            iina_args.append(f"--start={params.start_time}")

        # Construct final command
        commands = [
            "open",
            "-W",  # Wait for the application to exit
            "-n",  # Open a new instance of the application
            "-a",
            "IINA",
        ]
        
        if iina_args:
            commands.append("--args")
            commands.extend(iina_args)
        
        commands.append(params.url)

        logger.info(f"Launching IINA: {' '.join(commands)}")

        try:
            # We run blocking here. When the user quits IINA, it returns.
            subprocess.run(commands, check=False)
            
            # Since IINA doesn't have an IPC returned to us easily, we just return a stub result
            return PlayerResult(
                status="completed",
                last_position="0:00",
                duration="0:00",
                percent_pos=0.0
            )
        except Exception as e:
            logger.error(f"Failed to launch IINA: {e}")
            return PlayerResult(
                status="failed",
                last_position="0:00",
                duration="0:00",
                percent_pos=0.0
            )

    def play_with_ipc(self, params: PlayerParams, socket_path: str) -> subprocess.Popen:
        """
        IINA does not currently support the same IPC tracking pattern used by MPV natively.
        Raises NotImplementedError.
        """
        raise NotImplementedError("IINA does not support IPC through Anicat currently.")
