import ipaddress
import time

import pytest

from conftest import LOOPBACK, jpeg_bytes
from fetch import FetchError, fetch_image_bytes, ip_allowed, redact_url


@pytest.mark.parametrize(
    "addr, allowed",
    [
        ("8.8.8.8", True),
        ("2001:4860:4860::8888", True),
        ("::ffff:8.8.8.8", True),
        ("127.0.0.1", False),
        ("10.1.2.3", False),
        ("172.16.0.1", False),
        ("192.168.1.10", False),
        ("169.254.169.254", False),
        ("100.64.0.1", False),  # CGNAT
        ("0.0.0.0", False),
        ("224.0.0.1", False),
        ("255.255.255.255", False),
        ("::1", False),
        ("::", False),
        ("fe80::1", False),
        ("fc00::1", False),
        ("::ffff:127.0.0.1", False),  # IPv4-mapped loopback
        ("::ffff:192.168.0.1", False),
        ("ff02::1", False),
    ],
)
def test_ip_allowed(addr, allowed):
    assert ip_allowed(ipaddress.ip_address(addr), []) is allowed


def test_ip_allowlist():
    nets = [ipaddress.ip_network("192.168.1.0/24")]
    assert ip_allowed(ipaddress.ip_address("192.168.1.50"), nets)
    assert not ip_allowed(ipaddress.ip_address("192.168.2.50"), nets)
    assert ip_allowed(ipaddress.ip_address("::ffff:192.168.1.50"), nets)


def test_redact_url():
    assert redact_url("https://user:pw@example.com:8443/a/b.jpg?sig=secret#x") == "https://example.com:8443/a/b.jpg"


@pytest.mark.parametrize("url", ["ftp://example.com/a.jpg", "file:///C:/Windows/win.ini", "gopher://x", "http:///nohost",
                                 "https://user:pw@example.com/a.jpg"])
def test_rejects_bad_urls(settings, url):
    with pytest.raises(FetchError) as e:
        fetch_image_bytes(url, settings)
    assert e.value.status == 400


@pytest.mark.parametrize("url", ["http://127.0.0.1/", "http://localhost/", "http://169.254.169.254/latest/meta-data/",
                                 "http://10.0.0.1/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://0.0.0.0/"])
def test_rejects_private_targets(settings, url):
    with pytest.raises(FetchError) as e:
        fetch_image_bytes(url, settings)
    assert e.value.status == 400
    assert "private" in str(e.value) or "resolve" in str(e.value)


def test_rejects_mixed_dns_answers(settings):
    resolver = lambda host, port: ["93.184.216.34", "127.0.0.1"]  # noqa: E731
    with pytest.raises(FetchError, match="private"):
        fetch_image_bytes("http://rebind.test/a.jpg", settings, resolver=resolver)


