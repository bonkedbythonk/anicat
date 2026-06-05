import os
import random
import re
from urllib.parse import unquote, urlparse

import httpx

TIMEOUT = 10


def random_user_agent():
    _USER_AGENT_TPL = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/%s Safari/537.36"
    _CHROME_VERSIONS = (
        "120.0.6099.109",
        "120.0.6099.144",
        "120.0.6099.199",
        "120.0.6099.216",
        "121.0.6167.85",
        "121.0.6167.101",
        "121.0.6167.139",
        "121.0.6167.160",
        "122.0.6261.69",
        "122.0.6261.94",
        "122.0.6261.111",
        "122.0.6261.128",
        "123.0.6312.58",
        "123.0.6312.86",
        "123.0.6312.105",
        "123.0.6312.122",
        "124.0.6367.60",
        "124.0.6367.91",
        "124.0.6367.118",
        "124.0.6367.155",
        "125.0.6422.60",
        "125.0.6422.76",
        "125.0.6422.112",
        "125.0.6422.141",
        "126.0.6478.61",
        "126.0.6478.114",
        "126.0.6478.126",
        "126.0.6478.182",
        "127.0.6533.72",
        "127.0.6533.88",
        "127.0.6533.99",
        "127.0.6533.119",
        "128.0.6613.84",
        "128.0.6613.113",
        "128.0.6613.119",
        "128.0.6613.137",
        "129.0.6668.58",
        "129.0.6668.70",
        "129.0.6668.89",
        "129.0.6668.100",
        "130.0.6723.58",
        "130.0.6723.69",
        "130.0.6723.91",
        "130.0.6723.116",
    )
    return _USER_AGENT_TPL % random.choice(_CHROME_VERSIONS)


def get_remote_filename(response: httpx.Response) -> str | None:
    """
    Extracts the filename from the Content-Disposition header or the URL.

    Args:
        response: The httpx.Response object.

    Returns:
        The extracted filename as a string, or None if not found.
    """
    content_disposition = response.headers.get("Content-Disposition")
    if content_disposition:
        filename_match = re.search(
            r"filename\*=(.+)", content_disposition, re.IGNORECASE
        )
        if filename_match:
            encoded_filename = filename_match.group(1).strip()
            try:
                if "''" in encoded_filename:
                    parts = encoded_filename.split("''", 1)
                    if len(parts) == 2:
                        return unquote(parts[1])
                return unquote(
                    encoded_filename
                )  # Fallback for simple URL-encoded parts
            except Exception:
                pass  # Fallback to filename or URL if decoding fails

        filename_match = re.search(
            r"filename=\"?([^\";]+)\"?", content_disposition, re.IGNORECASE
        )
        if filename_match:
            return unquote(filename_match.group(1).strip())

    parsed_url = urlparse(str(response.url))  # Convert httpx.URL to string for urlparse
    path = parsed_url.path
    if path:
        filename_from_url = os.path.basename(path)
        if filename_from_url:
            filename_from_url = filename_from_url.split("?")[0].split("#")[0]
            return unquote(filename_from_url)  # Unquote URL-encoded characters

    return None
