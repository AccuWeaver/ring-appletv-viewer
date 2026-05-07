"""FastAPI application entry point.

Wires routers, middleware, lifespan-managed services, and global
exception handling. Validates configuration at startup; exits non-zero
if the unofficial adapter is selected without a refresh token
(Requirement 10.6).
"""

import logging
import sys
import time
import uuid
from contextlib import asynccontextmanager
from datetime import UTC, datetime

from fastapi import Depends, FastAPI, Request, Response
from fastapi.responses import JSONResponse
from slowapi.errors import RateLimitExceeded

from app.adapters.base import RingAdapter
from app.adapters.errors import RingAdapterError
from app.adapters.factory import create_adapter
from app.adapters.rate_limit import RateLimitGovernor
from app.adapters.session_map import StreamSessionMap
from app.config import ConfigurationError, get_settings
from app.data.encryptor import FernetEncryptor
from app.data.refresh_token_store import RefreshTokenStore
from app.data.token_store import TokenStore
from app.dependencies import get_ring_adapter
from app.middleware.input_sanitizer import InputSanitizationMiddleware
from app.middleware.rate_limiter import limiter, rate_limit_exceeded_handler
from app.routes.app_api import router as app_api_router
from app.routes.mock_ring_api import router as mock_ring_api_router
from app.routes.ring_callbacks import router as ring_callbacks_router
from app.services.auth import verify_api_key

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Lifespan — replaces the old @app.on_event("startup") hook.
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Startup → adapter creation; shutdown → adapter.aclose()."""
    try:
        settings = get_settings()
    except ConfigurationError as exc:
        logger.error("startup_failure reason=configuration error=%r", exc)
        # Fail fast (Req 10.6): do not start the HTTP server.
        sys.exit(1)

    logging.basicConfig(
        level=getattr(logging, settings.log_level.upper(), logging.INFO)
    )
    # Attach the redacting filter to the root logger (Req 3.8, 9.2, 9.5).
    from app.logging_redaction import install as install_log_redaction

    install_log_redaction()

    # Database init: TokenStore creates the existing tables; the refresh
    # token store shares the same SQLite file (Req 10.1 / 4.2) and just
    # adds its own table.
    encryptor = FernetEncryptor(settings.token_encryption_key)
    token_store = TokenStore(settings.database_path, encryptor)
    await token_store.initialize()
    refresh_store = RefreshTokenStore(settings.database_path, encryptor)
    await refresh_store.initialize()

    try:
        adapter = await create_adapter(settings)
    except ConfigurationError as exc:
        logger.error("startup_failure reason=adapter_config error=%r", exc)
        sys.exit(1)

    # Install the adapter singleton for all /mock/* routes (Req 7.3).
    app.dependency_overrides[get_ring_adapter] = lambda: adapter

    # Expose health-adapter dependencies on app.state for the endpoint
    # below to read without re-creating.
    app.state.adapter = adapter
    app.state.refresh_store = refresh_store
    app.state.governor = _extract_governor(adapter)
    app.state.session_map = _extract_session_map(adapter)

    logger.info("startup adapter_mode=%s", adapter.mode())  # Req 7.5

    try:
        yield
    finally:
        aclose = getattr(adapter, "aclose", None)
        if aclose is not None:
            await aclose()
        # The factory may have stashed a separate Ring-API httpx client
        # on the adapter; close it now if present.
        ring_http = getattr(adapter, "_ring_http", None)
        if ring_http is not None:
            await ring_http.aclose()
        logger.info("shutdown adapter_mode=%s", adapter.mode())


def _extract_governor(adapter: RingAdapter) -> RateLimitGovernor | None:
    """Return the adapter's internal rate-limit governor, if it has one.

    Only the `UnofficialRingAdapter` has a governor; the `MockRingAdapter`
    returns None here so `/health/adapter` can report 0 for mock mode.
    """
    client = getattr(adapter, "_client", None)
    if client is None:
        return None
    return getattr(client, "_governor", None)


def _extract_session_map(adapter: RingAdapter) -> StreamSessionMap | None:
    """Return the adapter's internal stream-session map, if it has one."""
    return getattr(adapter, "_sessions", None)


# ---------------------------------------------------------------------------
# App setup
# ---------------------------------------------------------------------------

app = FastAPI(
    title="Partner Auth Backend",
    description="Ring Partner API OAuth 2.0 authentication backend for RingAppleTV",
    version="0.1.0",
    lifespan=lifespan,
)

