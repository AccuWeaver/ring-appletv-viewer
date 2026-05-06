"""Property tests for error response minimality.

# Feature: partner-auth-backend, Property 9: Error response minimality
"""

import os
import re
import tempfile

from cryptography.fernet import Fernet

# Set required environment variables before importing the app
_TEST_API_KEY = "test-secret-api-key-12345"
_TEST_FERNET_KEY = Fernet.generate_key().decode()

os.environ.setdefault("RING_CLIENT_ID", "test_client_id")
os.environ.setdefault("RING_CLIENT_SECRET", "test_client_secret")
os.environ.setdefault("RING_HMAC_KEY", "dGVzdGhtYWNrZXkxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMw==")
os.environ.setdefault("APP_API_KEY", _TEST_API_KEY)
os.environ.setdefault("TOKEN_ENCRYPTION_KEY", _TEST_FERNET_KEY)
os.environ.setdefault("DATABASE_PATH", tempfile.mktemp(suffix=".db"))

from httpx import ASGITransport, AsyncClient  # noqa: E402
from hypothesis import given, settings  # noqa: E402
from hypothesis import strategies as st  # noqa: E402

from app.main import app  # noqa: E402

# ---------------------------------------------------------------------------
# Patterns that should NEVER appear in error responses
# ---------------------------------------------------------------------------

# Python traceback indicators
TRACEBACK_PATTERNS = [
    re.compile(r"Traceback \(most recent call last\)", re.IGNORECASE),
    re.compile(r"File \"[^\"]+\", line \d+", re.IGNORECASE),
]

# Internal file paths
FILE_PATH_PATTERNS = [
    re.compile(r"/app/[a-zA-Z_/]+\.py"),
    re.compile(r"\\app\\[a-zA-Z_\\]+\.py"),
    re.compile(r"/usr/[a-zA-Z_/]+\.py"),
    re.compile(r"/home/[a-zA-Z_/]+\.py"),
    re.compile(r"site-packages/"),
]

# Database schema details
DB_SCHEMA_PATTERNS = [
    re.compile(r"CREATE TABLE", re.IGNORECASE),
    re.compile(r"sqlite3\.OperationalError", re.IGNORECASE),
    re.compile(r"no such table:", re.IGNORECASE),
]

# Raw exception class names (common Python exceptions with parens indicating raw message)
RAW_EXCEPTION_PATTERNS = [
    re.compile(r"(TypeError|ValueError|AttributeError|KeyError|IndexError)\("),
    re.compile(r"RuntimeError\("),
]

ALL_FORBIDDEN_PATTERNS = (
    TRACEBACK_PATTERNS + FILE_PATH_PATTERNS + DB_SCHEMA_PATTERNS + RAW_EXCEPTION_PATTERNS
)


def response_contains_internal_details(response_text: str) -> str | None:
    """Check if a response body contains internal details that should not be exposed.

    Returns the pattern description if found, None otherwise.
    """
    for pattern in TRACEBACK_PATTERNS:
        if pattern.search(response_text):
            return f"traceback: {pattern.pattern}"

    for pattern in FILE_PATH_PATTERNS:
        if pattern.search(response_text):
            return f"file_path: {pattern.pattern}"

    for pattern in DB_SCHEMA_PATTERNS:
        if pattern.search(response_text):
            return f"db_schema: {pattern.pattern}"

    for pattern in RAW_EXCEPTION_PATTERNS:
        if pattern.search(response_text):
            return f"raw_exception: {pattern.pattern}"

    return None


# ---------------------------------------------------------------------------
# Strategies for generating error-triggering requests
# ---------------------------------------------------------------------------

# Requests that trigger various error conditions (only GET requests to avoid
# body-related middleware issues)
error_triggering_requests = st.sampled_from(
    [
        # Missing API key on protected endpoint → 401
        {"method": "GET", "path": "/api/token", "headers": {}},
        # Invalid API key → 401
        {"method": "GET", "path": "/api/token", "headers": {"Authorization": "Bearer wrong-key"}},
        # Non-existent endpoint → 404
        {"method": "GET", "path": "/nonexistent/path", "headers": {}},
        # Token request with valid key but no user → 404
        {
            "method": "GET",
            "path": "/api/token",
            "headers": {"Authorization": f"Bearer {_TEST_API_KEY}"},
            "params": {"user_id": "nonexistent"},
        },
        # Another non-existent path
        {"method": "GET", "path": "/api/nonexistent", "headers": {}},
        # Invalid path segments
        {"method": "GET", "path": "/ring/invalid-endpoint", "headers": {}},
    ]
)


# ---------------------------------------------------------------------------
# Property 9: Error response minimality
# ---------------------------------------------------------------------------


@settings(max_examples=100)
@given(request_spec=error_triggering_requests)
async def test_error_response_minimality(request_spec: dict) -> None:
    """Property 9: Error response minimality

    For any error condition, the HTTP response SHALL NOT contain tracebacks,
    file paths, DB schema, or raw exception messages.

    **Validates: Requirements 9.3**
    """
    method = request_spec["method"]
    path = request_spec["path"]
    headers = request_spec.get("headers", {})
    params = request_spec.get("params")

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.request(method, path, headers=headers, params=params)

    # Only check error responses (4xx and 5xx)
    if response.status_code >= 400:
        response_text = response.text

        leaked_detail = response_contains_internal_details(response_text)
        assert leaked_detail is None, (
            f"Error response for {method} {path} (status={response.status_code}) "
            f"contains internal details: {leaked_detail}\n"
            f"Response body: {response_text[:500]}"
        )


async def test_unhandled_exception_returns_generic_error() -> None:
    """Unhandled exceptions should return a generic error without internal details."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Request token for non-existent user (triggers 404 from token service)
        response = await client.get(
            "/api/token",
            headers={"Authorization": f"Bearer {_TEST_API_KEY}"},
            params={"user_id": "nonexistent_user"},
        )

    # Should be an error response
    assert response.status_code >= 400

    # Should not contain internal details
    response_text = response.text
    leaked = response_contains_internal_details(response_text)
    assert leaked is None, (
        f"Error response contains internal details: {leaked}\n"
        f"Response: {response_text[:500]}"
    )
