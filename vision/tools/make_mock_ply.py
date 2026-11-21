#!/usr/bin/env python3
"""Generate a mock SHARP-style Gaussian splat PLY (stdlib only, deterministic).

The file mimics apple/ml-sharp `save_ply` output:
  - OpenCV coordinates: x right, y DOWN, z FORWARD; camera at the origin looking at +z; metres.
  - element vertex: x y z f_dc_0..2 opacity scale_0..2 rot_0..3 (all float32)
      f_dc = (sRGB - 0.5) / C0, opacity = logit(alpha), scale = ln(sigma), rot = (w, x, y, z)
  - extra elements: image_size, intrinsic, extrinsic, frame, disparity, color_space, version

The scene is deliberately asymmetric so a wrong coordinate conversion is obvious:
  - backdrop at z = 4 m filling a 60-degree horizontal FOV: sky blue on TOP, grass green on the BOTTOM,
    with a white arrow pointing UP (OpenCV "up" is -y)
  - a red ball on the LEFT (z = 2 m) and a yellow cube on the RIGHT (z = 2.5 m)

Usage: make_mock_ply.py OUTPUT.ply
The first vertex written is a fixed probe splat used by the unit tests (see PROBE below).
"""

import math
import struct
import sys

C0 = 0.28209479177387814

IMAGE_W, IMAGE_H = 640, 480
HFOV_DEG = 60.0
F_PX = (IMAGE_W / 2) / math.tan(math.radians(HFOV_DEG / 2))

# Probe splat: unit tests decode the first vertex and compare against these values.
PROBE = {
    "position": (0.0, -1.0, 4.0),
    "srgb": (0.25, 0.5, 0.75),
    "alpha": 0.8,
    "sigma": (0.05, 0.04, 0.03),
}


def logit(a):
    return math.log(a / (1.0 - a))


def splat(pos, srgb, alpha, sigma, quat=(1.0, 0.0, 0.0, 0.0)):
    return (
        pos[0], pos[1], pos[2],
        (srgb[0] - 0.5) / C0, (srgb[1] - 0.5) / C0, (srgb[2] - 0.5) / C0,
        logit(alpha),
        math.log(sigma[0]), math.log(sigma[1]), math.log(sigma[2]),
        quat[0], quat[1], quat[2], quat[3],
    )


