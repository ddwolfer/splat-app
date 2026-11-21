import ipaddress
import socket
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path

import pytest
from PIL import Image

SERVER_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_DIR))

from config import Settings  # noqa: E402


def jpeg_bytes(size=(64, 48), color=(200, 100, 50), exif=None) -> bytes:
    buf = BytesIO()
    img = Image.new("RGB", size, color)
    if exif is not None:
        img.save(buf, "JPEG", exif=exif)
    else:
        img.save(buf, "JPEG")
    return buf.getvalue()


class FakeEngine:
    """Stands in for SharpEngine: records concurrency, optionally sleeps or raises."""

    gpu_name = "Fake GPU"
    amp = "fp16"

    def __init__(self, delay: float = 0.0):
        self.delay = delay
        self.active = 0
        self.max_active = 0
        self.calls = []
        self.fail_next_with = None
        self._lock = threading.Lock()

    def run(self, rgb, f_px, out_path):
        with self._lock:
            self.active += 1
            self.max_active = max(self.max_active, self.active)
        try:
            self.calls.append((rgb.shape, f_px))
            if self.delay:
                time.sleep(self.delay)
            if self.fail_next_with is not None:
                exc, self.fail_next_with = self.fail_next_with, None
                raise exc
            Path(out_path).write_bytes(b"ply\nformat binary_little_endian 1.0\nend_header\n")
        finally:
            with self._lock:
                self.active -= 1


@pytest.fixture
def settings(tmp_path):
    s = Settings()
    s.splat_dir = tmp_path / "splats"
    s.min_free_bytes = 0
    s.download_total_timeout = 3.0
    s.download_op_timeout = 2.0
    return s


class _Handler(BaseHTTPRequestHandler):
    routes: dict = {}

    def do_GET(self):  # noqa: N802
        route = self.routes.get(self.path)
        if route is None:
            self.send_response(404)
            self.end_headers()
            return
        route(self)

    def log_message(self, *args):
        pass


@pytest.fixture
def http_server():
    """Local HTTP server on 127.0.0.1; tests register handlers in `server.routes`."""
    routes = {}
    handler = type("H", (_Handler,), {"routes": routes})
    srv = ThreadingHTTPServer(("127.0.0.1", 0), handler)
    srv.daemon_threads = True
    t = threading.Thread(target=srv.serve_forever, daemon=True)
    t.start()
    srv.routes = routes
    srv.base = f"http://127.0.0.1:{srv.server_address[1]}"
    yield srv
    srv.shutdown()
    srv.server_close()


LOOPBACK = [ipaddress.ip_network("127.0.0.0/8")]


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]