def test_connects_to_the_validated_ip(settings, http_server):
    """DNS pinning: the hostname is resolved once by our backend and that IP is connected to."""
    data = jpeg_bytes()

    def ok(h):
        h.send_response(200)
        h.send_header("Content-Length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)

    http_server.routes["/a.jpg"] = ok
    port = http_server.server_address[1]
    settings.allowed_private_nets = LOOPBACK
    seen = []

    def resolver(host, p):
        seen.append(host)
        return ["127.0.0.1"]

    assert fetch_image_bytes(f"http://pinned.test:{port}/a.jpg", settings, resolver=resolver) == data
    assert seen == ["pinned.test"]


def test_rebinding_second_resolution_is_checked(settings, http_server):
    """Each connection (e.g. after a redirect) re-validates; a later private answer is refused."""
    port = http_server.server_address[1]

    def redirect(h):
        h.send_response(302)
        h.send_header("Location", f"http://rebind.test:{port}/b.jpg")
        h.send_header("Content-Length", "0")
        h.end_headers()

    http_server.routes["/a.jpg"] = redirect
    settings.allowed_private_nets = [ipaddress.ip_network("127.0.0.1/32")]
    answers = iter([["127.0.0.1"], ["10.0.0.5"]])
    with pytest.raises(FetchError, match="private"):
        fetch_image_bytes(f"http://rebind.test:{port}/a.jpg", settings, resolver=lambda h, p: next(answers))


def test_redirect_to_private_is_blocked(settings, http_server):
    def redirect(h):
        h.send_response(302)
        h.send_header("Location", "http://169.254.169.254/latest/meta-data/")
        h.send_header("Content-Length", "0")
        h.end_headers()

    http_server.routes["/r"] = redirect
    settings.allowed_private_nets = [ipaddress.ip_network("127.0.0.1/32")]
    with pytest.raises(FetchError, match="private"):
        fetch_image_bytes(http_server.base + "/r", settings)


def test_redirect_followed_and_limited(settings, http_server):
    data = jpeg_bytes()

    def final(h):
        h.send_response(200)
        h.send_header("Content-Length", str(len(data)))
        h.end_headers()
        h.wfile.write(data)

    def hop(target):
        def f(h):
            h.send_response(301)
            h.send_header("Location", target)
            h.send_header("Content-Length", "0")
            h.end_headers()
        return f

    http_server.routes["/final"] = final
    http_server.routes["/r1"] = hop("/final")
    http_server.routes["/loop"] = hop("/loop")
    settings.allowed_private_nets = LOOPBACK
    assert fetch_image_bytes(http_server.base + "/r1", settings) == data
    with pytest.raises(FetchError, match="too many redirects"):
        fetch_image_bytes(http_server.base + "/loop", settings)


def test_size_limit_by_header_and_by_stream(settings, http_server):
    big = b"x" * 5000

    def with_length(h):
        h.send_response(200)
        h.send_header("Content-Length", str(len(big)))
        h.end_headers()
        h.wfile.write(big)

    def chunked(h):
        h.protocol_version = "HTTP/1.1"
        h.send_response(200)
        h.send_header("Transfer-Encoding", "chunked")
        h.end_headers()
        for _ in range(10):
            h.wfile.write(b"3e8\r\n" + b"y" * 1000 + b"\r\n")
        h.wfile.write(b"0\r\n\r\n")

    http_server.routes["/len"] = with_length
    http_server.routes["/chunked"] = chunked
    settings.allowed_private_nets = LOOPBACK
    settings.max_upload_bytes = 2000
    for path in ("/len", "/chunked"):
        with pytest.raises(FetchError) as e:
            fetch_image_bytes(http_server.base + path, settings)
        assert e.value.status == 413


def test_slow_drip_hits_total_deadline(settings, http_server):
    def slow(h):
        h.send_response(200)
        h.send_header("Content-Length", "100")
        h.end_headers()
        try:
            for _ in range(100):
                h.wfile.write(b"z")
                h.wfile.flush()
                time.sleep(0.2)
        except OSError:
            pass

    http_server.routes["/slow"] = slow
    settings.allowed_private_nets = LOOPBACK
    settings.download_total_timeout = 1.0
    settings.download_op_timeout = 0.5
    t0 = time.monotonic()
    with pytest.raises(FetchError) as e:
        fetch_image_bytes(http_server.base + "/slow", settings)
    assert e.value.status == 504
    assert time.monotonic() - t0 < 2.5


def test_slow_dns_hits_deadline(settings):
    settings.download_total_timeout = 0.5

    def slow_resolver(host, port):
        time.sleep(2)
        return ["93.184.216.34"]

    t0 = time.monotonic()
    with pytest.raises(FetchError) as e:
        fetch_image_bytes("http://slow-dns.test/a.jpg", settings, resolver=slow_resolver)
    assert e.value.status == 504
    assert time.monotonic() - t0 < 1.5


def test_slow_headers_hit_deadline(settings, http_server):
    """Response headers dribbled out slowly must not exceed the overall deadline."""

    def slow_headers(h):
        try:
            h.wfile.write(b"HTTP/1.1 200 OK\r\n")
            for i in range(50):
                h.wfile.write(f"X-Pad-{i}: x\r\n".encode())
                h.wfile.flush()
                time.sleep(0.2)
        except OSError:
            pass

    http_server.routes["/slowh"] = slow_headers
    settings.allowed_private_nets = LOOPBACK
    settings.download_total_timeout = 1.0
    settings.download_op_timeout = 0.5
    t0 = time.monotonic()
    with pytest.raises(FetchError) as e:
        fetch_image_bytes(http_server.base + "/slowh", settings)
    assert e.value.status == 504
    assert time.monotonic() - t0 < 2.0


@pytest.mark.parametrize("url", ["http://example.com:abc/a.jpg", "http://example.com:99999/a.jpg", "http://[::1/a"])
def test_invalid_url_forms_are_400(settings, url):
    with pytest.raises(FetchError) as e:
        fetch_image_bytes(url, settings)
    assert e.value.status == 400


def test_http_error_status(settings, http_server):
    settings.allowed_private_nets = LOOPBACK
    with pytest.raises(FetchError) as e:
        fetch_image_bytes(http_server.base + "/missing", settings)
    assert e.value.status == 502
