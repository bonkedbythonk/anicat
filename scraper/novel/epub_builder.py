"""CrossPoint-Grade EPUB3 Packaging Engine for Light Novels & E-Ink Devices."""

import html
import io
import os
import re
import uuid
from typing import List, Optional, Tuple, Dict, Set, Any
import requests
from bs4 import BeautifulSoup
import ebooklib
from ebooklib import epub

from .models import Novel, Chapter, SeriesInfo, BookInfo
from .image_engine import optimize_image_for_eink, split_landscape_double_spread, TARGET_WIDTH, TARGET_HEIGHT, JPEG_QUALITY
from .content_cleaner import clean_chapter_html
from .metadata_sanitizer import sanitize_ascii_text, format_crosspoint_filename


CSS_STYLES = """@charset "utf-8";

@namespace "http://www.w3.org/1999/xhtml";
@namespace epub "http://www.idpf.org/2007/ops";

html, body {
    margin: 0;
    padding: 0;
}

body {
    margin: 3% 4%;
    padding: 0;
    font-family: -apple-system, "Georgia", "Baskerville", "Palatino", serif;
    font-size: 1.0em;
    line-height: 1.75;
    text-align: justify;
    color: #000000;
    background-color: #ffffff;
}

h1, h2, h3, h4, h5, h6 {
    font-weight: bold;
    line-height: 1.3;
    text-align: center;
    margin: 1.2em 0 0.8em 0;
}

h1.chapter-title {
    font-size: 1.5em;
    padding-bottom: 0.3em;
    margin-top: 1.2em;
    margin-bottom: 1.0em;
    border-bottom: 1px solid #ccc;
}

p {
    margin: 0.4em 0;
    text-indent: 1.5em;
}

p.first-p, p.scene-start {
    text-indent: 0;
}

p.drop-cap::first-letter {
    font-size: 2.8em;
    float: left;
    line-height: 0.85;
    margin: 0.08em 0.12em 0 0;
    font-weight: bold;
    font-family: "Georgia", "Palatino", serif;
}

.scene-break {
    text-align: center;
    text-indent: 0 !important;
    margin: 1.5em auto;
    font-size: 1.0em;
    letter-spacing: 0.4em;
    color: #444;
}

.title-page {
    text-align: center;
    margin: 5% auto 3% auto;
    max-width: 95%;
}

.title-page h1 {
    font-size: 1.8em;
    margin-bottom: 0.3em;
    line-height: 1.2;
}

.title-page .author {
    font-size: 1.15em;
    font-style: italic;
    margin-bottom: 1.2em;
    color: #333;
}

.meta-box {
    text-align: left;
    margin: 1.2em auto;
    padding: 0.8em 1.2em;
    background-color: #f4f4f4;
    border: 1px solid #ddd;
    border-radius: 4px;
    font-size: 0.9em;
    line-height: 1.5;
}

.meta-box p {
    text-indent: 0;
    margin: 0.25em 0;
}

.description-box {
    margin: 1.5em auto;
    text-align: left;
    font-size: 0.92em;
    line-height: 1.6;
}

.description-box h3 {
    text-align: left;
    margin-bottom: 0.4em;
    font-size: 1.1em;
}

.description-box p {
    text-indent: 0;
    margin-bottom: 0.6em;
}

.illustration-page {
    text-align: center;
    margin: 1.0em auto;
    padding: 0;
}

.illustration-page img, img.illustration {
    display: block;
    max-width: 100%;
    max-height: 96vh;
    height: auto;
    width: auto;
    margin: 0.5em auto;
}
"""

IMAGE_PAGE_TEMPLATE = """<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
<head>
  <title>{title}</title>
  <style type="text/css">
    @page {{ margin: 0; padding: 0; }}
    html, body {{ margin: 0; padding: 0; width: 100%; height: 100%; text-align: center; background-color: #000; overflow: hidden; }}
    .img-wrap {{ margin: 0; padding: 0; width: 100%; height: 100%; display: flex; align-items: center; justify-content: center; }}
    img {{ max-width: 100%; max-height: 100%; width: auto; height: auto; margin: auto; display: block; object-fit: contain; }}
  </style>
</head>
<body>
  <div class="img-wrap">
    <img src="{img_src}" alt="{title}"/>
  </div>
</body>
</html>"""


def _download_image_with_session(url: str, session: requests.Session, timeout: int = 15) -> Optional[bytes]:
    """Download image bytes with fallback to .jpg if .jxl/.avif was provided."""
    clean_url = re.sub(r"\.(jxl|avif)$", ".jpg", url, flags=re.IGNORECASE)
    try:
        resp = session.get(clean_url, timeout=timeout)
        if resp.status_code == 200:
            return resp.content
    except Exception:
        pass

    if clean_url != url:
        try:
            resp = session.get(url, timeout=timeout)
            if resp.status_code == 200:
                return resp.content
        except Exception:
            pass
    return None


