"""Property tests for input sanitization.

# Feature: partner-auth-backend, Property 8: Input sanitization
"""

import os
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
from app.middleware.input_sanitizer import contains_dangerous_pattern  # noqa: E402

# ---------------------------------------------------------------------------
# Strategies for generating dangerous inputs
# ---------------------------------------------------------------------------

sql_injection_payloads = st.sampled_from(
    [
        "'; DROP TABLE users --",
        "' OR '1'='1",
        "'; DELETE FROM tokens;--",
        "' UNION SELECT * FROM tokens --",
        "1; UPDATE users SET role='admin'",
        "'; INSERT INTO users VALUES('hacker','pass');--",
        "' AND 1=1 --",
        "SELECT * FROM users WHERE 1=1",
        "'; ALTER TABLE users DROP COLUMN password;--",
        "' ; EXEC xp_cmdshell('dir') --",
    ]
)

script_injection_payloads = st.sampled_from(
    [
        "<script>alert('xss')</script>",
        "<SCRIPT>document.cookie</SCRIPT>",
        "<script src='evil.js'></script>",
        "javascript:alert(1)",
        '<img onerror="alert(1)" src=x>',
        '<div onmouseover="steal()">',
        "<Script>fetch('http://evil.com')</Script>",
        '<a href="javascript:void(0)">click</a>',
        "</script><script>alert('xss')</script>",
    ]
)

null_byte_payloads = st.sampled_from(
    [
        "file\x00.txt",
        "\x00admin",
        "user\x00\x00data",
        "path/to/\x00file",
        "\x00",
    ]
)

dangerous_payloads = st.one_of(
    sql_injection_payloads,
    script_injection_payloads,
    null_byte_payloads,
)


# ---------------------------------------------------------------------------
# Property 8: Input sanitization
# ---------------------------------------------------------------------------


@settings(max_examples=100)
@given(payload=dangerous_payloads)
async def test_input_sanitization_rejects_dangerous_query_params(payload: str) -> None:
    """Property 8: Input sanitization

    For any request parameter containing SQL injection, script injection, or null
    bytes, the validation layer SHALL reject or sanitize the dangerous pattern.

    **Validates: Requirements 9.2**
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(
            "/health",
            params={"input": payload},
        )

    # The middleware should reject the request with 400
    assert response.status_code == 400, (
        f"Expected 400 for dangerous payload {payload!r}, got {response.status_code}"
    )
    body = response.json()
    assert body["error"] == "validation_error"


@settings(max_examples=100)
@given(payload=dangerous_payloads)
async def test_input_sanitization_detects_dangerous_patterns(payload: str) -> None:
    """Property 8: Input sanitization (unit-level)

    For any string containing SQL injection, script injection, or null bytes,
    the contains_dangerous_pattern function SHALL detect the threat.

    **Validates: Requirements 9.2**
    """
    result = contains_dangerous_pattern(payload)
    assert result is not None, (
        f"Expected dangerous pattern detection for {payload!r}, got None"
    )
    assert result in ("sql_injection", "script_injection", "null_byte")


async def test_safe_input_passes_through() -> None:
    """Safe inputs should not be rejected by the sanitization middleware."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(
            "/health",
            params={"user_id": "default", "name": "John Doe"},
        )

    assert response.status_code == 200
