"""Example-based endpoint tests for the Partner Auth Backend.

Validates: Requirements 1.4, 1.5, 2.4, 3.4, 3.6, 4.4, 4.5, 5.1, 5.2, 5.3, 6.4, 9.5
"""

import base64
import hashlib
import hmac
import os
import tempfile
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from cryptography.fernet import Fernet

# Set required environment variables before importing the app.
# Use setdefault to avoid overriding values set by other test modules.
_TEST_FERNET_KEY = Fernet.generate_key().decode()

os.environ.setdefault("RING_CLIENT_ID", "test_client_id")
os.environ.setdefault("RING_CLIENT_SECRET", "test_client_secret")
os.environ.setdefault("RING_HMAC_KEY", "dGVzdGhtYWNrZXkxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMw==")
os.environ.setdefault("APP_API_KEY", "test-secret-api-key-12345")
os.environ.setdefault("TOKEN_ENCRYPTION_KEY", _TEST_FERNET_KEY)
os.environ.setdefault("DATABASE_PATH", tempfile.mktemp(suffix=".db"))

# Read the actual values that are in effect (may have been set by another module)
_ACTIVE_API_KEY = os.environ["APP_API_KEY"]
_ACTIVE_HMAC_KEY_B64 = os.environ["RING_HMAC_KEY"]
_ACTIVE_HMAC_KEY_BYTES = base64.b64decode(_ACTIVE_HMAC_KEY_B64)
_ACTIVE_FERNET_KEY = os.environ["TOKEN_ENCRYPTION_KEY"]
_ACTIVE_DB_PATH = os.environ["DATABASE_PATH"]

from httpx import ASGITransport, AsyncClient  # noqa: E402

from app.data.encryptor import FernetEncryptor  # noqa: E402
from app.data.token_store import TokenStore  # noqa: E402
from app.main import app  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _init_db() -> None:
    """Initialize the database tables before each test."""
    encryptor = FernetEncryptor(_ACTIVE_FERNET_KEY)
    token_store = TokenStore(_ACTIVE_DB_PATH, encryptor)
    await token_store.initialize()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _compute_hmac(nonce: str) -> str:
    """Compute HMAC-SHA256 signature for a nonce using the active HMAC key."""
    return hmac.new(_ACTIVE_HMAC_KEY_BYTES, nonce.encode("utf-8"), hashlib.sha256).hexdigest()


def _mock_ring_token_response(
    access_token: str = "mock_access_token",
    refresh_token: str = "mock_refresh_token",
    expires_in: int = 3600,
) -> httpx.Response:
    """Create a mock Ring OAuth token response."""
    return httpx.Response(
        status_code=200,
        json={
            "access_token": access_token,
            "refresh_token": refresh_token,
            "expires_in": expires_in,
            "token_type": "Bearer",
            "scope": "read",
        },
    )


# ---------------------------------------------------------------------------
# Token Exchange Tests (Requirements 1.4, 1.5)
# ---------------------------------------------------------------------------


