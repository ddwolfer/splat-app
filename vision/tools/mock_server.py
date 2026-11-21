#!/usr/bin/env python3
"""Local stand-in for splat-server (API.md), for developing/testing the vision app without the PC.

Stdlib only. Dev use on your own machine; it is NOT the real server and does not fetch image_url.

  python3 vision/tools/mock_server.py                 # 0.0.0.0:8765, small mock PLY (~1 MB)
  python3 vision/tools/mock_server.py --count 1179648 # full-size PLY (~63 MB, like real SHARP output)

Endpoints (see API.md): GET /health, POST /generate (JSON {"image_url"}), GET /splats/<id>.ply, GET /list.
Test hooks: an image_url containing "error" -> 400, "busy" -> 503, "slow" -> 10 s delay.
Binds 0.0.0.0 so the visionOS simulator can reach it via the Mac's LAN IP (exercises ATS local networking).
"""

import argparse
import datetime
import json
import os
import re
import sys
import tempfile
import threading
import time
import uuid
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import make_mock_ply  # noqa: E402  (sibling script in this directory)

SPLAT_PATH = re.compile(r"^/splats/([0-9a-f-]{36})\.ply$")


class State:
    def __init__(self, ply_path, delay):
        self.ply_path = ply_path
        self.delay = delay
        self.lock = threading.Lock()
        self.splats = []  # newest first


class Handler(BaseHTTPRequestHandler):
    state: State = None  # set in main()
    server_version = "splat-mock/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("[mock_server] " + (fmt % args) + "\n")

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def send_error_json(self, status, message):
        self.send_json(status, {"error": message})

    def do_GET(self):
        if self.path == "/health":
            self.send_json(HTTPStatus.OK, {"ok": True, "gpu": "Mock GPU (mock_server.py)"})
        elif self.path == "/list":
            with self.state.lock:
                self.send_json(HTTPStatus.OK, {"splats": list(self.state.splats)})
        elif match := SPLAT_PATH.match(self.path):
            with self.state.lock:
                known = any(s["id"] == match.group(1) for s in self.state.splats)
            if not known:
                self.send_error_json(HTTPStatus.NOT_FOUND, "splat not found")
                return
            size = os.path.getsize(self.state.ply_path)
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", str(size))
            self.end_headers()
            with open(self.state.ply_path, "rb") as f:
                while chunk := f.read(1 << 20):
                    self.wfile.write(chunk)
        else:
            self.send_error_json(HTTPStatus.NOT_FOUND, "not found")

    def do_POST(self):
        if self.path != "/generate":
            self.send_error_json(HTTPStatus.NOT_FOUND, "not found")
            return
        if not self.headers.get("Content-Type", "").startswith("application/json"):
            self.send_error_json(HTTPStatus.UNSUPPORTED_MEDIA_TYPE, "expected application/json")
            return
        length = int(self.headers.get("Content-Length") or 0)
        if length > 4096:
            self.send_error_json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "body too large")
            return
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
            image_url = body["image_url"]
            assert isinstance(image_url, str) and image_url.startswith(("http://", "https://"))
        except Exception:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "invalid JSON or image_url")
            return
        if "error" in image_url:
            self.send_error_json(HTTPStatus.BAD_REQUEST, "not an image (mock)")
            return
        if "busy" in image_url:
            self.send_error_json(HTTPStatus.SERVICE_UNAVAILABLE, "server busy, try again later")
            return

        start = time.monotonic()
        time.sleep(10 if "slow" in image_url else self.state.delay)
        splat_id = str(uuid.uuid4())
        record = {
            "id": splat_id,
            "ply_url": f"/splats/{splat_id}.ply",
            "seconds": round(time.monotonic() - start, 2),
            "created": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
            "source": image_url.split("?")[0],
            "width": make_mock_ply.IMAGE_W,
            "height": make_mock_ply.IMAGE_H,
            "amp": "mock",
            "size_bytes": os.path.getsize(self.state.ply_path),
        }
        with self.state.lock:
            self.state.splats.insert(0, record)
            del self.state.splats[40:]
        self.send_json(HTTPStatus.OK, {k: record[k] for k in ("id", "ply_url", "seconds")})


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--delay", type=float, default=2.0, help="seconds /generate waits (default 2)")
    parser.add_argument("--count", type=int, default=None, help="splats in the served PLY (e.g. 1179648)")
    args = parser.parse_args()

    ply_path = os.path.join(tempfile.mkdtemp(prefix="splat-mock-"), "mock.ply")
    make_mock_ply.write_ply(ply_path, make_mock_ply.build_scene(args.count))
    print(f"[mock_server] PLY {os.path.getsize(ply_path):,} bytes at {ply_path}")

    Handler.state = State(ply_path, args.delay)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"[mock_server] listening on http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
