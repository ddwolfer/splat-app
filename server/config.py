"""Server settings. Every value can be overridden with an environment variable of the same name."""

from __future__ import annotations

import ipaddress
import os
from dataclasses import dataclass, field
from pathlib import Path

SERVER_DIR = Path(__file__).resolve().parent


def _int(name: str, default: int) -> int:
    return int(os.environ.get(name, default))


def _float(name: str, default: float) -> float:
    return float(os.environ.get(name, default))


def _nets(name: str) -> list[ipaddress.IPv4Network | ipaddress.IPv6Network]:
    raw = os.environ.get(name, "").strip()
    return [ipaddress.ip_network(part.strip(), strict=False) for part in raw.split(",") if part.strip()]


@dataclass
class Settings:
    splat_dir: Path = field(default_factory=lambda: Path(os.environ.get("SPLAT_DIR", SERVER_DIR / "splats")))
    # Input limits
    max_upload_bytes: int = field(default_factory=lambda: _int("MAX_UPLOAD_BYTES", 20 * 1024 * 1024))
    max_json_bytes: int = field(default_factory=lambda: _int("MAX_JSON_BYTES", 4096))
    max_pixels: int = field(default_factory=lambda: _int("MAX_PIXELS", 40_000_000))
    max_side: int = field(default_factory=lambda: _int("MAX_SIDE", 2048))
    body_read_timeout: float = field(default_factory=lambda: _float("BODY_READ_TIMEOUT", 30.0))
    # Download limits
    download_total_timeout: float = field(default_factory=lambda: _float("DOWNLOAD_TOTAL_TIMEOUT", 20.0))
    download_op_timeout: float = field(default_factory=lambda: _float("DOWNLOAD_OP_TIMEOUT", 5.0))
    max_redirects: int = field(default_factory=lambda: _int("MAX_REDIRECTS", 3))
    allowed_private_nets: list = field(default_factory=lambda: _nets("ALLOWED_PRIVATE_NETS"))
    # Concurrency / storage
    max_inflight: int = field(default_factory=lambda: _int("MAX_INFLIGHT", 3))  # 1 running + 2 waiting
    max_splats: int = field(default_factory=lambda: _int("MAX_SPLATS", 40))
    min_free_bytes: int = field(default_factory=lambda: _int("MIN_FREE_BYTES", 2 * 1024**3))
    # Model
    amp: str = field(default_factory=lambda: os.environ.get("SHARP_AMP", "fp16"))