def _process_chapter_images(
    chapter_soup: BeautifulSoup,
    book: epub.EpubBook,
    session: requests.Session,
    downloaded_images: Dict[str, Any],
    image_counter: List[int],
    target_w: int = TARGET_WIDTH,
    target_h: int = TARGET_HEIGHT,
    grayscale: bool = True,
    quality: int = JPEG_QUALITY,
    split_spreads: bool = True
) -> BeautifulSoup:
    """Replace in-chapter images with CrossPoint optimized local paths."""
    for pic in chapter_soup.select("picture"):
        img = pic.select_one("img")
        img_src = None
        if img and (img.get("src") or img.get("data-src")):
            img_src = img.get("src") or img.get("data-src")
        else:
            for s in pic.select("source[srcset]"):
                s_url = s.get("srcset", "").split()[0]
                if ".jpg" in s_url.lower() or ".png" in s_url.lower() or ".webp" in s_url.lower():
                    img_src = s_url
                    break
            if not img_src:
                sources = pic.select("source[srcset]")
                if sources:
                    img_src = sources[0].get("srcset", "").split()[0]

        if img_src:
            new_img = chapter_soup.new_tag("img", src=img_src, alt="Illustration")
            pic.replace_with(new_img)
        else:
            pic.decompose()

    for img in chapter_soup.select("img"):
        src = img.get("src") or img.get("data-src")
        if not src:
            continue

        normalized_url = re.sub(r"\.(jxl|avif)$", ".jpg", src, flags=re.IGNORECASE)
        img_entry = downloaded_images.get(normalized_url) or downloaded_images.get(src)
        local_path = None

        if isinstance(img_entry, dict):
            local_path = img_entry.get("full")
        elif isinstance(img_entry, str):
            local_path = img_entry
        else:
            raw_bytes = _download_image_with_session(normalized_url, session)
            if raw_bytes:
                opt_res = optimize_image_for_eink(raw_bytes, target_w, target_h, grayscale, quality)
                if opt_res:
                    opt_bytes, w, h = opt_res
                    image_counter[0] += 1
                    img_filename = f"images/ill_{image_counter[0]:04d}.jpg"
                    book.add_item(epub.EpubItem(
                        uid=f"ill_{image_counter[0]:04d}",
                        file_name=img_filename,
                        media_type="image/jpeg",
                        content=opt_bytes
                    ))
                    entry = {"full": img_filename, "width": w, "height": h}
                    downloaded_images[normalized_url] = entry
                    downloaded_images[src] = entry
                    local_path = img_filename

        if local_path:
            img["src"] = local_path
            img["class"] = "illustration"
            for attr in ["srcset", "data-src", "th", "fetchpriority", "decoding", "loading", "height", "width", "style"]:
                if attr in img.attrs:
                    del img[attr]
            parent = img.parent
            if parent and parent.name != "div":
                container = chapter_soup.new_tag("div", attrs={"class": "illustration-page"})
                img.wrap(container)
        else:
            img.decompose()

    return chapter_soup


