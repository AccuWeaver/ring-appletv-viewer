"""FastAPI application entry point.

Wires together routers, middleware, and service dependencies.
Validates configuration at startup (fail-fast).
"""

import logging
import time
import uuid
from datetime import UTC, datetime

from fastapi import FastAPI, Request, Response
from slowapi.errors import RateLimitExceeded

from app.config import get_settings
from app.middleware.input_sanitizer import InputSanitizationMiddleware
from app.middleware.rate_limiter import limiter, rate_limit_exceeded_handler
from app.routes.app_api import router as app_api_router
from app.routes.ring_callbacks import router as ring_callbacks_router

logger = logging.getLogger(__name__)

app = FastAPI(
    title="Partner Auth Backend",
    description="Ring Partner API OAuth 2.0 authentication backend for RingAppleTV",
    version="0.1.0",
)

# ---------------------------------------------------------------------------
# Rate limiting setup
# ---------------------------------------------------------------------------
app.state.limiter = limiter
app.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)  # type: ignore[arg-type]

# ---------------------------------------------------------------------------
# Input sanitization middleware
# ---------------------------------------------------------------------------
app.add_middleware(InputSanitizationMiddleware)


# ---------------------------------------------------------------------------
# Startup event: validate config and initialize database
# ---------------------------------------------------------------------------


@app.on_event("startup")
async def startup_event() -> None:
    """Validate configuration and initialize the database on startup."""
    # Fail-fast: raises ConfigurationError if required env vars are missing
    settings = get_settings()

    # Configure logging level from settings
    logging.basicConfig(level=getattr(logging, settings.log_level.upper(), logging.INFO))
    logger.info("Configuration validated successfully")

    # Database initialization placeholder — TokenStore will be wired in Task 3
    logger.info("Database initialization placeholder (TokenStore not yet implemented)")


# ---------------------------------------------------------------------------
# Request logging middleware
# ---------------------------------------------------------------------------


@app.middleware("http")
async def request_logging_middleware(request: Request, call_next) -> Response:  # type: ignore[no-untyped-def]
    """Log timestamp, request_id, method, path, and timing for every request."""
    request_id = str(uuid.uuid4())
    start_time = time.time()
    timestamp = datetime.now(UTC).isoformat()

    # Attach request_id to request state for downstream use
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

    # Include request ID in response headers for traceability
    response.headers["X-Request-ID"] = request_id
    return response


# ---------------------------------------------------------------------------
# Global exception handler — return minimal error details to callers
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

    from starlette.responses import JSONResponse

    return JSONResponse(
        status_code=500,
        content={"error": "internal_error"},
    )


# ---------------------------------------------------------------------------
# Health check endpoint
# ---------------------------------------------------------------------------


@app.get("/health")
async def health_check() -> dict:
    """Health check endpoint returning HTTP 200."""
    return {"status": "healthy"}


# ---------------------------------------------------------------------------
# Router includes
# ---------------------------------------------------------------------------

app.include_router(ring_callbacks_router)
app.include_router(app_api_router)
