"""Property tests for API key authentication.

# Feature: partner-auth-backend, Property 10: API key rejection
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
from hypothesis import assume, given, settings  # noqa: E402
from hypothesis import strategies as st  # noqa: E402

from app.main import app  # noqa: E402


@settings(max_examples=100)
@given(
    invalid_key=st.text(
        alphabet=st.characters(whitelist_categories=("L", "N", "P", "S"), max_codepoint=127),
        min_size=1,
        max_size=200,
    ),
)
async def test_api_key_rejection(invalid_key: str) -> None:
    """Property 10: API key rejection

    For any random string not equal to the configured API key, the token
    endpoint SHALL return HTTP 401.

    **Validates: Requirements 9.6**
    """
    assume(invalid_key != _TEST_API_KEY)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(
            "/api/token",
            headers={"Authorization": f"Bearer {invalid_key}"},
        )

    assert response.status_code == 401, (
        f"Expected 401 for invalid API key {invalid_key!r}, got {response.status_code}"
    )


async def test_missing_api_key_returns_401() -> None:
    """Requests without an Authorization header SHALL return HTTP 401."""
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/token")

    assert response.status_code == 401, (
        f"Expected 401 for missing API key, got {response.status_code}"
    )