app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)  # type: ignore[arg-type]
app.add_middleware(InputSanitizationMiddleware)


# ---------------------------------------------------------------------------
# RingAdapterError handler — maps every adapter error to a stable envelope.
# Requirements 1.8, 11.2, 11.3.
# ---------------------------------------------------------------------------


@app.exception_handler(RingAdapterError)
async def ring_adapter_error_handler(
    request: Request, exc: RingAdapterError
) -> JSONResponse:
    """Translate an adapter error into a stable HTTP envelope.

    Body: ``{"error": "<code>"}``. Upstream Ring messages, stack traces,
    and file paths are never exposed to the client (Req 11.3).
    """
    request_id = getattr(request.state, "request_id", "unknown")
    adapter: RingAdapter | None = getattr(app.state, "adapter", None)
    mode = adapter.mode() if adapter is not None else "unknown"
    device_id = request.path_params.get("device_id") if request.path_params else None

    logger.warning(
        "adapter_error request_id=%s mode=%s code=%s status=%d "
        "device_id=%s operation=%s",
        request_id,
        mode,
        exc.code,
        exc.http_status,
        device_id,
        request.url.path,
    )
    return JSONResponse(
        status_code=exc.http_status,
        content={"error": exc.code},
    )


# ---------------------------------------------------------------------------
# Request logging middleware (unchanged).
# ---------------------------------------------------------------------------


@app.middleware("http")
async def request_logging_middleware(request: Request, call_next) -> Response:  # type: ignore[no-untyped-def]
    """Log timestamp, request_id, method, path, and timing for every request."""
    request_id = str(uuid.uuid4())
    start_time = time.time()
    timestamp = datetime.now(UTC).isoformat()
    request.state.request_id = request_id

    response: Response = await call_next(request)

    duration_ms = (time.time() - start_time) * 1000
    logger.info(
        "timestamp=%s request_id=%s method=%s path=%s status=%d duration_ms=%.1f",
        timestamp,
        request_id,
        request.method,
        request.url.path,
        response.status_code,
        duration_ms,
    )
    response.headers["X-Request-ID"] = request_id
    return response


# ---------------------------------------------------------------------------
# Unhandled-exception handler (existing; keep verbatim).
# ---------------------------------------------------------------------------


@app.exception_handler(Exception)
async def global_exception_handler(request: Request, exc: Exception) -> Response:
    """Catch unhandled exceptions and return a generic error response.

    Logs full error details server-side; returns only a generic message to callers.
    Never exposes tracebacks, file paths, DB schema, or raw exception messages.
    """
    import traceback

    request_id = getattr(request.state, "request_id", "unknown")
    logger.error(
        "Unhandled exception: request_id=%s method=%s path=%s error=%s traceback=%s",
        request_id,
        request.method,
        request.url.path,
        str(exc),
        traceback.format_exc(),
    )
    return JSONResponse(
        status_code=500,
        content={"error": "internal_error"},
    )


# ---------------------------------------------------------------------------
# Health endpoints.
# Requirements 11.5, 11.6.
# ---------------------------------------------------------------------------


@app.get("/health")
async def health_check(
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
) -> dict:
    """Public health check — reports the active adapter mode."""
    return {"status": "healthy", "adapter_mode": adapter.mode()}


@app.get("/health/adapter")
async def health_adapter(
    adapter: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
    _api_key: str = Depends(verify_api_key),  # noqa: B008
) -> dict:
    """Adapter-level diagnostics. API key required (Req 11.6)."""
    mode = adapter.mode()

    refresh_store = getattr(app.state, "refresh_store", None)
    governor = getattr(app.state, "governor", None)
    session_map = getattr(app.state, "session_map", None)

    if mode == "unofficial" and refresh_store is not None:
        refresh_token_valid: bool | None = await refresh_store.is_valid()
    else:
        refresh_token_valid = None

    active_stream_sessions = (
        await session_map.count() if session_map is not None else 0
    )

    if mode == "unofficial" and governor is not None:
        ring_api_requests_last_minute = await governor.current_rate()
    else:
        ring_api_requests_last_minute = 0

    return {
        "adapter_mode": mode,
        "refresh_token_valid": refresh_token_valid,
        "active_stream_sessions": active_stream_sessions,
        "ring_api_requests_last_minute": ring_api_requests_last_minute,
    }


# ---------------------------------------------------------------------------
# Router includes (unchanged).
# ---------------------------------------------------------------------------

app.include_router(ring_callbacks_router)
app.include_router(app_api_router)
app.include_router(mock_ring_api_router)
