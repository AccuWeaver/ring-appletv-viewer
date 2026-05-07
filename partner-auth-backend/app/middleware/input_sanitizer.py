"""Input validation and sanitization middleware.

Validates and sanitizes all incoming request parameters to prevent:
- SQL injection patterns
- Script injection (XSS)
- Null byte injection

Uses a pure ASGI middleware approach to avoid BaseHTTPMiddleware's
exception handling issues with ExceptionGroups.
"""

import re
from urllib.parse import parse_qs

from starlette.responses import JSONResponse
from starlette.types import ASGIApp, Receive, Scope, Send

# Patterns that indicate potential injection attacks
SQL_INJECTION_PATTERNS = [
    re.compile(
        r"(\b(SELECT|INSERT|UPDATE|DELETE|DROP|ALTER|CREATE|EXEC|UNION)\b\s)", re.IGNORECASE
    ),
    re.compile(r"(--|;)\s*(DROP|ALTER|DELETE|INSERT|UPDATE|SELECT)", re.IGNORECASE),
    re.compile(r"'\s*(OR|AND)\s+.+=\s*.+", re.IGNORECASE),
    re.compile(r"'\s*;\s*(DROP|ALTER|DELETE|INSERT|UPDATE)", re.IGNORECASE),
]

SCRIPT_INJECTION_PATTERNS = [
    re.compile(r"<\s*script[^>]*>", re.IGNORECASE),
    re.compile(r"javascript\s*:", re.IGNORECASE),
    re.compile(r"on\w+\s*=\s*[\"']", re.IGNORECASE),
    re.compile(r"<\s*/\s*script\s*>", re.IGNORECASE),
]

NULL_BYTE_PATTERN = re.compile(r"\x00")


def contains_dangerous_pattern(value: str) -> str | None:
    """Check if a string contains dangerous patterns.

    Returns the type of dangerous pattern found, or None if safe.
    """
    if NULL_BYTE_PATTERN.search(value):
        return "null_byte"

    for pattern in SQL_INJECTION_PATTERNS:
        if pattern.search(value):
            return "sql_injection"

    for pattern in SCRIPT_INJECTION_PATTERNS:
        if pattern.search(value):
            return "script_injection"

    return None


class InputSanitizationMiddleware:
    """Pure ASGI middleware that validates request parameters for dangerous patterns."""

    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        """Check query parameters for injection patterns."""
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        # Parse query string from scope
        query_string = scope.get("query_string", b"").decode("utf-8", errors="replace")
        if query_string:
            params = parse_qs(query_string, keep_blank_values=True)
            for key, values in params.items():
                # Check the key
                threat = contains_dangerous_pattern(key)
                if threat:
                    response = JSONResponse(
                        status_code=400,
                        content={
                            "error": "validation_error",
                            "detail": "Invalid input detected in parameter name",
                        },
                    )
                    await response(scope, receive, send)
                    return

                # Check each value
                for value in values:
                    threat = contains_dangerous_pattern(value)
                    if threat:
                        response = JSONResponse(
                            status_code=400,
                            content={
                                "error": "validation_error",
                                "detail": f"Invalid input detected in parameter '{key}'",
                            },
                        )
                        await response(scope, receive, send)
                        return

        # Check path for null bytes
        path = scope.get("path", "")
        if contains_dangerous_pattern(path):
            response = JSONResponse(
                status_code=400,
                content={
                    "error": "validation_error",
                    "detail": "Invalid input detected in request path",
                },
            )
            await response(scope, receive, send)
            return

        await self.app(scope, receive, send)
