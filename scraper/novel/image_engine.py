"""CrossPoint-Grade Image Engine: E-ink resizing, true-grayscale, and landscape spread auto-splitter."""

import io
from typing import Optional, Tuple
from PIL import Image

TARGET_WIDTH = 528
TARGET_HEIGHT = 792
JPEG_QUALITY = 85


def optimize_image_for_eink(
    image_bytes: bytes,
    target_w: int = TARGET_WIDTH,
    target_h: int = TARGET_HEIGHT,
    grayscale: bool = True,
    quality: int = JPEG_QUALITY
) -> Optional[Tuple[bytes, int, int]]:
    """
    1. Converts image to 8-bit True-Grayscale (Mode 'L') or RGB.
    2. Resizes preserving aspect ratio to fit within target screen dimensions.
    3. Encodes as optimized baseline JPEG.
    """
    try:
        img = Image.open(io.BytesIO(image_bytes))

        if grayscale and img.mode != "L":
            img = img.convert("L")
        elif not grayscale and img.mode not in ("RGB", "L"):
            img = img.convert("RGB")

        # Downscale if exceeding target screen bounds using high-quality Lanczos resampling
        img.thumbnail((target_w, target_h), Image.Resampling.LANCZOS)

        out_io = io.BytesIO()
        img.save(out_io, format="JPEG", quality=quality, optimize=True)
        return out_io.getvalue(), img.width, img.height
    except Exception:
        return None


def split_landscape_double_spread(
    image_bytes: bytes,
    target_w: int = TARGET_WIDTH,
    target_h: int = TARGET_HEIGHT,
    grayscale: bool = True,
    quality: int = JPEG_QUALITY
) -> Optional[Tuple[bytes, bytes, int, int]]:
    """
    If an illustration is a landscape double-page spread (width > height * 1.15):
    - Cuts the image down the center into Left and Right portrait halves.
    - Scales each half independently to fit the target screen.
    Returns (left_bytes, right_bytes, half_width, half_height).
    """
    try:
        img = Image.open(io.BytesIO(image_bytes))
        if grayscale and img.mode != "L":
            img = img.convert("L")
        elif not grayscale and img.mode not in ("RGB", "L"):
            img = img.convert("RGB")

        if img.width > img.height * 1.15:
            w, h = img.size
            mid = w // 2
            left_crop = img.crop((0, 0, mid, h))
            right_crop = img.crop((mid, 0, w, h))

            left_crop.thumbnail((target_w, target_h), Image.Resampling.LANCZOS)
            right_crop.thumbnail((target_w, target_h), Image.Resampling.LANCZOS)

            out_l = io.BytesIO()
            left_crop.save(out_l, format="JPEG", quality=quality, optimize=True)

            out_r = io.BytesIO()
            right_crop.save(out_r, format="JPEG", quality=quality, optimize=True)

            return out_l.getvalue(), out_r.getvalue(), left_crop.width, left_crop.height
    except Exception:
        pass
    return None