def build_novel_epub(
    novel: Novel,
    output_path: str,
    series_info: Optional[SeriesInfo] = None,
    volume_title: Optional[str] = None,
    target_width: int = TARGET_WIDTH,
    target_height: int = TARGET_HEIGHT,
    grayscale: bool = True,
    jpeg_quality: int = JPEG_QUALITY,
    split_spreads: bool = True
) -> str:
    """Compile a Novel into an official CrossPoint-Grade EPUB for E-Ink Devices."""
    book = epub.EpubBook()
    session = requests.Session()
    session.headers.update({
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
    })

    # 1. Metadata
    novel_id = f"urn:ranobedb:series:{series_info.id}" if series_info else str(uuid.uuid4())
    book.set_identifier(novel_id)

    full_title = novel.title
    if volume_title and volume_title not in full_title:
        full_title = f"{novel.title} - {volume_title}"
    book.set_title(full_title)

    lang = novel.language or (series_info.lang if series_info else "en")
    book.set_language(lang)

    # Clean English authors and staff
    raw_authors = series_info.authors if (series_info and series_info.authors) else ([novel.author] if novel.author and novel.author != "Unknown Author" else ["Unknown Author"])
    effective_authors = [sanitize_ascii_text(a) for a in raw_authors if sanitize_ascii_text(a)] or ["Author"]
    primary_author = effective_authors[0]

    for auth in effective_authors:
        book.add_author(auth)

    if series_info:
        for art in series_info.artists:
            clean_art = sanitize_ascii_text(art)
            if clean_art:
                book.add_author(clean_art, role="ill")
        if series_info.publishers:
            clean_pubs = [sanitize_ascii_text(p.name) for p in series_info.publishers if sanitize_ascii_text(p.name)]
            if clean_pubs:
                book.add_metadata("DC", "publisher", ", ".join(clean_pubs))

    if novel.description:
        book.add_metadata("DC", "description", novel.description)

    # 2. Add Stylesheet
    style_item = epub.EpubItem(
        uid="style_crosspoint",
        file_name="styles/stylesheet.css",
        media_type="text/css",
        content=CSS_STYLES.encode("utf-8")
    )
    book.add_item(style_item)

    spine_items = []
    toc_items = []
    downloaded_images: Dict[str, Any] = {}
    image_counter = [0]
    has_cover = False

    # 3. Process Cover Image
    cover_url = novel.cover_image_url
    if not cover_url and series_info:
        cover_url = series_info.primary_cover_url

    cover_bytes = novel.cover_image_bytes
    if not cover_bytes and cover_url:
        cover_bytes = _download_image_with_session(cover_url, session)

    if cover_bytes:
        opt_res = optimize_image_for_eink(cover_bytes, target_width, target_height, grayscale, jpeg_quality)
        if opt_res:
            opt_cover_bytes, _, _ = opt_res
            book.set_cover("images/cover.jpg", opt_cover_bytes)

            cover_html_content = IMAGE_PAGE_TEMPLATE.format(
                title=html.escape(full_title),
                img_src="images/cover.jpg"
            )
            cover_page = epub.EpubHtml(
                title="Cover",
                file_name="cover.xhtml",
                lang="en"
            )
            cover_page.content = cover_html_content.encode("utf-8")
            book.add_item(cover_page)
            spine_items.append(cover_page)
            has_cover = True

    # 4. Process Dedicated Color Inserts (Front Matter Artworks)
    insert_pages = []
    if series_info and series_info.books:
        matched_book = None
        if volume_title:
            for b in series_info.books:
                if b.title and b.title.lower() in volume_title.lower():
                    matched_book = b
                    break
        if not matched_book and len(series_info.books) > 0:
            matched_book = series_info.books[0]

        if matched_book and matched_book.image and matched_book.image.url and matched_book.image.url != cover_url:
            raw_insert = _download_image_with_session(matched_book.image.url, session)
            if raw_insert:
                if split_spreads:
                    split_res = split_landscape_double_spread(raw_insert, target_width, target_height, grayscale, jpeg_quality)
                else:
                    split_res = None

                if split_res:
                    l_bytes, r_bytes, _, _ = split_res
                    image_counter[0] += 1
                    l_filename = f"images/insert_{image_counter[0]:03d}_1.jpg"
                    book.add_item(epub.EpubItem(
                        uid=f"insert_img_{image_counter[0]}_1",
                        file_name=l_filename,
                        media_type="image/jpeg",
                        content=l_bytes
                    ))
                    r_filename = f"images/insert_{image_counter[0]:03d}_2.jpg"
                    book.add_item(epub.EpubItem(
                        uid=f"insert_img_{image_counter[0]}_2",
                        file_name=r_filename,
                        media_type="image/jpeg",
                        content=r_bytes
                    ))

                    for sub_idx, sub_file in enumerate([l_filename, r_filename], 1):
                        ins_page = epub.EpubHtml(
                            title=f"Color Illustration Part {sub_idx}",
                            file_name=f"insert_{image_counter[0]:03d}_{sub_idx}.xhtml",
                            lang="en"
                        )
                        ins_page.content = IMAGE_PAGE_TEMPLATE.format(
                            title="Color Illustration",
                            img_src=sub_file
                        ).encode("utf-8")
                        book.add_item(ins_page)
                        insert_pages.append(ins_page)
                else:
                    opt_res = optimize_image_for_eink(raw_insert, target_width, target_height, grayscale, jpeg_quality)
                    if opt_res:
                        opt_b, _, _ = opt_res
                        image_counter[0] += 1
                        ins_filename = f"images/insert_{image_counter[0]:03d}.jpg"
                        book.add_item(epub.EpubItem(
                            uid=f"insert_img_{image_counter[0]}",
                            file_name=ins_filename,
                            media_type="image/jpeg",
                            content=opt_b
                        ))
                        ins_page = epub.EpubHtml(
                            title="Color Illustration",
                            file_name=f"insert_{image_counter[0]:03d}.xhtml",
                            lang="en"
                        )
                        ins_page.content = IMAGE_PAGE_TEMPLATE.format(
                            title="Color Illustration",
                            img_src=ins_filename
                        ).encode("utf-8")
                        book.add_item(ins_page)
                        insert_pages.append(ins_page)

    # 5. Title Page (Clean English metadata box)
    clean_display_title = sanitize_ascii_text(full_title) or full_title
    clean_display_author = primary_author

    meta_parts = []
    if series_info and series_info.artists:
        arts = [sanitize_ascii_text(a) for a in series_info.artists if sanitize_ascii_text(a)]
        if arts:
            meta_parts.append(f"<p><strong>Illustration:</strong> {html.escape(', '.join(arts))}</p>")
    if series_info and series_info.translators:
        trs = [sanitize_ascii_text(t) for t in series_info.translators if sanitize_ascii_text(t)]
        if trs:
            meta_parts.append(f"<p><strong>Translation:</strong> {html.escape(', '.join(trs))}</p>")
    if series_info and series_info.publishers:
        pubs = [sanitize_ascii_text(p.name) for p in series_info.publishers if sanitize_ascii_text(p.name)]
        if pubs:
            meta_parts.append(f"<p><strong>Publisher:</strong> {html.escape(', '.join(pubs))}</p>")

    desc_html = ""
    if novel.description:
        desc_pars = "".join(f"<p>{html.escape(p.strip())}</p>" for p in novel.description.split("\n") if p.strip())
        desc_html = f"""<div class="description-box">
          <h3>Synopsis</h3>
          {desc_pars}
        </div>"""

    title_page_content = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
