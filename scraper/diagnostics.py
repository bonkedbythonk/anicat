"""Shared scraping diagnostics.

Providers scrape HTML/JSON whose structure can change without notice. When a
selector that should match something returns nothing, that is almost always a
provider layout change rather than a genuinely empty result — and silently
returning [] turns it into a blank screen for the user. `warn_empty` makes that
failure mode loud and self-identifying so the cause is one log line away.
"""

import logging

log = logging.getLogger("anicat-scraper.diagnostics")


def warn_empty(provider: str, selector: str, context: str = "") -> None:
    """Log that `selector` matched nothing for `provider`.

    Call this at the points where an empty match means the parser is broken
    (search returned no cards, a detail page yielded no episodes, an API
    response had no results) rather than where empty is legitimately possible.
    """
    suffix = f" ({context})" if context else ""
    log.warning(
        "[%s] selector matched nothing: %s%s — provider layout may have changed",
        provider,
        selector,
        suffix,
    )
