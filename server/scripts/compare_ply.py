"""Compare per-gaussian outputs of SHARP .ply files against a reference (e.g. fp32 vs fp16).

Usage: $PY server/scripts/compare_ply.py <reference.ply> <candidate.ply> [...]

Gaussians are compared index-by-index (SHARP emits a fixed grid, so order is identical).
Metrics (median / p99 over gaussians):
  xyz_rel   : |dxyz| / z_ref                           (relative position error)
  scale_rel : |exp(s_cand) - exp(s_ref)| / exp(s_ref)  (per axis)
  f_dc      : |df_dc|                                  (SH DC coefficients, sRGB)
  opacity   : |sigmoid(o_cand) - sigmoid(o_ref)|
  rot_deg   : angle between quaternions in degrees (sign-invariant; noisy for near-isotropic gaussians)
  cov_rel   : ||Sigma_cand - Sigma_ref||_F / ||Sigma_ref||_F with Sigma = R diag(s^2) R^T
              (shape error independent of the quaternion ambiguity); also opacity-weighted mean
"""

from __future__ import annotations

import sys

import numpy as np
from plyfile import PlyData


def load(path: str) -> dict[str, np.ndarray]:
    v = PlyData.read(path)["vertex"].data
    return {name: np.asarray(v[name], dtype=np.float64) for name in v.dtype.names}


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1 / (1 + np.exp(-x))


def covariance(d: dict[str, np.ndarray]) -> np.ndarray:
    q = np.stack([d[f"rot_{i}"] for i in range(4)], 1)
    q /= np.linalg.norm(q, axis=1, keepdims=True)
    w, x, y, z = q.T
    rot = np.stack([
        1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y),
        2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x),
        2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y),
    ], 1).reshape(-1, 3, 3)
    s = np.exp(np.stack([d[f"scale_{i}"] for i in range(3)], 1))
    return np.einsum("nij,nj,nkj->nik", rot, s**2, rot)


def stats(x: np.ndarray) -> str:
    return f"median {np.median(x):.2e}  p99 {np.percentile(x, 99):.2e}"


def main() -> int:
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    ref = load(sys.argv[1])
    for path in sys.argv[2:]:
        c = load(path)
        if len(c["x"]) != len(ref["x"]):
            print(f"{path}: vertex count differs ({len(c['x'])} vs {len(ref['x'])})")
            continue
        dxyz = np.sqrt(sum((c[k] - ref[k]) ** 2 for k in "xyz"))
        xyz_rel = dxyz / ref["z"]
        scale_rel = np.concatenate([
            np.abs(np.exp(c[f"scale_{i}"]) - np.exp(ref[f"scale_{i}"])) / np.exp(ref[f"scale_{i}"])
            for i in range(3)
        ])
        f_dc = np.concatenate([np.abs(c[f"f_dc_{i}"] - ref[f"f_dc_{i}"]) for i in range(3)])
        opacity = np.abs(sigmoid(c["opacity"]) - sigmoid(ref["opacity"]))
        q_ref = np.stack([ref[f"rot_{i}"] for i in range(4)], 1)
        q_c = np.stack([c[f"rot_{i}"] for i in range(4)], 1)
        q_ref /= np.linalg.norm(q_ref, axis=1, keepdims=True)
        q_c /= np.linalg.norm(q_c, axis=1, keepdims=True)
        dot = np.clip(np.abs((q_ref * q_c).sum(1)), 0, 1)
        rot_deg = np.degrees(2 * np.arccos(dot))
        cov_ref = covariance(ref).reshape(-1, 9)
        cov_rel = np.linalg.norm(covariance(c).reshape(-1, 9) - cov_ref, axis=1) / np.linalg.norm(cov_ref, axis=1)
        w = sigmoid(ref["opacity"])
        print(path)
        print(f"  xyz_rel  : {stats(xyz_rel)}")
        print(f"  scale_rel: {stats(scale_rel)}")
        print(f"  f_dc     : {stats(f_dc)}")
        print(f"  opacity  : {stats(opacity)}")
        print(f"  rot_deg  : {stats(rot_deg)}")
        print(f"  cov_rel  : {stats(cov_rel)}  opacity-weighted mean {(cov_rel * w).sum() / w.sum():.2e}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