<head>
  <title>{html.escape(clean_display_title)}</title>
  <link rel="stylesheet" href="styles/stylesheet.css" type="text/css"/>
</head>
<body>
  <div class="title-page">
    <h1>{html.escape(clean_display_title)}</h1>
    <p class="author">By {html.escape(clean_display_author)}</p>
    {f'<div class="meta-box">{"".join(meta_parts)}</div>' if meta_parts else ''}
    {desc_html}
  </div>
</body>
</html>"""

    title_page = epub.EpubHtml(
        title="Title Page",
        file_name="title_page.xhtml",
        lang="en"
    )
    title_page.content = title_page_content.encode("utf-8")
    title_page.add_item(style_item)
    book.add_item(title_page)

    spine_items.append(title_page)
    for ins in insert_pages:
        spine_items.append(ins)

    # 6. Process Chapters
    for idx, chapter in enumerate(novel.chapters, start=1):
        ch_title = chapter.title or f"Chapter {idx}"
        clean_title = sanitize_ascii_text(ch_title) or ch_title
        raw_html = chapter.content_html or "<p></p>"

        # Parse & clean chapter DOM
        cleaned_body = clean_chapter_html(raw_html, ch_title)

        ch_soup = BeautifulSoup(cleaned_body, "html.parser")
        ch_soup = _process_chapter_images(
            ch_soup, book, session, downloaded_images, image_counter,
            target_width, target_height, grayscale, jpeg_quality, split_spreads
        )

        final_chapter_html = f"""<?xml version="1.0" encoding="utf-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" lang="en" xml:lang="en">
<head>
  <title>{html.escape(clean_title)}</title>
  <link rel="stylesheet" href="styles/stylesheet.css" type="text/css"/>
</head>
<body>
  <h1 class="chapter-title">{html.escape(clean_title)}</h1>
  {str(ch_soup)}
</body>
</html>"""

        ch_item = epub.EpubHtml(
            title=clean_title,
            file_name=f"chapter_{idx:04d}.xhtml",
            lang="en"
        )
        ch_item.content = final_chapter_html.encode("utf-8")
        ch_item.add_item(style_item)
        book.add_item(ch_item)

        spine_items.append(ch_item)
        toc_items.append(ch_item)

    # 7. Navigation & Spine Setup
    book.toc = toc_items
    book.add_item(epub.EpubNcx())
    book.add_item(epub.EpubNav())

    # Build Spine (Cover -> Title Page -> Dedicated Inserts -> Narrative Chapters)
    book.spine = spine_items

    # 8. Determine Clean Filename & Save
    if os.path.isdir(output_path):
        filename = format_crosspoint_filename(clean_display_title, clean_display_author)
        final_file_path = os.path.join(output_path, filename)
    else:
        final_file_path = output_path

    os.makedirs(os.path.dirname(os.path.abspath(final_file_path)), exist_ok=True)
    epub.write_epub(final_file_path, book)
    return final_file_path
