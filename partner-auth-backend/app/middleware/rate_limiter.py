"""Rate limiting middleware using slowapi.

Enforces max 60 requests/minute per user on the /api/token endpoint.
Returns HTTP 429 with retry_after when the limit is exceeded.
"""

from fastapi import Request, Response
from slowapi import Limiter
from slowapi.errors import RateLimitExceeded
from slowapi.util import get_remote_address
from starlette.responses import JSONResponse


def _get_user_identifier(request: Request) -> str:
    """Extract a rate-limit key from the request.

    Uses the user_id query parameter if present, otherwise falls back
    to the remote IP address.
    """
    user_id = request.query_params.get("user_id")
    if user_id:
        return user_id
    return get_remote_address(request)


# Create the limiter instance with user-based key function
limiter = Limiter(key_func=_get_user_identifier)


def rate_limit_exceeded_handler(request: Request, exc: RateLimitExceeded) -> Response:
    """Custom handler for rate limit exceeded errors.

    Returns HTTP 429 with a JSON body containing error info and retry_after.
    """
    # Extract the retry-after value from the exception headers if available
    retry_after_seconds = "60"
    if hasattr(exc, "headers") and exc.headers:
        retry_after_seconds = exc.headers.get("Retry-After", "60")

    return JSONResponse(
        status_code=429,
        content={
            "error": "rate_limited",
            "retry_after": int(retry_after_seconds),
        },
        headers={"Retry-After": retry_after_seconds},
    )
