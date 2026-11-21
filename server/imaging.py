"""Decode untrusted image bytes into an RGB uint8 array plus a focal length in pixels.

We do not use ml-sharp's `io.load_rgb` for untrusted input: it picks the decoder by file
extension, ignores mirrored EXIF orientations, slices channels without converting palette/CMYK
images, and (on import) raises Pillow's pixel limit to 200MP. The focal-length rules below are
copied from `load_rgb` so results match the official CLI.
"""

from __future__ import annotations

import io
import math
import warnings
from dataclasses import dataclass

import numpy as np
import pillow_heif
from PIL import ExifTags, Image, ImageOps, TiffTags

pillow_heif.register_heif_opener()

DEFAULT_F_35MM = 30.0


class ImageError(Exception):
    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


@dataclass
class DecodedImage:
    rgb: np.ndarray  # HxWx3 uint8
    f_px: float
    original_size: tuple[int, int]  # (w, h) after EXIF transpose, before resize
    f_35mm: float
    focal_from_exif: bool


def _exif_dict(img: Image.Image) -> dict:
    exif = img.getexif()
    sub = exif.get_ifd(0x8769)
    out = {ExifTags.TAGS[k]: v for k, v in sub.items() if k in ExifTags.TAGS}
    out.update({TiffTags.TAGS_V2[k].name: v for k, v in exif.items() if k in TiffTags.TAGS_V2})
    return out


def _focal_35mm(exif: dict) -> tuple[float, bool]:
    """Same rules as ml-sharp io.load_rgb."""
    f = exif.get("FocalLengthIn35mmFilm", exif.get("FocalLenIn35mmFilm"))
    try:
        f = float(f) if f is not None else None
    except (TypeError, ValueError):
        f = None
    if f is None or f < 1:
        f = exif.get("FocalLength")
        try:
            f = float(f) if f is not None else None
        except (TypeError, ValueError, ZeroDivisionError):
            f = None
        if f is None or not math.isfinite(f) or f <= 0:
            return DEFAULT_F_35MM, False
        if f < 10.0:
            f *= 8.4  # crude phone-sensor crop factor, as in ml-sharp
    if not math.isfinite(f) or f <= 0:
        return DEFAULT_F_35MM, False
    return f, True


def convert_focallength(width: float, height: float, f_mm: float) -> float:
    """ml-sharp io.convert_focallength: 35mm-equivalent focal length -> pixels (diagonal based)."""
    return f_mm * math.sqrt(width**2 + height**2) / math.sqrt(36**2 + 24**2)


def decode_image(data: bytes, max_pixels: int, max_side: int) -> DecodedImage:
    if not data:
        raise ImageError("empty image")
    try:
        with warnings.catch_warnings():
            warnings.simplefilter("error", Image.DecompressionBombWarning)
            img = Image.open(io.BytesIO(data))
            w, h = img.size  # header only, nothing decoded yet
            if w <= 0 or h <= 0:
                raise ImageError("invalid image dimensions")
            if w * h > max_pixels:
                raise ImageError(f"image too large: {w}x{h} exceeds {max_pixels} pixels", 413)
            exif = _exif_dict(img)
            img = ImageOps.exif_transpose(img)  # handles all 8 orientations incl. mirrored
            if img.mode not in ("RGB",):
                if img.mode in ("I;16", "I;16B", "I;16L", "I"):
                    # 16/32-bit grayscale: scale to 8-bit before RGB conversion
                    arr = np.asarray(img, dtype=np.float64)
                    peak = arr.max() or 1.0
                    img = Image.fromarray((arr / peak * 255).astype(np.uint8))  # 2-D uint8 -> mode "L"
                if img.mode in ("RGBA", "LA", "PA") or (img.mode == "P" and "transparency" in img.info):
                    img = img.convert("RGBA")
                    background = Image.new("RGBA", img.size, (255, 255, 255, 255))
                    img = Image.alpha_composite(background, img)
                img = img.convert("RGB")
            img.load()
    except ImageError:
        raise
    except (Image.DecompressionBombError, Image.DecompressionBombWarning) as exc:
        raise ImageError("image too large (decompression bomb)", 413) from exc
    except Exception as exc:  # noqa: BLE001 - any decoder failure means "not a usable image"
        raise ImageError(f"cannot decode image: {type(exc).__name__}") from exc

    original_size = img.size
    scale = min(1.0, max_side / max(img.size))
    if scale < 1.0:
        new_size = (max(1, round(img.width * scale)), max(1, round(img.height * scale)))
        img = img.resize(new_size, Image.Resampling.LANCZOS)

    f_35mm, from_exif = _focal_35mm(exif)
    f_px = convert_focallength(img.width, img.height, f_35mm)
    if not math.isfinite(f_px) or f_px <= 0:
        raise ImageError("invalid focal length")

    rgb = np.asarray(img, dtype=np.uint8)
    if rgb.ndim != 3 or rgb.shape[2] != 3:
        raise ImageError("unexpected image layout")
    return DecodedImage(rgb=np.ascontiguousarray(rgb), f_px=f_px, original_size=original_size,
                        f_35mm=f_35mm, focal_from_exif=from_exif)
