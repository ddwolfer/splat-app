from io import BytesIO

import numpy as np
import pytest
from PIL import Image

from conftest import jpeg_bytes
from imaging import ImageError, convert_focallength, decode_image

MAXP, MAXSIDE = 40_000_000, 2048


def png(img: Image.Image, **kw) -> bytes:
    buf = BytesIO()
    img.save(buf, "PNG", **kw)
    return buf.getvalue()


def exif_with(**tags) -> Image.Exif:
    exif = Image.Exif()
    for tag, value in tags.items():
        if tag == "Orientation":
            exif[0x0112] = value
        else:
            exif.get_ifd(0x8769)[{"FocalLengthIn35mmFilm": 0xA405, "FocalLength": 0x920A}[tag]] = value
    return exif


def test_rgb_jpeg_default_focal():
    d = decode_image(jpeg_bytes((64, 48)), MAXP, MAXSIDE)
    assert d.rgb.shape == (48, 64, 3) and d.rgb.dtype == np.uint8
    assert not d.focal_from_exif and d.f_35mm == 30.0
    assert d.f_px == pytest.approx(convert_focallength(64, 48, 30.0))


def test_focal_from_exif_35mm():
    d = decode_image(jpeg_bytes((64, 48), exif=exif_with(FocalLengthIn35mmFilm=26)), MAXP, MAXSIDE)
    assert d.focal_from_exif and d.f_35mm == 26


def test_small_focal_length_is_scaled_like_ml_sharp():
    d = decode_image(jpeg_bytes((64, 48), exif=exif_with(FocalLength=5.0)), MAXP, MAXSIDE)
    assert d.f_35mm == pytest.approx(42.0)


@pytest.mark.parametrize("orientation, shape", [(1, (48, 64)), (2, (48, 64)), (6, (64, 48)), (8, (64, 48)), (5, (64, 48))])
def test_exif_orientation_including_mirrored(orientation, shape):
    img = Image.new("RGB", (64, 48))
    img.paste((255, 0, 0), (0, 0, 8, 8))  # marker in the top-left corner
    buf = BytesIO()
    img.save(buf, "JPEG", exif=exif_with(Orientation=orientation), quality=95)
    d = decode_image(buf.getvalue(), MAXP, MAXSIDE)
    assert d.rgb.shape[:2] == shape
    if orientation == 2:  # horizontal mirror: marker moves to the top-right
        assert d.rgb[2, -3, 0] > 200 and d.rgb[2, 2, 0] < 60


@pytest.mark.parametrize("mode", ["P", "L", "LA", "RGBA", "I;16", "1"])
def test_color_modes_become_rgb(mode):
    base = Image.new("RGB", (40, 30), (10, 200, 30))
    if mode == "I;16":
        img = Image.fromarray(np.full((30, 40), 40000, dtype=np.uint16))  # -> mode "I;16"
    else:
        img = base.convert(mode)
    d = decode_image(png(img), MAXP, MAXSIDE)
    assert d.rgb.shape == (30, 40, 3) and d.rgb.dtype == np.uint8


def test_cmyk_jpeg():
    buf = BytesIO()
    Image.new("CMYK", (40, 30), (0, 255, 255, 0)).save(buf, "JPEG")
    d = decode_image(buf.getvalue(), MAXP, MAXSIDE)
    assert d.rgb.shape == (30, 40, 3)


def test_transparent_pixels_composited_on_white():
    img = Image.new("RGBA", (10, 10), (0, 0, 0, 0))
    d = decode_image(png(img), MAXP, MAXSIDE)
    assert (d.rgb == 255).all()


def test_downscale_and_focal_uses_resized_size():
    d = decode_image(jpeg_bytes((3000, 1500)), MAXP, 1000)
    assert d.rgb.shape == (500, 1000, 3)
    assert d.original_size == (3000, 1500)
    assert d.f_px == pytest.approx(convert_focallength(1000, 500, 30.0))


def test_pixel_limit_checked_before_decode():
    data = png(Image.new("L", (8000, 6000)))  # 48MP but tiny file
    with pytest.raises(ImageError) as e:
        decode_image(data, MAXP, MAXSIDE)
    assert e.value.status == 413


@pytest.mark.parametrize("data", [b"", b"not an image", b"\x89PNG\r\n\x1a\n" + b"\0" * 50, jpeg_bytes()[:100]])
def test_garbage_rejected(data):
    with pytest.raises(ImageError) as e:
        decode_image(data, MAXP, MAXSIDE)
    assert e.value.status == 400


def test_heic_roundtrip():
    pillow_heif = pytest.importorskip("pillow_heif")
    buf = BytesIO()
    try:
        Image.new("RGB", (64, 48), (1, 2, 3)).save(buf, "HEIF")
    except Exception as exc:  # encoder may be unavailable on some builds
        pytest.skip(f"HEIF encoder unavailable: {exc}")
    d = decode_image(buf.getvalue(), MAXP, MAXSIDE)
    assert d.rgb.shape == (48, 64, 3)
    assert pillow_heif  # registered opener in use
