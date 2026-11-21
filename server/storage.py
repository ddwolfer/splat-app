"""On-disk splat store: <id>.ply + <id>.json, where the JSON sidecar is the completion marker."""

from __future__ import annotations

import json
import logging
import os
import shutil
import time
import uuid
from pathlib import Path

LOGGER = logging.getLogger("splat.storage")

# A .ply without its .json is only treated as an orphan once it is this old, so a publish that is
# between its two renames (in this process or in scripts/register_ply.py) is never deleted.
ORPHAN_MIN_AGE_S = 600


def parse_id(text: str) -> str | None:
    """Return the canonical UUID string, or None if `text` is not a UUID (blocks path traversal)."""
    try:
        return str(uuid.UUID(text))
    except (ValueError, AttributeError, TypeError):
        return None


class SplatStore:
    def __init__(self, root: Path, max_splats: int, min_free_bytes: int):
        self.root = root
        self.max_splats = max_splats
        self.min_free_bytes = min_free_bytes
        self.root.mkdir(parents=True, exist_ok=True)

    # ---- paths -------------------------------------------------------------------------------
    def ply_path(self, splat_id: str) -> Path:
        return self.root / f"{splat_id}.ply"

    def meta_path(self, splat_id: str) -> Path:
        return self.root / f"{splat_id}.json"

    def tmp_ply_path(self, splat_id: str) -> Path:
        return self.root / f"{splat_id}.ply.tmp"

    # ---- lifecycle ---------------------------------------------------------------------------
    def cleanup_orphans(self) -> None:
        """Remove leftovers from crashed / interrupted generations."""
        for p in self.root.glob("*.tmp"):
            self._unlink(p)
        for ply in self.root.glob("*.ply"):
            if not self.meta_path(ply.stem).exists():
                self._unlink(ply)

    def check_free_space(self) -> bool:
        return shutil.disk_usage(self.root).free >= self.min_free_bytes

    def publish(self, splat_id: str, meta: dict) -> None:
        """Move the finished temp PLY into place, then atomically write the sidecar (= complete)."""
        os.replace(self.tmp_ply_path(splat_id), self.ply_path(splat_id))
        meta_tmp = self.root / f"{splat_id}.json.tmp"
        meta_tmp.write_text(json.dumps(meta, ensure_ascii=False), encoding="utf-8")
        os.replace(meta_tmp, self.meta_path(splat_id))

    def discard(self, splat_id: str) -> None:
        for p in (self.tmp_ply_path(splat_id), self.root / f"{splat_id}.json.tmp"):
            self._unlink(p)

    def open_ply(self, splat_id: str):
        """Open a published PLY for reading, or return None (missing, unpublished or evicted)."""
        if not self.meta_path(splat_id).exists():
            return None
        try:
            return open(self.ply_path(splat_id), "rb")
        except OSError:
            return None

    def list(self) -> list[dict]:
        items = []
        for meta_file in self.root.glob("*.json"):
            if parse_id(meta_file.stem) is None:
                continue
            try:
                meta = json.loads(meta_file.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            try:
                meta["size_bytes"] = self.ply_path(meta_file.stem).stat().st_size
            except OSError:  # evicted or not yet published
                continue
            items.append(meta)
        items.sort(key=lambda m: m.get("created", ""), reverse=True)
        return items

    def evict(self) -> None:
        """Keep only the newest `max_splats`. Files that cannot be deleted now are retried later."""
        # Leftovers from earlier failed deletes (e.g. the PLY was being downloaded at the time).
        now = time.time()
        for ply in self.root.glob("*.ply"):
            if self.meta_path(ply.stem).exists():
                continue
            try:
                old = now - ply.stat().st_mtime > ORPHAN_MIN_AGE_S
            except OSError:
                continue
            if old:
                self._unlink(ply)
        items = self.list()
        for meta in items[self.max_splats:]:
            splat_id = meta.get("id")
            if not splat_id or parse_id(splat_id) is None:
                continue
            # Remove the marker first so the splat disappears from the API even if the PLY is busy.
            self._unlink(self.meta_path(splat_id))
            self._unlink(self.ply_path(splat_id))

    @staticmethod
    def _unlink(path: Path) -> None:
        try:
            path.unlink(missing_ok=True)
        except OSError as exc:  # e.g. Windows: file is being downloaded right now
            LOGGER.warning("could not delete %s: %s", path.name, exc)
