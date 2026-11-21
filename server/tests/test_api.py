import json
import os
import socket
import threading
import time
import uuid

import httpx
import pytest
import uvicorn
from fastapi.testclient import TestClient

from app import GpuOutOfMemory, create_app
from conftest import FakeEngine, free_port, jpeg_bytes
from fetch import FetchError


def make_client(settings, engine=None, fetcher=None):
    engine = engine or FakeEngine()
    fetcher = fetcher or (lambda url, s: jpeg_bytes())
    app = create_app(settings, engine_factory=lambda s: engine, fetcher=fetcher)
    return TestClient(app), engine


def test_health(settings):
    client, _ = make_client(settings)
    with client:
        r = client.get("/health")
    assert r.status_code == 200 and r.json() == {"ok": True, "gpu": "Fake GPU"}


def test_generate_json_then_download_and_list(settings):
    client, engine = make_client(settings)
    with client:
        r = client.post("/generate", json={"image_url": "https://example.com/p.jpg?sig=SECRET"})
        assert r.status_code == 200, r.text
        body = r.json()
        assert set(body) == {"id", "ply_url", "seconds"}
        uuid.UUID(body["id"])
        assert body["ply_url"] == f"/splats/{body['id']}.ply"
        assert isinstance(body["seconds"], float)
        ply = client.get(body["ply_url"])
        assert ply.status_code == 200 and ply.content.startswith(b"ply")
        assert ply.headers["content-type"] == "application/octet-stream"
        listing = client.get("/list").json()["splats"]
    assert len(listing) == 1 and listing[0]["id"] == body["id"]
    assert listing[0]["source"] == "https://example.com/p.jpg"  # query (signature) stripped
    assert "SECRET" not in json.dumps(listing)
    assert engine.calls[0][0] == (48, 64, 3)


def test_generate_multipart(settings):
    client, _ = make_client(settings)
    with client:
        r = client.post("/generate", files={"file": ("photo.jpg", jpeg_bytes(), "image/jpeg")})
        assert r.status_code == 200, r.text
        listing = client.get("/list").json()["splats"]
    assert listing[0]["source"] == "upload:photo.jpg"


@pytest.mark.parametrize(
    "kwargs, status",
    [
        ({"content": b"hello", "headers": {"Content-Type": "text/plain"}}, 415),
        ({"content": b"{not json", "headers": {"Content-Type": "application/json"}}, 400),
        ({"json": {"url": "https://x"}}, 400),
        ({"json": {"image_url": 123}}, 400),
        ({"json": ["https://x"]}, 400),
        ({"json": {"image_url": "https://x/" + "a" * 5000}}, 413),
        ({"files": {"other": ("a.jpg", b"123", "image/jpeg")}}, 400),
        ({"files": {"file": ("a.txt", b"not an image", "text/plain")}}, 400),
    ],
)
def test_generate_bad_input(settings, kwargs, status):
    client, engine = make_client(settings)
    with client:
        r = client.post("/generate", **kwargs)
    assert r.status_code == status, r.text
    assert set(r.json()) == {"error"}
    assert engine.calls == []


def test_upload_too_large(settings):
    settings.max_upload_bytes = 1000
    client, _ = make_client(settings)
    with client:
        r = client.post("/generate", files={"file": ("a.jpg", b"x" * 200_000, "image/jpeg")})
    assert r.status_code == 413 and "error" in r.json()


def test_fetch_errors_are_mapped(settings):
    def fetcher(url, s):
        raise FetchError("URL resolves to a private or reserved address", 400)

    client, _ = make_client(settings, fetcher=fetcher)
    with client:
        r = client.post("/generate", json={"image_url": "http://127.0.0.1/"})
    assert r.status_code == 400 and "private" in r.json()["error"]


def test_oom_returns_503_and_next_request_succeeds(settings):
    engine = FakeEngine()
    engine.fail_next_with = GpuOutOfMemory()
    client, _ = make_client(settings, engine=engine)
    with client:
        r1 = client.post("/generate", json={"image_url": "https://example.com/a.jpg"})
        r2 = client.post("/generate", json={"image_url": "https://example.com/a.jpg"})
    assert r1.status_code == 503 and "out of memory" in r1.json()["error"]
    assert r2.status_code == 200
    assert not list(settings.splat_dir.glob("*.tmp"))


def test_disk_full_returns_507(settings):
    settings.min_free_bytes = 10**18
    client, _ = make_client(settings)
    with client:
        r = client.post("/generate", json={"image_url": "https://example.com/a.jpg"})
    assert r.status_code == 507


@pytest.mark.parametrize("path", ["/splats/not-a-uuid.ply", "/splats/..%2F..%2Fapp.py", "/splats/%2e%2e/config.py",
                                  f"/splats/{uuid.uuid4()}.ply", f"/splats/{uuid.uuid4()}.json", "/nope"])
def test_splat_not_found(settings, path):
    client, _ = make_client(settings)
    with client:
        r = client.get(path)
    assert r.status_code == 404 and set(r.json()) == {"error"}


