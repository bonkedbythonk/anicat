"""Unit tests for novel engine: image optimizer, cleaner, metadata sanitizer, and epub generation."""

import os
import io
import pytest
from PIL import Image

from novel.image_engine import optimize_image_for_eink, split_landscape_double_spread
from novel.content_cleaner import clean_chapter_html
from novel.metadata_sanitizer import sanitize_ascii_text, format_crosspoint_filename
from novel.models import Novel, Chapter, SeriesInfo, BookInfo
from novel.epub_builder import build_novel_epub


def test_metadata_sanitizer():
    raw = "Riku Misora (海空りく) [Author]"
    sanitized = sanitize_ascii_text(raw)
    assert "海空りく" not in sanitized
    assert "Riku Misora" in sanitized

    title = 'Re:Zero - Starting Life in Another World/Volume 1: "The Beast"'
    author = "Tappei Nagatsuki (長月達平)"
    filename = format_crosspoint_filename(title, author)
    assert filename.endswith(".epub")
    assert "/" not in filename
    assert ":" not in filename
    assert '"' not in filename
    assert "Tappei Nagatsuki" in filename


def test_content_cleaner():
    html_raw = """
    <div class="chapter-content">
        <h1>Prologue: The Awakening</h1>
        <script>alert('bad');</script>
        <p>The dawn broke over the kingdom.</p>
        <p>* * *</p>
        <p>A second scene began.</p>
        <p></p>
    </div>
    """
    cleaned = clean_chapter_html(html_raw, "Prologue: The Awakening")
    assert "<script" not in cleaned
    assert "The dawn broke" in cleaned
    assert "❖ ❖ ❖" in cleaned
    assert 'class="scene-break"' in cleaned
    assert "drop-cap" in cleaned


def test_image_engine_grayscale_and_resizing():
    # Create test RGB image
    img = Image.new("RGB", (1000, 1500), color=(255, 128, 64))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    raw_bytes = buf.getvalue()

    res = optimize_image_for_eink(raw_bytes, target_w=528, target_h=792, grayscale=True, quality=85)
    assert res is not None
    opt_bytes, w, h = res
    assert w <= 528
    assert h <= 792

    # Check mode of output image
    out_img = Image.open(io.BytesIO(opt_bytes))
    assert out_img.mode == "L"


def test_image_engine_split_landscape_spread():
    # Create test landscape image (width > height * 1.15)
    img = Image.new("RGB", (1600, 900), color=(100, 150, 200))
    buf = io.BytesIO()
    img.save(buf, format="JPEG")
    raw_bytes = buf.getvalue()

    split_res = split_landscape_double_spread(raw_bytes, target_w=528, target_h=792, grayscale=True, quality=85)
    assert split_res is not None
    l_bytes, r_bytes, w, h = split_res
    assert w <= 528
    assert h <= 792
    assert len(l_bytes) > 0
    assert len(r_bytes) > 0


def test_epub_builder_minimal(tmp_path):
    novel = Novel(
        title="Test Light Novel",
        author="Test Author",
        description="A test light novel for CrossPoint verification.",
        source_url="https://example.com/novel/1",
        chapters=[
            Chapter(
                index=1,
                title="Chapter 1: The Beginning",
                url="https://example.com/novel/1/c1",
                content_html="<p>It was a dark and stormy night.</p><p>* * *</p><p>Then the sun rose.</p>"
            )
        ]
    )

    out_file = str(tmp_path / "Test Novel.epub")
    built_path = build_novel_epub(
        novel=novel,
        output_path=out_file,
        target_width=528,
        target_height=792,
        grayscale=True,
        jpeg_quality=85
    )

    assert os.path.exists(built_path)
    assert os.path.getsize(built_path) > 500