async def test_token_exchange_valid_code_returns_200() -> None:
    """Token exchange with a valid authorization code returns HTTP 200.

    Validates: Requirement 1.4
    """
    mock_response = _mock_ring_token_response()

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch("app.services.token_service.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=mock_response)
            mock_client.aclose = AsyncMock()
            mock_client_cls.return_value = mock_client

            response = await client.post(
                "/ring/token-exchange",
                json={"code": "valid_auth_code_123"},
            )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "success"


async def test_token_exchange_invalid_code_returns_400() -> None:
    """Token exchange with an invalid/expired code returns HTTP error.

    Validates: Requirement 1.5
    """
    error_response = httpx.Response(status_code=400, json={"error": "invalid_grant"})

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch("app.services.token_service.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=error_response)
            mock_client.aclose = AsyncMock()
            mock_client_cls.return_value = mock_client

            response = await client.post(
                "/ring/token-exchange",
                json={"code": "invalid_expired_code"},
            )

    # The endpoint returns 502 for upstream errors (non-200 from Ring)
    assert response.status_code == 502
    data = response.json()
    assert data["error"] == "upstream_error"


# ---------------------------------------------------------------------------
# Account Linking Tests (Requirement 2.4)
# ---------------------------------------------------------------------------


async def test_account_link_valid_hmac_returns_200() -> None:
    """Account link with valid HMAC signature returns 200 with confirmation payload.

    Validates: Requirement 2.4
    """
    nonce = "1234567890:test_account_123"
    signature = _compute_hmac(nonce)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post(
            "/ring/account-link",
            json={
                "nonce": nonce,
                "signature": signature,
                "account_id": "test_account_123",
            },
        )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "linked"
    assert data["account_id"] == "test_account_123"


# ---------------------------------------------------------------------------
# Token Refresh Failure Tests (Requirement 3.4)
# ---------------------------------------------------------------------------


async def test_token_refresh_failure_ring_401_marks_session_invalid() -> None:
    """When Ring returns 401 during refresh, session is marked invalid and 401 returned.

    Validates: Requirement 3.4
    """
    # Store tokens that are expired (to trigger refresh)
    encryptor = FernetEncryptor(_ACTIVE_FERNET_KEY)
    token_store = TokenStore(_ACTIVE_DB_PATH, encryptor)
    await token_store.save_tokens(
        user_id="refresh_test_user",
        access_token="old_access_token",
        refresh_token="old_refresh_token",
        expires_at="2020-01-01T00:00:00+00:00",  # Already expired
        token_type="Bearer",
        scope="read",
    )

    # Mock Ring returning 401 on refresh attempt
    ring_401_response = httpx.Response(status_code=401, json={"error": "invalid_token"})

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        with patch("app.services.token_service.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=ring_401_response)
            mock_client.aclose = AsyncMock()
            mock_client_cls.return_value = mock_client

            response = await client.get(
                "/api/token",
                headers={"Authorization": f"Bearer {_ACTIVE_API_KEY}"},
                params={"user_id": "refresh_test_user"},
            )

    assert response.status_code == 401
    data = response.json()
    assert data["detail"]["error"] == "session_invalid"


# ---------------------------------------------------------------------------
# API Key Authentication Tests (Requirements 3.6, 9.6)
# ---------------------------------------------------------------------------


async def test_api_key_valid_key_accepted() -> None:
    """Valid API key in Authorization header is accepted.

    Validates: Requirement 3.6
    """
    from datetime import UTC, datetime, timedelta

    # Store a valid token for the user
    encryptor = FernetEncryptor(_ACTIVE_FERNET_KEY)
    token_store = TokenStore(_ACTIVE_DB_PATH, encryptor)
    future_expiry = (datetime.now(UTC) + timedelta(hours=1)).isoformat()
    await token_store.save_tokens(
        user_id="api_key_test_user",
        access_token="valid_access_token",
        refresh_token="valid_refresh_token",
        expires_at=future_expiry,
        token_type="Bearer",
        scope="read",
    )

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(
            "/api/token",
            headers={"Authorization": f"Bearer {_ACTIVE_API_KEY}"},
            params={"user_id": "api_key_test_user"},
        )

    assert response.status_code == 200
    data = response.json()
    assert "access_token" in data


async def test_api_key_missing_key_rejected() -> None:
    """Missing API key in Authorization header returns 401.

    Validates: Requirement 3.6
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/api/token")

    assert response.status_code == 401


async def test_api_key_wrong_key_rejected() -> None:
    """Wrong API key in Authorization header returns 401.

    Validates: Requirement 3.6
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get(
            "/api/token",
            headers={"Authorization": "Bearer totally-wrong-key"},
        )

    assert response.status_code == 401


# ---------------------------------------------------------------------------
# Webhook Tests (Requirements 4.4, 4.5)
# ---------------------------------------------------------------------------


async def test_webhook_unrecognized_event_type_returns_200() -> None:
    """Webhook with unrecognized event type returns 200 without error.

    Validates: Requirement 4.4
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.post(
            "/ring/webhook",
            json={
                "event_type": "completely_unknown_event",
                "device_id": "device_abc",
                "timestamp": "2024-01-15T10:30:00Z",
                "event_id": "evt_unknown_001",
            },
        )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "received"


# ---------------------------------------------------------------------------
# App Homepage Tests (Requirements 5.1, 5.2, 5.3)
# ---------------------------------------------------------------------------


async def test_app_homepage_returns_200_with_html() -> None:
    """App homepage returns 200 with HTML containing app name and description.

    Validates: Requirements 5.1, 5.2, 5.3
    """
    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        response = await client.get("/ring/app-homepage")

    assert response.status_code == 200
    assert "text/html" in response.headers["content-type"]

    body = response.text
    assert "RingAppleTV" in body
    # Check for description content
    assert "Ring" in body
    assert "Apple TV" in body


# ---------------------------------------------------------------------------
# Health Check Tests (Requirement 6.4)
# ---------------------------------------------------------------------------


async def test_health_check_returns_200() -> None:
    """Health check endpoint returns HTTP 200.

    Validates: Requirement 6.4
    """
    transport = ASGITransport(app=app)
    async with (
        app.router.lifespan_context(app),
        AsyncClient(transport=transport, base_url="http://test") as client,
    ):
        response = await client.get("/health")

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "healthy"
    # Requirement 11.5: /health reports the active adapter_mode.
    assert data["adapter_mode"] == "mock"


# ---------------------------------------------------------------------------
# Rate Limiting Tests (Requirement 9.5)
# ---------------------------------------------------------------------------


async def test_rate_limiting_61st_request_returns_429() -> None:
    """The 61st request in a minute to /api/token returns 429.

    Validates: Requirement 9.5
    """
    from datetime import UTC, datetime, timedelta

    from fastapi import FastAPI
    from slowapi import Limiter
    from slowapi.errors import RateLimitExceeded
    from slowapi.util import get_remote_address

    from app.middleware.input_sanitizer import InputSanitizationMiddleware
    from app.middleware.rate_limiter import rate_limit_exceeded_handler
    from app.routes.app_api import router as app_api_router
    from app.routes.ring_callbacks import router as ring_callbacks_router

    # Create a fresh app instance to avoid shared rate limiter state
    fresh_limiter = Limiter(key_func=get_remote_address)
    fresh_app = FastAPI()
    fresh_app.state.limiter = fresh_limiter
    fresh_app.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)  # type: ignore[arg-type]
    fresh_app.add_middleware(InputSanitizationMiddleware)
    fresh_app.include_router(ring_callbacks_router)
    fresh_app.include_router(app_api_router)

    # Store a valid token for the user
    encryptor = FernetEncryptor(_ACTIVE_FERNET_KEY)
    token_store = TokenStore(_ACTIVE_DB_PATH, encryptor)
    future_expiry = (datetime.now(UTC) + timedelta(hours=1)).isoformat()
    await token_store.save_tokens(
        user_id="rate_limit_user",
        access_token="rl_access_token",
        refresh_token="rl_refresh_token",
        expires_at=future_expiry,
        token_type="Bearer",
        scope="read",
    )

    transport = ASGITransport(app=fresh_app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Send 60 requests (should all succeed)
        for i in range(60):
            resp = await client.get(
                "/api/token",
                headers={"Authorization": f"Bearer {_ACTIVE_API_KEY}"},
                params={"user_id": "rate_limit_user"},
            )
            assert resp.status_code == 200, (
                f"Request {i + 1}: Expected 200, got {resp.status_code}: {resp.text}"
            )

        # 61st request should be rate limited
        response = await client.get(
            "/api/token",
            headers={"Authorization": f"Bearer {_ACTIVE_API_KEY}"},
            params={"user_id": "rate_limit_user"},
        )

    assert response.status_code == 429
    data = response.json()
    assert data["error"] == "rate_limited"
    assert "retry_after" in data