def test_eviction_and_orphan_cleanup(settings):
    settings.max_splats = 2
    settings.splat_dir.mkdir(parents=True)
    (settings.splat_dir / "junk.ply.tmp").write_bytes(b"x")
    orphan = settings.splat_dir / f"{uuid.uuid4()}.ply"
    orphan.write_bytes(b"x")
    client, _ = make_client(settings)
    with client:
        ids = []
        for _ in range(3):
            ids.append(client.post("/generate", json={"image_url": "https://e.com/a.jpg"}).json()["id"])
            time.sleep(0.01)
        listing = [m["id"] for m in client.get("/list").json()["splats"]]
        assert client.get(f"/splats/{ids[0]}.ply").status_code == 404
    assert listing == [ids[2], ids[1]]
    assert not (settings.splat_dir / "junk.ply.tmp").exists()  # startup cleanup
    assert not orphan.exists()  # startup cleanup


def test_eviction_orphans_only_when_old(settings):
    """At runtime a .ply without .json may be a publish in progress (e.g. register_ply.py)."""
    settings.max_splats = 1
    client, _ = make_client(settings)
    with client:
        fresh = settings.splat_dir / f"{uuid.uuid4()}.ply"
        fresh.write_bytes(b"x")
        stale = settings.splat_dir / f"{uuid.uuid4()}.ply"
        stale.write_bytes(b"x")
        old = time.time() - 3600
        os.utime(stale, (old, old))
        client.post("/generate", json={"image_url": "https://e.com/a.jpg"})
    assert fresh.exists()
    assert not stale.exists()


def test_download_survives_eviction_race(settings):
    """An open download keeps its file; eviction just logs and retries later."""
    settings.max_splats = 1
    client, _ = make_client(settings)
    with client:
        first = client.post("/generate", json={"image_url": "https://e.com/a.jpg"}).json()["id"]
        handle = client.app.state.store.open_ply(first)
        try:
            client.post("/generate", json={"image_url": "https://e.com/a.jpg"})
            assert handle.read().startswith(b"ply")  # still readable through the open handle
        finally:
            handle.close()
        assert client.get(f"/splats/{first}.ply").status_code == 404  # unpublished (json gone)


def test_body_read_timeout_frees_slot(settings):
    settings.body_read_timeout = 0.5
    settings.max_inflight = 1
    engine = FakeEngine()
    app = create_app(settings, engine_factory=lambda s: engine, fetcher=lambda url, s: jpeg_bytes())
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    try:
        for _ in range(100):
            if server.started:
                break
            time.sleep(0.05)
        # Send headers promising a body, then stall.
        s = socket.create_connection(("127.0.0.1", port))
        s.sendall(b"POST /generate HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\n"
                  b"Content-Length: 100\r\n\r\n{")
        s.settimeout(5)
        reply = s.recv(4096)
        s.close()
        assert b" 408 " in reply.split(b"\r\n", 1)[0]
        r = httpx.post(f"http://127.0.0.1:{port}/generate", json={"image_url": "https://e.com/a.jpg"}, timeout=10)
        assert r.status_code == 200  # the slot was released
    finally:
        server.should_exit = True
        t.join(timeout=10)


# ---- real server: concurrency, admission control, client disconnect ------------------------------
@pytest.fixture
def live_server(settings):
    engine = FakeEngine(delay=0.6)
    app = create_app(settings, engine_factory=lambda s: engine, fetcher=lambda url, s: jpeg_bytes())
    port = free_port()
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning"))
    t = threading.Thread(target=server.run, daemon=True)
    t.start()
    for _ in range(100):
        if server.started:
            break
        time.sleep(0.05)
    yield f"http://127.0.0.1:{port}", engine
    server.should_exit = True
    t.join(timeout=10)


def test_concurrent_requests_serialized_and_admission_limited(live_server, settings):
    base, engine = live_server
    results = []

    def post():
        r = httpx.post(base + "/generate", json={"image_url": "https://e.com/a.jpg"}, timeout=30)
        results.append(r.status_code)

    threads = [threading.Thread(target=post) for _ in range(6)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert engine.max_active == 1  # GPU work never overlapped
    assert sorted(results).count(200) == settings.max_inflight
    assert sorted(results).count(503) == 6 - settings.max_inflight


def test_client_disconnect_does_not_free_slot_early(live_server, settings):
    base, engine = live_server
    with pytest.raises(httpx.ReadTimeout):
        httpx.post(base + "/generate", json={"image_url": "https://e.com/a.jpg"}, timeout=0.2)
    # The abandoned job keeps running; new requests still never overlap it on the GPU.
    codes = []
    threads = [threading.Thread(target=lambda: codes.append(
        httpx.post(base + "/generate", json={"image_url": "https://e.com/a.jpg"}, timeout=30).status_code))
        for _ in range(3)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert engine.max_active == 1
    assert codes.count(200) == 2 and codes.count(503) == 1  # one slot still held by the abandoned job
    time.sleep(0.8)
    assert len(httpx.get(base + "/list").json()["splats"]) == 3  # abandoned job completed too
