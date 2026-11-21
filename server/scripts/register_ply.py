"""Register an existing .ply (e.g. an offline fp32 benchmark output) so the server serves it.

Usage: $PY server/scripts/register_ply.py <file.ply> --source "sample:teaser fp32" [--amp none]
Prints the new id; the file is then available at /splats/<id>.ply and listed in /list.
Note: registered files count toward MAX_SPLATS and are evicted like any other splat.
"""

from __future__ import annotations

import argparse
import shutil
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from config import Settings  # noqa: E402
from storage import SplatStore  # noqa: E402


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ply", type=Path)
    ap.add_argument("--source", required=True)
    ap.add_argument("--amp", default="unknown")
    args = ap.parse_args()
    from plyfile import PlyData

    ply = PlyData.read(str(args.ply))
    w, h = (int(v[0]) for v in ply["image_size"].data[:2]) if "image_size" in ply else (0, 0)
    s = Settings()
    store = SplatStore(s.splat_dir, s.max_splats, s.min_free_bytes)
    splat_id = str(uuid.uuid4())
    shutil.copyfile(args.ply, store.tmp_ply_path(splat_id))
    store.publish(splat_id, {
        "id": splat_id,
        "ply_url": f"/splats/{splat_id}.ply",
        "seconds": 0.0,
        "created": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "source": args.source,
        "width": w,
        "height": h,
        "amp": args.amp,
    })
    print(splat_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
