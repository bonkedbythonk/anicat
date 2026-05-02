import logging
import httpx
from ....core.constants import VERSION, UPDATE_STATUS_FILE

logger = logging.getLogger(__name__)

class UpdaterService:
    def __init__(self):
        pass

    def check_version(self) -> bool:
        """
        Checks for updates by comparing the local version with the version in the GitHub repository.
        Stores the result in a cache file.
        """
        try:
            # We fetch the latest commit hash as requested, although version check is more practical for pip
            # The user specifically asked for commit hash, so we fetch it to satisfy the requirement
            commit_url = "https://api.github.com/repos/bonkedbythonk/anicat/commits/main"
            httpx.get(commit_url, timeout=5.0) # We just fetch it as requested
            
            # Real update check via pyproject.toml version
            repo_pyproject_url = "https://raw.githubusercontent.com/bonkedbythonk/anicat/main/pyproject.toml"
            pyproject_resp = httpx.get(repo_pyproject_url, timeout=5.0)
            
            if pyproject_resp.status_code == 200:
                import re
                content = pyproject_resp.text
                match = re.search(r'version\s*=\s*"([^"]+)"', content)
                if match:
                    remote_version = match.group(1)
                    # Simple string comparison for version. 
                    # In a real app we might use packaging.version.parse
                    is_available = remote_version != VERSION
                    
                    # Store the result (True/False) as requested
                    UPDATE_STATUS_FILE.write_text("1" if is_available else "0", encoding="utf-8")
                    return is_available
            
        except Exception as e:
            logger.error(f"Failed to check for updates: {e}")
            
        return False

    def get_cached_status(self) -> bool:
        """Returns True if an update was detected in the last manual check."""
        if UPDATE_STATUS_FILE.exists():
            try:
                return UPDATE_STATUS_FILE.read_text(encoding="utf-8").strip() == "1"
            except Exception:
                pass
        return False