def lerp(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def in_up_arrow(x, y):
    """White arrow centred on x = 0, pointing to -y (up in OpenCV)."""
    shaft = abs(x) <= 0.09 and -0.55 <= y <= 0.75
    # Triangle head: tip at y = -1.05, base at y = -0.55 with half-width 0.35.
    if -1.05 <= y <= -0.55:
        half_width = 0.35 * (y + 1.05) / 0.5
        head = abs(x) <= half_width
    else:
        head = False
    return shaft or head


def backdrop(z=4.0, spacing=0.035):
    half_w = z * math.tan(math.radians(HFOV_DEG / 2)) * 1.05
    half_h = half_w * IMAGE_H / IMAGE_W
    sky_top, sky_horizon = (0.10, 0.35, 0.85), (0.65, 0.85, 1.00)
    grass_near, grass_far = (0.15, 0.45, 0.10), (0.35, 0.70, 0.25)
    out = []
    cols = int(2 * half_w / spacing) + 1
    rows = int(2 * half_h / spacing) + 1
    for r in range(rows):
        y = -half_h + r * spacing
        for c in range(cols):
            x = -half_w + c * spacing
            if in_up_arrow(x, y):
                color = (0.97, 0.97, 0.97)
            elif y < 0:  # top half: sky
                color = lerp(sky_top, sky_horizon, (y + half_h) / half_h)
            else:  # bottom half: grass with a checker so depth/parallax is visible
                base = lerp(grass_far, grass_near, y / half_h)
                checker = (int((x + half_w) / 0.25) + int(y / 0.25)) % 2
                color = tuple(v * (0.8 if checker else 1.0) for v in base)
            out.append(splat((x, y, z), color, 0.97, (spacing * 0.7, spacing * 0.7, 0.004)))
    return out


def ball(center, radius, color, count=1800):
    out = []
    golden = math.pi * (3.0 - math.sqrt(5.0))
    for i in range(count):
        v = 1.0 - 2.0 * (i + 0.5) / count
        r = math.sqrt(1.0 - v * v)
        theta = golden * i
        nx, ny, nz = r * math.cos(theta), v, r * math.sin(theta)
        # Simple shading so the ball reads as 3D: lighter towards the camera-facing upper side.
        shade = 0.6 + 0.4 * max(0.0, -0.3 * ny - 0.95 * nz)
        pos = (center[0] + radius * nx, center[1] + radius * ny, center[2] + radius * nz)
        out.append(splat(pos, tuple(min(1.0, c * shade) for c in color), 0.95, (0.022, 0.022, 0.022)))
    return out


def cube(center, size, color, spacing=0.02):
    out = []
    n = int(size / spacing) + 1
    h = size / 2
    face_shade = {0: 1.0, 1: 0.75, 2: 0.9}  # per axis, so edges are visible
    for axis in range(3):
        for sign in (-1.0, 1.0):
            for i in range(n):
                for j in range(n):
                    u = -h + i * spacing
                    w = -h + j * spacing
                    p = [0.0, 0.0, 0.0]
                    p[axis] = sign * h
                    p[(axis + 1) % 3] = u
                    p[(axis + 2) % 3] = w
                    pos = (center[0] + p[0], center[1] + p[1], center[2] + p[2])
                    shade = face_shade[axis]
                    out.append(splat(pos, tuple(c * shade for c in color), 0.95,
                                     (spacing * 0.7, spacing * 0.7, spacing * 0.7)))
    return out


def build_scene():
    splats = [splat(PROBE["position"], PROBE["srgb"], PROBE["alpha"], PROBE["sigma"])]
    splats += backdrop()
    splats += ball(center=(-0.75, 0.15, 2.0), radius=0.25, color=(0.90, 0.12, 0.10))
    splats += cube(center=(0.75, -0.15, 2.5), size=0.4, color=(0.98, 0.85, 0.10))
    return splats


def write_ply(path, splats):
    vertex_props = (["x", "y", "z"] + [f"f_dc_{i}" for i in range(3)] + ["opacity"]
                    + [f"scale_{i}" for i in range(3)] + [f"rot_{i}" for i in range(4)])
    depths = sorted(s[2] for s in splats)
    disparity = (1.0 / depths[int(len(depths) * 0.9)], 1.0 / depths[int(len(depths) * 0.1)])

    header = ["ply", "format binary_little_endian 1.0", f"element vertex {len(splats)}"]
    header += [f"property float {p}" for p in vertex_props]
    header += ["element image_size 2", "property uint image_size",
               "element intrinsic 9", "property float intrinsic",
               "element extrinsic 16", "property float extrinsic",
               "element frame 2", "property int frame",
               "element disparity 2", "property float disparity",
               "element color_space 1", "property uchar color_space",
               "element version 3", "property uchar version",
               "end_header"]

    with open(path, "wb") as f:
        f.write(("\n".join(header) + "\n").encode("ascii"))
        vertex = struct.Struct("<14f")
        for s in splats:
            f.write(vertex.pack(*s))
        f.write(struct.pack("<2I", IMAGE_W, IMAGE_H))
        f.write(struct.pack("<9f", F_PX, 0, IMAGE_W / 2, 0, F_PX, IMAGE_H / 2, 0, 0, 1))
        f.write(struct.pack("<16f", *[1.0 if i % 5 == 0 else 0.0 for i in range(16)]))
        f.write(struct.pack("<2i", 1, len(splats)))
        f.write(struct.pack("<2f", *disparity))
        f.write(struct.pack("<B", 1))  # ml-sharp encode_color_space("sRGB")
        f.write(struct.pack("<3B", 1, 5, 0))


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: make_mock_ply.py OUTPUT.ply")
    splats = build_scene()
    write_ply(sys.argv[1], splats)
    print(f"wrote {len(splats)} splats to {sys.argv[1]}")


if __name__ == "__main__":
    main()
