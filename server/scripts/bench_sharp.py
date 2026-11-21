"""M1 benchmark: load SHARP once, run inference N times on CUDA, report timings and VRAM.

Usage (Git Bash):
    PYTHONNOUSERSITE=1 /c/Users/91006/anaconda3/envs/sharp/python.exe server/scripts/bench_sharp.py \
        -i server/third_party/ml-sharp/data/teaser.jpg -o server/splats/m1 -n 3

Uses ml-sharp's own load_rgb / save_ply, and server/sharp_runner.predict (a mirror of the official
predict_image with optional mixed precision on the network forward only).
"""

from __future__ import annotations

import argparse
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch
from plyfile import PlyData

from sharp.utils import io
from sharp.utils.gaussians import save_ply

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from sharp_runner import DEFAULT_AMP, load_model, predict  # noqa: E402

MB = 1024**2
REQUIRED_FIELDS = ["x", "y", "z", "f_dc_0", "f_dc_1", "f_dc_2", "opacity",
                   "scale_0", "scale_1", "scale_2", "rot_0", "rot_1", "rot_2", "rot_3"]
REQUIRED_ELEMENTS = ["vertex", "extrinsic", "intrinsic", "image_size", "frame", "disparity",
                     "color_space", "version"]


def positive_int(text: str) -> int:
    value = int(text)
    if value < 1:
        raise argparse.ArgumentTypeError("must be >= 1")
    return value


def sync() -> None:
    torch.cuda.synchronize()


def nvidia_smi_used_mb() -> str:
    try:
        out = subprocess.run(
            ["nvidia-smi", "--query-gpu=memory.used,memory.total", "--format=csv,noheader,nounits"],
            capture_output=True, text=True, timeout=10,
        )
        return out.stdout.strip()
    except Exception as exc:  # noqa: BLE001
        return f"n/a ({exc})"


def check_ply(path: Path) -> dict:
    ply = PlyData.read(str(path))
    v = ply["vertex"].data
    fields = list(v.dtype.names)
    arr = np.stack([v[f] for f in fields], axis=1).astype(np.float64)
    xyz = arr[:, :3]
    finite = bool(np.isfinite(arr).all())
    idx = {f: i for i, f in enumerate(fields)}
    scales = np.exp(arr[:, [idx["scale_0"], idx["scale_1"], idx["scale_2"]]])
    opac = 1 / (1 + np.exp(-arr[:, idx["opacity"]]))
    quat = arr[:, [idx["rot_0"], idx["rot_1"], idx["rot_2"], idx["rot_3"]]]
    problems = []
    missing = [f for f in REQUIRED_FIELDS if f not in fields]
    if missing:
        problems.append(f"missing fields {missing}")
    if not finite:
        problems.append("non-finite values")
    if len(v) == 0:
        problems.append("no vertices")
    if not (scales > 0).all() or scales.max() > 1e3:
        problems.append(f"bad scales (max={scales.max():.3g})")
    qn = np.linalg.norm(quat, axis=1)
    if np.abs(qn - 1).max() > 1e-3:
        problems.append("quaternions not normalized")
    if (xyz[:, 2] <= 0).any():
        problems.append("points behind camera (z <= 0)")
    return {
        "problems": problems,
        "vertices": len(v),
        "fields": fields,
        "elements": [e.name for e in ply.elements],
        "all_finite": finite,
        "xyz_min": xyz.min(0).round(3).tolist(),
        "xyz_max": xyz.max(0).round(3).tolist(),
        "xyz_median": np.median(xyz, 0).round(3).tolist(),
        "scale_median": float(np.median(scales)),
        "opacity_mean": float(opac.mean()),
        "quat_norm_range": [float(qn.min()), float(qn.max())],
        "size_mb": round(path.stat().st_size / MB, 1),
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--image", type=Path, required=True)
    ap.add_argument("-o", "--out", type=Path, required=True)
    ap.add_argument("-n", "--runs", type=positive_int, default=3, help="measured runs (after 1 warm-up)")
    ap.add_argument("--amp", choices=["none", "fp16", "bf16"], default=DEFAULT_AMP,
                    help=f"autocast dtype for the network forward (default: {DEFAULT_AMP})")
    args = ap.parse_args()

    assert torch.cuda.is_available(), "CUDA not available"
    device = torch.device("cuda")
    print(f"python   : {sys.executable}")
    print(f"torch    : {torch.__version__} cuda={torch.version.cuda} gpu={torch.cuda.get_device_name(0)}")
    print(f"smi idle : {nvidia_smi_used_mb()} (used,total MiB)")
    print(f"amp      : {args.amp}")

    t0 = time.perf_counter()
    model = load_model(device)
    sync()
    print(f"load     : {time.perf_counter() - t0:.2f}s, allocated={torch.cuda.memory_allocated() / MB:.0f}MB")
    assert next(model.parameters()).device.type == "cuda"

    t0 = time.perf_counter()
    image, _, f_px = io.load_rgb(args.image)
    h, w = image.shape[:2]
    print(f"image    : {w}x{h}, f_px={f_px:.1f}, read {time.perf_counter() - t0:.2f}s")

    args.out.mkdir(parents=True, exist_ok=True)

    # Warm-up (cuDNN autotune, allocator growth); reported separately, not part of the stats.
    sync()
    t0 = time.perf_counter()
    gaussians = predict(model, image, f_px, device, amp=args.amp)
    sync()
    print(f"warm-up  : {time.perf_counter() - t0:.2f}s")

    times = []
    for i in range(args.runs):
        gaussians = None  # release previous output before measuring
        torch.cuda.reset_peak_memory_stats()
        sync()
        t0 = time.perf_counter()
        gaussians = predict(model, image, f_px, device, amp=args.amp)
        sync()
        dt = time.perf_counter() - t0
        times.append(dt)
        assert gaussians.mean_vectors.device.type == "cuda"
        print(
            f"run {i + 1}    : {dt:.2f}s, peak allocated={torch.cuda.max_memory_allocated() / MB:.0f}MB, "
            f"peak reserved={torch.cuda.max_memory_reserved() / MB:.0f}MB, smi-after={nvidia_smi_used_mb()}"
        )
    print(f"steady   : mean {np.mean(times):.2f}s, min {np.min(times):.2f}s over {len(times)} runs")

    suffix = "" if args.amp == "none" else f"_{args.amp}"
    out_path = args.out / f"{args.image.stem}_bench{suffix}.ply"
    t0 = time.perf_counter()
    save_ply(gaussians, f_px, (h, w), out_path)
    print(f"save     : {time.perf_counter() - t0:.2f}s -> {out_path}")

    report = check_ply(out_path)
    for k, v in report.items():
        print(f"ply.{k:<16}: {v}")
    missing_el = [e for e in REQUIRED_ELEMENTS if e not in report["elements"]]
    if missing_el:
        report["problems"].append(f"missing elements {missing_el}")
    if report["problems"]:
        print(f"FAIL: {report['problems']}")
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
