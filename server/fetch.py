"""Download an image from an arbitrary URL with SSRF protection and hard limits.

SSRF defence: the address check happens inside the network backend's `connect_tcp`, i.e. at the
moment the socket is opened, on exactly the IP that is connected to. There is no gap between
"check" and "use", so DNS rebinding cannot slip a private address through. TLS still uses the
original hostname for SNI and certificate verification (httpcore passes the origin host to
start_tls). Redirects are followed manually and each hop goes through the same backend.

Time limit: one overall deadline covers DNS, every connect, TLS handshake and every socket
read/write (response headers included), across all redirects.
"""

from __future__ import annotations

import ipaddress
import socket
import time
from concurrent.futures import ThreadPoolExecutor
from concurrent.futures import TimeoutError as FutureTimeout
from typing import Callable, Iterable
from urllib.parse import urljoin, urlsplit, urlunsplit

import httpcore

from config import Settings

USER_AGENT = "splat-server/1.0"

IPAddress = ipaddress.IPv4Address | ipaddress.IPv6Address


class FetchError(Exception):
    """Raised for any download failure; `status` is the HTTP status the API should return."""

    def __init__(self, message: str, status: int = 400):
        super().__init__(message)
        self.status = status


def redact_url(url: str) -> str:
    """Drop userinfo, query and fragment so signed URLs / credentials are never stored or logged."""
    try:
        parts = urlsplit(url)
        host = parts.hostname or ""
        if parts.port:
            host = f"{host}:{parts.port}"
        return urlunsplit((parts.scheme, host, parts.path, "", ""))
    except ValueError:
        return "<invalid url>"


def ip_allowed(ip: IPAddress, allowed_private_nets: Iterable) -> bool:
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    if any(ip in net for net in allowed_private_nets if net.version == ip.version):
        return True
    return ip.is_global and not ip.is_multicast


Resolver = Callable[[str, int], list[str]]

# getaddrinfo cannot be interrupted, so it runs on a small helper pool and we stop waiting for it
# when the deadline passes (the lookup thread then finishes on its own in the background).
_DNS_POOL = ThreadPoolExecutor(max_workers=4, thread_name_prefix="dns")


def system_resolver(host: str, port: int) -> list[str]:
    infos = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
    return [info[4][0] for info in infos]


class Deadline:
    def __init__(self, total: float, per_op: float):
        self.end = time.monotonic() + total
        self.per_op = per_op

    def remaining(self) -> float:
        left = self.end - time.monotonic()
        if left <= 0:
            raise FetchError("download timed out", 504)
        return left

    def op(self, requested: float | None = None) -> float:
        """Timeout for one blocking operation: never beyond the overall deadline."""
        cap = min(self.remaining(), self.per_op)
        return cap if requested is None else min(cap, requested)


class DeadlineStream(httpcore.NetworkStream):
    """Wraps a socket stream so every read/write (headers included) obeys the overall deadline."""

    def __init__(self, inner: httpcore.NetworkStream, deadline: Deadline):
        self._inner = inner
        self._deadline = deadline

    def read(self, max_bytes, timeout=None):
        return self._inner.read(max_bytes, self._deadline.op(timeout))

    def write(self, buffer, timeout=None):
        return self._inner.write(buffer, self._deadline.op(timeout))

    def close(self):
        return self._inner.close()

    def start_tls(self, ssl_context, server_hostname=None, timeout=None):
        inner = self._inner.start_tls(ssl_context, server_hostname, self._deadline.op(timeout))
        return DeadlineStream(inner, self._deadline)

    def get_extra_info(self, info):
        return self._inner.get_extra_info(info)


