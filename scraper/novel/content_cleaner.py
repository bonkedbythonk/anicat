"""DOM Cleaner & Typography Normalizer for CrossPoint E-Ink EPUBs."""

import re
from bs4 import BeautifulSoup


def clean_chapter_html(raw_html: str, chapter_title: str) -> str:
    """
    1. Removes scripts, styles, forms, SVGs, and orphan containers.
    2. Deduplicates headings that repeat the chapter title or generic section markers.
    3. Normalizes scene breaks (* * *, ---, etc.) into decorative ornaments (❖ ❖ ❖).
    4. Applies initial drop-cap styling to the narrative opening.
    5. Strips empty tags and orphan containers.
    """
    if not raw_html:
        return "<p></p>"

    soup = BeautifulSoup(raw_html, "html.parser")
    norm_title = re.sub(r"[^\w\s]", "", chapter_title.lower()).strip()

    # 1. Strip unwanted tags
    for tag in soup.find_all(["script", "style", "form", "svg", "input", "button", "iframe"]):
        tag.decompose()

    # 2. Deduplicate repeated chapter headings
    for h in list(soup.find_all(["h1", "h2", "h3", "h4", "h5", "h6"])):
        h_txt = re.sub(r"[^\w\s]", "", h.get_text(strip=True).lower()).strip()
        if not h_txt or h_txt == norm_title or h_txt in norm_title or norm_title in h_txt:
            h.decompose()
        elif re.match(r"^(prologue|epilogue|afterword|chapter\s*\d+|part\s*\d+|volume\s*\d+|insert|title\s*page)$", h_txt):
            h.decompose()

    # 3. Check top leaf paragraphs for duplicate title strings
    for p in list(soup.find_all(["p", "div"])):
        if p.find(["p", "div"]):
            continue  # Preserve container divs
        p_raw = p.get_text(strip=True)
        p_norm = re.sub(r"[^\w\s]", "", p_raw.lower()).strip()
        if p_norm and (p_norm == norm_title or p_norm in norm_title or re.match(r"^(prologue|epilogue|afterword|chapter\s*\d+|part\s*\d+|volume\s*\d+|title\s*page|insert)$", p_norm)):
            if len(p_raw) < 120:
                p.decompose()

    # 4. Standardize scene break markers
    for p in soup.find_all("p"):
        txt = p.get_text(strip=True)
        if re.match(r"^([*•◆❖✦—~-]\s*){2,}$", txt) or txt in ("***", "◆◆◆", "❖❖❖", "✦✦✦", "---", "--"):
            p["class"] = "scene-break"
            p.string = "❖ ❖ ❖"

    # 5. Remove empty elements
    for p in list(soup.find_all(["p", "div", "span"])):
        if not p.find(["p", "div", "img", "picture"]) and not p.get_text(strip=True):
            p.decompose()

    # 6. Apply initial drop cap to first paragraph
    first_p = soup.select_one("p:not(.scene-break)")
    if first_p:
        txt = first_p.get_text(strip=True)
        if len(txt) > 30 and not first_p.get("class"):
            first_p["class"] = "drop-cap"

    return "".join(str(c) for c in soup.children if str(c).strip())
