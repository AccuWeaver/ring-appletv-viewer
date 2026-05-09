"""Property tests for request logging completeness.

# Feature: partner-auth-backend, Property 12: Request logging completeness
"""

import logging
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
# Strategies for generating HTTP requests
# ---------------------------------------------------------------------------

# Valid HTTP methods
http_methods = st.sampled_from(["GET", "POST", "PUT", "DELETE", "PATCH"])

# Valid URL paths (simple, safe paths)
url_paths = st.sampled_from(
    [
        "/health",
        "/api/token",
        "/ring/app-homepage",
    ]
)

# UUID pattern for request_id
UUID_PATTERN = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")

# ISO 8601 timestamp pattern
TIMESTAMP_PATTERN = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}")


class LogCapture(logging.Handler):
    """Simple log handler that captures log records for testing."""

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)

    def clear(self) -> None:
        self.records.clear()


# Create a shared log capture handler
_log_capture = LogCapture()
_log_capture.setLevel(logging.DEBUG)
logging.getLogger("app.main").addHandler(_log_capture)
logging.getLogger("app.main").setLevel(logging.DEBUG)


# ---------------------------------------------------------------------------
# Property 12: Request logging completeness
# ---------------------------------------------------------------------------


@settings(max_examples=100)
@given(method=http_methods, path=url_paths)
async def test_request_logging_completeness(method: str, path: str) -> None:
    """Property 12: Request logging completeness

    For any HTTP request, the log entry SHALL contain timestamp, unique request ID,
    method, and path.

    **Validates: Requirements 6.5**
    """
    _log_capture.clear()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        await client.request(method, path)

    # Find the request log entry
    log_messages = [
        record.message for record in _log_capture.records if "request_id=" in record.message
    ]

    assert len(log_messages) > 0, f"No request log entry found for {method} {path}"

    log_entry = log_messages[-1]

    # Verify timestamp is present
    assert "timestamp=" in log_entry, (
        f"Log entry missing timestamp for {method} {path}: {log_entry}"
    )
    # Extract and validate timestamp format
    timestamp_match = re.search(r"timestamp=(\S+)", log_entry)
    assert timestamp_match is not None, f"Could not extract timestamp from: {log_entry}"
    assert TIMESTAMP_PATTERN.match(timestamp_match.group(1)), (
        f"Timestamp not in ISO format: {timestamp_match.group(1)}"
    )

    # Verify request_id is present and is a valid UUID
    assert "request_id=" in log_entry, (
        f"Log entry missing request_id for {method} {path}: {log_entry}"
    )
    request_id_match = re.search(r"request_id=(\S+)", log_entry)
    assert request_id_match is not None, f"Could not extract request_id from: {log_entry}"
    assert UUID_PATTERN.match(request_id_match.group(1)), (
        f"request_id not a valid UUID: {request_id_match.group(1)}"
    )

    # Verify method is present
    assert f"method={method}" in log_entry, f"Log entry missing method={method}: {log_entry}"

    # Verify path is present
    assert f"path={path}" in log_entry, f"Log entry missing path={path}: {log_entry}"


async def test_request_id_in_response_header() -> None:
    """The X-Request-ID response header SHALL contain a valid UUID."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/health")

    request_id = response.headers.get("X-Request-ID")
    assert request_id is not None, "X-Request-ID header missing from response"
    assert UUID_PATTERN.match(request_id), f"X-Request-ID is not a valid UUID: {request_id}"
