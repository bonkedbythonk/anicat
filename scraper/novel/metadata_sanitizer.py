"""Metadata Sanitizer & File Namer for E-Ink E-Readers."""

import re


def sanitize_ascii_text(text: str) -> str:
    """
    Prevents ??? question mark errors on e-ink firmware by stripping
    unmapped CJK kanji/kana and bracketed Japanese notes.
    """
    if not text:
        return ""
    # Remove bracketed Japanese (e.g. 'Riku Misora (海空りく)' -> 'Riku Misora')
    s = re.sub(r"\s*[\(\（][^\x00-\x7F]+[\)\）]", "", text)
    if not any(c.isascii() and c.isalnum() for c in s):
        return ""
    return "".join(c for c in s if ord(c) < 0x2E80).strip()


def format_crosspoint_filename(title: str, author: str, max_len: int = 220) -> str:
    """
    Formats the file as '{Title} - {Author}.epub'.
    Trims from the middle if title is too long so volume numbers at the end are never lost.
    """
    clean_title = sanitize_ascii_text(title) or title
    clean_author = sanitize_ascii_text(author) or "Author"

    clean_title = re.sub(r'[\\/*?:"<>|]', "", clean_title).strip()
    clean_author = re.sub(r'[\\/*?:"<>|]', "", clean_author).strip()

    name = f"{clean_title} - {clean_author}.epub"
    if len(name) > max_len:
        # Preserve start and ending volume number
        name = clean_title[:max_len - 40] + "..." + clean_title[-20:] + f" - {clean_author}.epub"
    return name
