import logging
import subprocess
import sys
from pathlib import Path

import httpx

from .constants import APP_CACHE_DIR

import os
import time

logger = logging.getLogger(__name__)

GITHUB_API_URL = "https://api.github.com/repos/bonkedbythonk/anicat/commits/main"
UPDATE_AVAILABLE_FILE = APP_CACHE_DIR / ".update_available"
LAST_COMMIT_FILE = APP_CACHE_DIR / ".last_commit"
LAST_CHECK_FILE = APP_CACHE_DIR / ".last_update_check"

_UPDATE_CACHE: bool = False

def _is_editable_install() -> bool:
    """Detects if the package is installed in editable mode."""
    package_path = Path(__file__).resolve()
    # If 'site-packages' is not in the path, it's likely a local/editable install
    return "site-packages" not in str(package_path)

def check_for_updates(silent: bool = True, debug: bool = False) -> bool:
    """
    Checks if there's a new commit on the GitHub main branch.
    Returns True if an update is available.
    """
    global _UPDATE_CACHE
    
    # Check 24-hour timeout for silent checks
    if silent and not debug:
        if LAST_CHECK_FILE.exists():
            try:
                last_check = float(LAST_CHECK_FILE.read_text().strip())
                if time.time() - last_check < 86400: # 24 hours
                    return is_update_available()
            except Exception:
                pass

    if debug:
        if _is_editable_install():
            print("[DEBUG] Running in editable mode. Auto-updates are usually ignored.")

    try:
        # Use a very short timeout for background checks
        timeout = 2.0 if silent else 10.0
        with httpx.Client(timeout=timeout) as client:
            response = client.get(GITHUB_API_URL)
            if response.status_code == 200:
                remote_hash = response.json().get("sha")
                
                # Update last check timestamp
                LAST_CHECK_FILE.parent.mkdir(parents=True, exist_ok=True)
                LAST_CHECK_FILE.write_text(str(time.time()))

                if not LAST_COMMIT_FILE.exists():
                    LAST_COMMIT_FILE.parent.mkdir(parents=True, exist_ok=True)
                    LAST_COMMIT_FILE.write_text(remote_hash)
                    UPDATE_AVAILABLE_FILE.write_text("0")
                    _UPDATE_CACHE = False
                    if debug:
                        print(f"[DEBUG] Remote Commit Hash: {remote_hash}")
                        print("[DEBUG] No local hash found. Initialized.")
                    return False

                local_hash = LAST_COMMIT_FILE.read_text().strip()
                update_detected = remote_hash != local_hash
                
                if debug:
                    print(f"[DEBUG] Local Commit Hash:  {local_hash}")
                    print(f"[DEBUG] Remote Commit Hash: {remote_hash}")
                    print(f"[DEBUG] Update Detected:    {update_detected}")

                if update_detected:
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
    
    if os.environ.get("ANICAT_FORCE_UPDATE") == "1":
        return True

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

def clear_update_cache():
    """Clears the update check cache and timestamp to force a fresh check."""
    if UPDATE_AVAILABLE_FILE.exists():
        UPDATE_AVAILABLE_FILE.unlink()
    if LAST_CHECK_FILE.exists():
        LAST_CHECK_FILE.unlink()
    global _UPDATE_CACHE
    _UPDATE_CACHE = False


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