class SafeBackend(httpcore.SyncBackend):
    """Network backend that refuses to connect to non-public addresses."""

    def __init__(self, settings: Settings, deadline: Deadline, resolver: Resolver = system_resolver):
        super().__init__()
        self.settings = settings
        self.deadline = deadline
        self.resolver = resolver

    def _resolve(self, host: str, port: int) -> list[str]:
        future = _DNS_POOL.submit(self.resolver, host, port)
        try:
            return future.result(timeout=self.deadline.op())
        except FutureTimeout as exc:
            raise FetchError("download timed out (DNS)", 504) from exc
        except (socket.gaierror, UnicodeError, OSError) as exc:
            raise FetchError(f"cannot resolve host: {host}", 400) from exc

    def connect_tcp(self, host, port, timeout=None, local_address=None, socket_options=None):
        addresses = self._resolve(host, port)
        if not addresses:
            raise FetchError(f"cannot resolve host: {host}", 400)
        ips = []
        for addr in addresses:
            ip = ipaddress.ip_address(addr.split("%", 1)[0])  # strip IPv6 zone id
            if not ip_allowed(ip, self.settings.allowed_private_nets):
                # Reject if ANY answer is non-public (mixed answers are a rebinding trick).
                raise FetchError("URL resolves to a private or reserved address", 400)
            ips.append(ip)
        last_exc: Exception | None = None
        for ip in ips:
            try:
                stream = super().connect_tcp(
                    str(ip), port, self.deadline.op(timeout), local_address, socket_options
                )
                return DeadlineStream(stream, self.deadline)
            except (httpcore.ConnectError, httpcore.ConnectTimeout) as exc:
                last_exc = exc
        assert last_exc is not None
        raise last_exc


def _validate_url(url: str) -> None:
    try:
        parts = urlsplit(url)
        _ = parts.port  # raises ValueError for a non-numeric / out-of-range port
    except ValueError as exc:
        raise FetchError("invalid URL", 400) from exc
    if parts.scheme not in ("http", "https"):
        raise FetchError("only http and https URLs are allowed", 400)
    if not parts.hostname:
        raise FetchError("URL has no host", 400)
    if parts.username or parts.password:
        raise FetchError("URLs with credentials are not allowed", 400)


def fetch_image_bytes(url: str, settings: Settings, resolver: Resolver = system_resolver) -> bytes:
    """Download `url` and return its body. Raises FetchError with an HTTP status on failure."""
    deadline = Deadline(settings.download_total_timeout, settings.download_op_timeout)
    pool = httpcore.ConnectionPool(
        network_backend=SafeBackend(settings, deadline, resolver),
        max_connections=1,
        retries=0,
    )
    try:
        current = url
        for _hop in range(settings.max_redirects + 1):
            _validate_url(current)
            t = deadline.op()
            headers = [
                (b"User-Agent", USER_AGENT.encode()),
                (b"Accept", b"image/*"),
                (b"Accept-Encoding", b"identity"),
            ]
            extensions = {"timeout": {"connect": t, "read": t, "write": t, "pool": t}}
            try:
                with pool.stream("GET", current, headers=headers, extensions=extensions) as resp:
                    if resp.status in (301, 302, 303, 307, 308):
                        location = _header(resp.headers, b"location")
                        if not location:
                            raise FetchError("redirect without Location", 502)
                        current = urljoin(current, location)
                        continue
                    if resp.status != 200:
                        raise FetchError(f"image URL returned HTTP {resp.status}", 502)
                    length = _header(resp.headers, b"content-length")
                    if length and length.isdigit() and int(length) > settings.max_upload_bytes:
                        raise FetchError("image is too large", 413)
                    body = bytearray()
                    for chunk in resp.iter_stream():
                        body.extend(chunk)
                        if len(body) > settings.max_upload_bytes:
                            raise FetchError("image is too large", 413)
                    return bytes(body)
            except FetchError:
                raise
            except httpcore.TimeoutException as exc:
                raise FetchError("download timed out", 504) from exc
            except (httpcore.UnsupportedProtocol, ValueError) as exc:
                raise FetchError("invalid URL", 400) from exc
            except (httpcore.NetworkError, httpcore.ProtocolError) as exc:
                raise FetchError(f"download failed: {type(exc).__name__}", 502) from exc
        raise FetchError("too many redirects", 502)
    finally:
        pool.close()


def _header(headers: list[tuple[bytes, bytes]], name: bytes) -> str | None:
    for key, value in headers:
        if key.lower() == name:
            return value.decode("latin-1").strip()
    return None
