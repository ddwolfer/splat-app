"""splat-server: FastAPI implementation of API.md (v1).

Run with a single worker and no reload (see run_server.ps1 / run_server.sh). The model is loaded
once at startup; the server only starts accepting connections after loading has finished.

Concurrency model
  * `max_inflight` admission slots (default 3) cover the WHOLE /generate pipeline: reading the
    request body, downloading, decoding, inference and saving. A request that cannot get a slot
    is rejected immediately with 503 before its body is read.
  * Download + decode run on an I/O pool; inference + saving run on a single-thread GPU pool,
    so GPU work can never overlap. A slot is released only when its pipeline has really finished
    (future done-callback), so a client disconnect never lets more work onto the GPU.
"""

from __future__ import annotations

import asyncio
import gc
import json
import logging
import os
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Protocol

import numpy as np
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from starlette.exceptions import HTTPException as StarletteHTTPException

from config import Settings
from fetch import FetchError, fetch_image_bytes, redact_url
from imaging import ImageError, decode_image
from storage import SplatStore, parse_id

LOGGER = logging.getLogger("splat.app")


class ApiError(Exception):
    def __init__(self, status: int, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class GpuOutOfMemory(Exception):
    pass


class Engine(Protocol):
    gpu_name: str
    amp: str

    def run(self, rgb: np.ndarray, f_px: float, out_path: Path) -> None: ...


class SharpEngine:
    """Real engine: ml-sharp on CUDA. Imports torch lazily so tests can use a fake engine."""

    def __init__(self, amp: str):
        import torch

        import sharp_runner

        if not torch.cuda.is_available():
            raise RuntimeError("CUDA is not available")
        self._torch = torch
        self._runner = sharp_runner
        self.device = torch.device("cuda")
        self.amp = amp
        self.gpu_name = torch.cuda.get_device_name(0)
        self.model = sharp_runner.load_model(self.device)

    def run(self, rgb: np.ndarray, f_px: float, out_path: Path) -> None:
        from sharp.utils.gaussians import save_ply

        torch = self._torch
        oom = False
        gaussians = None
        try:
            gaussians = self._runner.predict(self.model, rgb, f_px, self.device, amp=self.amp)
            save_ply(gaussians, f_px, rgb.shape[:2], out_path)
        except torch.OutOfMemoryError:
            oom = True
        gaussians = None  # drop our reference whether predict or save_ply failed
        if oom:
            # Outside the except block, so the traceback (and the tensors its frames reference)
            # has been released before we try to return memory to the driver.
            gc.collect()
            torch.cuda.empty_cache()
            raise GpuOutOfMemory()


Fetcher = Callable[[str, Settings], bytes]


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def create_app(
    settings: Settings | None = None,
    engine_factory: Callable[[Settings], Engine] | None = None,
    fetcher: Fetcher = fetch_image_bytes,
) -> FastAPI:
    settings = settings or Settings()
    engine_factory = engine_factory or (lambda s: SharpEngine(s.amp))
    store = SplatStore(settings.splat_dir, settings.max_splats, settings.min_free_bytes)
    slots = threading.BoundedSemaphore(settings.max_inflight)
    io_pool = ThreadPoolExecutor(max_workers=settings.max_inflight, thread_name_prefix="io")
    gpu_pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="gpu")
    state: dict = {}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        store.cleanup_orphans()
        t0 = time.perf_counter()
        state["engine"] = await asyncio.to_thread(engine_factory, settings)
        LOGGER.info("model ready in %.1fs on %s (amp=%s)", time.perf_counter() - t0,
                    state["engine"].gpu_name, state["engine"].amp)
        yield
        io_pool.shutdown(wait=True, cancel_futures=True)
        gpu_pool.shutdown(wait=True, cancel_futures=True)

    app = FastAPI(title="splat-server", version="1", lifespan=lifespan)
    app.state.settings = settings
    app.state.store = store

    # ---- error format: always {"error": "..."} ------------------------------------------------
    @app.exception_handler(ApiError)
    async def _api_error(_req: Request, exc: ApiError):
        return JSONResponse({"error": exc.message}, status_code=exc.status)

    @app.exception_handler(StarletteHTTPException)
    async def _http_error(_req: Request, exc: StarletteHTTPException):
        return JSONResponse({"error": str(exc.detail)}, status_code=exc.status_code)

    @app.exception_handler(RequestValidationError)
    async def _validation_error(_req: Request, _exc: RequestValidationError):
        return JSONResponse({"error": "invalid request"}, status_code=400)

    @app.exception_handler(Exception)
    async def _unexpected(_req: Request, exc: Exception):
        LOGGER.exception("unhandled error: %s", exc)
        return JSONResponse({"error": "internal server error"}, status_code=500)

    # ---- pipeline (runs in worker threads) ----------------------------------------------------
    def gpu_stage(splat_id: str, decoded, source: str, started: float) -> dict:
        tmp = store.tmp_ply_path(splat_id)
        try:
            if not store.check_free_space():
                raise ApiError(507, "not enough disk space on server")
            try:
                state["engine"].run(decoded.rgb, decoded.f_px, tmp)
            except GpuOutOfMemory:
                raise ApiError(503, "GPU out of memory, try again later")
            seconds = round(time.perf_counter() - started, 3)
            h, w = decoded.rgb.shape[:2]
            meta = {
                "id": splat_id,
                "ply_url": f"/splats/{splat_id}.ply",
                "seconds": seconds,
                "created": _now_iso(),
                "source": source,
                "width": w,
                "height": h,
                "amp": state["engine"].amp,
            }
            store.publish(splat_id, meta)
        except BaseException:
            store.discard(splat_id)
            raise
        store.evict()
        return meta

    def pipeline(kind: str, payload, started: float) -> dict:
        if kind == "url":
            source = redact_url(payload)
            try:
                data = fetcher(payload, settings)
            except FetchError as exc:
                raise ApiError(exc.status, str(exc))
        else:
            source, data = payload
        try:
            decoded = decode_image(data, settings.max_pixels, settings.max_side)
        except ImageError as exc:
            raise ApiError(exc.status, str(exc))
        del data
        splat_id = str(uuid.uuid4())
        LOGGER.info("generate %s from %s (%dx%d)", splat_id, source, *decoded.original_size)
        return gpu_pool.submit(gpu_stage, splat_id, decoded, source, started).result()

    async def read_body_capped(request: Request, limit: int) -> bytes:
        length = request.headers.get("content-length")
        if length is not None:
            if not length.isdigit():
                raise ApiError(400, "invalid Content-Length")
            if int(length) > limit:
                raise ApiError(413, "request body too large")
        body = bytearray()

        async def _read() -> None:
            async for chunk in request.stream():
                body.extend(chunk)
                if len(body) > limit:
                    raise ApiError(413, "request body too large")

        # The admission slot is already held: a client that never finishes its body must not
        # keep it forever.
        try:
            await asyncio.wait_for(_read(), timeout=settings.body_read_timeout)
        except TimeoutError:
            raise ApiError(408, "timed out reading request body")
        return bytes(body)

    async def parse_generate_input(request: Request):
        ctype = request.headers.get("content-type", "").split(";")[0].strip().lower()
        if ctype == "application/json":
            raw = await read_body_capped(request, settings.max_json_bytes)
            try:
                body = json.loads(raw)
            except ValueError:
                raise ApiError(400, "invalid JSON")
            url = body.get("image_url") if isinstance(body, dict) else None
            if not isinstance(url, str) or not url.strip():
                raise ApiError(400, 'JSON body must be {"image_url": "<http(s) URL>"}')
            return "url", url.strip()
        if ctype == "multipart/form-data":
            # Multipart overhead is small; allow 64KB on top of the file limit.
            raw = await read_body_capped(request, settings.max_upload_bytes + 64 * 1024)
            request._body = raw  # Starlette's form parser reads the cached body
            try:
                form = await request.form(max_files=1, max_fields=5)
            except Exception:
                raise ApiError(400, "invalid multipart body")
            try:
                upload = form.get("file")
                if upload is None or isinstance(upload, str):
                    raise ApiError(400, 'multipart field "file" is required')
                data = await upload.read()
                name = upload.filename or "upload"
            finally:
                await form.close()
            if len(data) > settings.max_upload_bytes:
                raise ApiError(413, "image is too large")
            return "file", (f"upload:{Path(name).name[:100]}", data)
        raise ApiError(415, "Content-Type must be application/json or multipart/form-data")

    # ---- routes -------------------------------------------------------------------------------
    @app.get("/health")
    async def health():
        return {"ok": True, "gpu": state["engine"].gpu_name}

    @app.post("/generate")
    async def generate(request: Request):
        started = time.perf_counter()
        if not slots.acquire(blocking=False):
            raise ApiError(503, "server busy, try again later")
        handed_off = False
        try:
            kind, payload = await parse_generate_input(request)
            future = io_pool.submit(pipeline, kind, payload, started)
            future.add_done_callback(lambda _f: slots.release())
            handed_off = True
        finally:
            if not handed_off:
                slots.release()
        meta = await asyncio.wrap_future(future)
        return {"id": meta["id"], "ply_url": meta["ply_url"], "seconds": meta["seconds"]}

    @app.get("/splats/{name}")
    async def get_splat(name: str):
        if not name.endswith(".ply"):
            raise ApiError(404, "not found")
        splat_id = parse_id(name[:-4])
        if splat_id is None or splat_id != name[:-4].lower():
            raise ApiError(404, "not found")
        # Open the file here, before responding: on Windows an open handle blocks deletion, so
        # eviction cannot remove it mid-download (eviction logs and retries later). If eviction
        # wins the race before we open, this is a clean 404 instead of a broken 200.
        handle = await asyncio.to_thread(store.open_ply, splat_id)
        if handle is None:
            raise ApiError(404, "not found")
        size = os.fstat(handle.fileno()).st_size

        def chunks():
            with handle:
                while block := handle.read(1024 * 1024):
                    yield block

        return StreamingResponse(
            chunks(),
            media_type="application/octet-stream",
            headers={
                "Content-Length": str(size),
                "Content-Disposition": f'attachment; filename="{splat_id}.ply"',
            },
        )

    @app.get("/list")
    async def list_splats():
        return {"splats": await asyncio.to_thread(store.list)}

    return app


def main() -> None:
    import argparse

    import uvicorn

    ap = argparse.ArgumentParser(description="splat-server")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8000)
    args = ap.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    # Single process, no reload: the model and the GPU lock live in this process.
    uvicorn.run(create_app(), host=args.host, port=args.port, workers=1, reload=False,
                timeout_keep_alive=30)


if __name__ == "__main__":
    main()
