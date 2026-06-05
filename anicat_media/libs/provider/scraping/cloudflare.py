"""Cloudflare challenge solver using nodriver (headless Chrome).

Solves Cloudflare's managed JS challenge by launching a headless Chrome
instance, waiting for the challenge to complete, and extracting the
cf_clearance cookie + user-agent for use with httpx.
"""

import asyncio
import logging
from dataclasses import dataclass
from typing import Dict, Optional

import sys

logger = logging.getLogger(__name__)

# Suppress asyncio's noisy "Event loop is closed" RuntimeError during garbage collection
# which occurs when subprocess transports are deleted after the loop is closed.
_original_unraisablehook = sys.unraisablehook

def _silence_event_loop_closed(unraisable):
    if (
        unraisable.exc_type is RuntimeError
        and "Event loop is closed" in str(unraisable.exc_value)
    ):
        return
    if _original_unraisablehook:
        _original_unraisablehook(unraisable)
    else:
        sys.__unraisablehook__(unraisable)

sys.unraisablehook = _silence_event_loop_closed


@dataclass
class CloudflareSession:
    """Result of a successful Cloudflare challenge solve."""

    cookies: Dict[str, str]
    user_agent: str


def _find_chrome_path() -> Optional[str]:
    """Find the Chrome/Chromium executable path."""
    import shutil
    import platform

    # Check PATH first
    for name in ("google-chrome", "chromium", "chromium-browser"):
        path = shutil.which(name)
        if path:
            return path

    # Platform-specific default locations
    if platform.system() == "Darwin":
        import os

        mac_paths = [
            "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            "/Applications/Chromium.app/Contents/MacOS/Chromium",
            "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            os.path.expanduser(
                "~/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
            ),
        ]
        for p in mac_paths:
            if os.path.isfile(p):
                return p
    elif platform.system() == "Windows":
        import os

        win_paths = [
            os.path.expandvars(
                r"%ProgramFiles%\Google\Chrome\Application\chrome.exe"
            ),
            os.path.expandvars(
                r"%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe"
            ),
            os.path.expandvars(
                r"%LocalAppData%\Google\Chrome\Application\chrome.exe"
            ),
        ]
        for p in win_paths:
            if os.path.isfile(p):
                return p
    elif platform.system() == "Linux":
        import os

        linux_paths = [
            "/usr/bin/google-chrome",
            "/usr/bin/chromium",
            "/usr/bin/chromium-browser",
            "/snap/bin/chromium",
        ]
        for p in linux_paths:
            if os.path.isfile(p):
                return p

    return None


async def _solve_challenge_async(
    url: str,
    *,
    timeout: int = 20,
    chrome_path: Optional[str] = None,
) -> CloudflareSession:
    """Async implementation of the Cloudflare challenge solver.

    Launches a headless Chrome instance via nodriver, navigates to the
    URL, waits for Cloudflare's JS challenge to resolve, then extracts
    cookies and the browser user-agent.

    Args:
        url: The URL to solve the challenge for (e.g. "https://animepahe.pw").
        timeout: Maximum seconds to wait for challenge resolution.
        chrome_path: Optional explicit path to Chrome binary.

    Returns:
        CloudflareSession with cookies and user-agent.

    Raises:
        RuntimeError: If the challenge cannot be solved.
    """
    import nodriver as uc
    from urllib.parse import urlparse

    # Suppress noisy debug logs from websockets/nodriver during solve
    # (they flood output and can cause timing issues with the title polling)
    _ws_logger = logging.getLogger("websockets")
    _nd_logger = logging.getLogger("nodriver")
    _ws_level, _nd_level = _ws_logger.level, _nd_logger.level
    _ws_logger.setLevel(max(_ws_level, logging.WARNING))
    _nd_logger.setLevel(max(_nd_level, logging.WARNING))

    domain = urlparse(url).hostname or ""

    config = uc.Config()
    # Run in headful mode but position the window off-screen to avoid disrupting the user.
    # True headless mode (--headless=new) is detected and blocked by Cloudflare's challenge.
    config.add_argument("--window-position=-32000,-32000")
    config.add_argument("--window-size=10,10")

    if chrome_path:
        config.browser_executable_path = chrome_path
    else:
        detected = _find_chrome_path()
        if detected:
            config.browser_executable_path = detected

    browser = None
    try:
        browser = await uc.start(config=config)
        page = await browser.get(url)

        # Wait for Cloudflare challenge to resolve
        # Poll for cf_clearance cookie or page title change
        elapsed = 0
        poll_interval = 1
        while elapsed < timeout:
            await asyncio.sleep(poll_interval)
            elapsed += poll_interval

            try:
                title = await page.evaluate("document.title")
                if title and "just a moment" not in str(title).lower():
                    logger.debug(
                        f"Cloudflare challenge resolved after {elapsed}s: {title}"
                    )
                    break
            except Exception:
                pass
        else:
            raise RuntimeError(
                f"Cloudflare challenge did not resolve within {timeout}s for {url}"
            )

        # Small extra delay for cookies to finalize
        await asyncio.sleep(1)

        # Extract user agent
        user_agent = await page.evaluate("navigator.userAgent")

        # Extract cookies for the target domain
        all_cookies = await browser.cookies.get_all()
        cookie_dict = {}
        for c in all_cookies:
            if domain and domain in c.domain:
                cookie_dict[c.name] = c.value

        if "cf_clearance" not in cookie_dict:
            logger.warning(
                f"No cf_clearance cookie found for {domain}. "
                f"Available: {[c.name for c in all_cookies if domain in c.domain]}"
            )

        return CloudflareSession(cookies=cookie_dict, user_agent=str(user_agent))

    finally:
        # Restore suppressed logger levels
        _ws_logger.setLevel(_ws_level)
        _nd_logger.setLevel(_nd_level)
        if browser:
            try:
                await browser.aclose()
            except Exception:
                pass
            try:
                browser.stop()
            except Exception:
                pass


def solve_cloudflare_challenge(
    url: str,
    *,
    timeout: int = 20,
    chrome_path: Optional[str] = None,
) -> CloudflareSession:
    """Solve a Cloudflare JS challenge and return session cookies.

    This is a synchronous wrapper around the async implementation.
    It's safe to call from synchronous code (e.g. provider __init__).

    Args:
        url: The URL to solve the challenge for.
        timeout: Maximum seconds to wait for challenge resolution.
        chrome_path: Optional explicit path to Chrome binary.

    Returns:
        CloudflareSession with cookies and user-agent.

    Raises:
        RuntimeError: If nodriver is not installed, Chrome is not found,
                      or the challenge cannot be solved.
    """
    try:
        import nodriver  # noqa: F401
    except ImportError:
        raise RuntimeError(
            "nodriver is required for Cloudflare bypass but is not installed. "
            "Install it with: pip install nodriver"
        )

    # Use a fresh event loop to avoid conflicts with any running loop
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        loop = None

    if loop and loop.is_running():
        # We're inside an existing event loop — run in a thread
        import concurrent.futures

        with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
            future = executor.submit(
                asyncio.run,
                _solve_challenge_async(
                    url, timeout=timeout, chrome_path=chrome_path
                ),
            )
            return future.result(timeout=timeout + 30)
    else:
        return asyncio.run(
            _solve_challenge_async(
                url, timeout=timeout, chrome_path=chrome_path
            )
        )
