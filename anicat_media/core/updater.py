import logging
import subprocess
import sys
from pathlib import Path

import httpx

from .constants import APP_CACHE_DIR

logger = logging.getLogger(__name__)

GITHUB_API_URL = "https://api.github.com/repos/bonkedbythonk/anicat/commits/main"
UPDATE_AVAILABLE_FILE = APP_CACHE_DIR / ".update_available"
LAST_COMMIT_FILE = APP_CACHE_DIR / ".last_commit"


_UPDATE_CACHE: bool = False

def check_for_updates(silent: bool = True) -> bool:
    """
    Checks if there's a new commit on the GitHub main branch.
    Returns True if an update is available.
    """
    global _UPDATE_CACHE
    try:
        # Use a very short timeout for background checks
        timeout = 2.0 if silent else 10.0
        with httpx.Client(timeout=timeout) as client:
            response = client.get(GITHUB_API_URL)
            if response.status_code == 200:
                remote_hash = response.json().get("sha")
                
                if not LAST_COMMIT_FILE.exists():
                    LAST_COMMIT_FILE.parent.mkdir(parents=True, exist_ok=True)
                    LAST_COMMIT_FILE.write_text(remote_hash)
                    UPDATE_AVAILABLE_FILE.write_text("0")
                    _UPDATE_CACHE = False
                    return False

                local_hash = LAST_COMMIT_FILE.read_text().strip()
                if remote_hash != local_hash:
                    UPDATE_AVAILABLE_FILE.write_text("1")
                    _UPDATE_CACHE = True
                    return True
                else:
                    UPDATE_AVAILABLE_FILE.write_text("0")
                    _UPDATE_CACHE = False
                    return False
    except Exception as e:
        if not silent:
            print(f"Error checking for updates: {e}")
        logger.debug(f"Silent update check failed: {e}")
    
    return False


def is_update_available() -> bool:
    """Quick check for the cached update flag (in-memory first)."""
    global _UPDATE_CACHE
    if _UPDATE_CACHE:
        return True
        
    if UPDATE_AVAILABLE_FILE.exists():
        try:
            val = UPDATE_AVAILABLE_FILE.read_text().strip() == "1"
            _UPDATE_CACHE = val
            return val
        except Exception:
            return False
    return False


def perform_update():
    """Executes the update command and exits."""
    print("Updating Anicat... please wait.")
    try:
        # First, fetch the remote hash so we can mark it as our new local hash after update
        with httpx.Client(timeout=10.0) as client:
            response = client.get(GITHUB_API_URL)
            if response.status_code == 200:
                remote_hash = response.json().get("sha")
                LAST_COMMIT_FILE.write_text(remote_hash)
                UPDATE_AVAILABLE_FILE.write_text("0")

        subprocess.run(
            ["uv", "tool", "install", "--force", "git+https://github.com/bonkedbythonk/anicat.git"],
            check=True
        )
        print("\n✨ [bold green]Update complete![/bold green]")
        print("Please restart Anicat to use the new version.")
        sys.exit(0)
    except subprocess.CalledProcessError as e:
        print(f"\n❌ [bold red]Update failed:[/bold red] {e}")
        sys.exit(1)
    except Exception as e:
        print(f"\n❌ [bold red]An error occurred during update:[/bold red] {e}")
        sys.exit(1)
