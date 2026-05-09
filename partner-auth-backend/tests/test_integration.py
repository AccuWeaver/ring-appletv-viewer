"""Integration tests for the Partner Auth Backend.

End-to-end flows testing multiple components working together.

Validates: Requirements 1.2, 2.2, 4.2, 6.8
"""

import base64
import hashlib
import hmac
import os
import subprocess
import sys
import tempfile
from unittest.mock import AsyncMock, patch

import httpx
import pytest
from cryptography.fernet import Fernet

# Set required environment variables before importing the app.
# Use setdefault to avoid overriding values set by other test modules.
_DEFAULT_FERNET_KEY = Fernet.generate_key().decode()

os.environ.setdefault("RING_CLIENT_ID", "test_client_id")
os.environ.setdefault("RING_CLIENT_SECRET", "test_client_secret")
os.environ.setdefault("RING_HMAC_KEY", "dGVzdGhtYWNrZXkxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMw==")
os.environ.setdefault("APP_API_KEY", "test-secret-api-key-12345")
os.environ.setdefault("TOKEN_ENCRYPTION_KEY", _DEFAULT_FERNET_KEY)
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


# ---------------------------------------------------------------------------
# Integration Test 1: End-to-end token exchange flow
# Validates: Requirement 1.2
# ---------------------------------------------------------------------------


async def test_e2e_token_exchange_flow() -> None:
    """End-to-end token exchange: code → Ring OAuth → store → retrieve.

    Simulates the full flow:
    1. Ring sends authorization code to /ring/token-exchange
    2. Backend exchanges code with Ring's OAuth server (mocked)
    3. Tokens are stored encrypted in SQLite
    4. tvOS app retrieves token via /api/token

    Validates: Requirement 1.2
    """
    mock_ring_response = httpx.Response(
        status_code=200,
        json={
            "access_token": "e2e_access_token_abc123",
            "refresh_token": "e2e_refresh_token_xyz789",
            "expires_in": 3600,
            "token_type": "Bearer",
            "scope": "read write",
        },
    )

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Step 1: Exchange authorization code
        with patch("app.services.token_service.httpx.AsyncClient") as mock_client_cls:
            mock_client = AsyncMock()
            mock_client.post = AsyncMock(return_value=mock_ring_response)
            mock_client.aclose = AsyncMock()
            mock_client_cls.return_value = mock_client

            exchange_response = await client.post(
                "/ring/token-exchange",
                json={"code": "e2e_auth_code_456"},
            )

        assert exchange_response.status_code == 200
        assert exchange_response.json()["status"] == "success"

        # Step 2: Retrieve the token via the app API
        token_response = await client.get(
            "/api/token",
            headers={"Authorization": f"Bearer {_ACTIVE_API_KEY}"},
            params={"user_id": "default"},
        )

    assert token_response.status_code == 200
    token_data = token_response.json()
    assert token_data["access_token"] == "e2e_access_token_abc123"
    assert token_data["token_type"] == "Bearer"
    assert "expires_at" in token_data


# ---------------------------------------------------------------------------
# Integration Test 2: End-to-end account linking with real HMAC
# Validates: Requirement 2.2
# ---------------------------------------------------------------------------


async def test_e2e_account_linking_with_real_hmac() -> None:
    """End-to-end account linking: compute HMAC → send request → verify stored.

    Uses real HMAC-SHA256 computation (not mocked) to verify the full
    account linking flow from signature generation to user record creation.

    Validates: Requirement 2.2
    """
    account_id = "ring_user_account_42"
    nonce = f"1700000000:{account_id}"

    # Compute real HMAC-SHA256 signature
    signature = _compute_hmac(nonce)

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Send account link request
        response = await client.post(
            "/ring/account-link",
            json={
                "nonce": nonce,
                "signature": signature,
                "account_id": account_id,
                "partner_account_id": "partner_user_42",
            },
        )

    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "linked"
    assert data["account_id"] == account_id

    # Verify the user record was actually stored in the database
    import aiosqlite

    async with aiosqlite.connect(_ACTIVE_DB_PATH) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT user_id, account_id FROM users WHERE user_id = ?",
            ("partner_user_42",),
        )
        row = await cursor.fetchone()

    assert row is not None, "User record should exist after account linking"
    assert row["account_id"] == account_id

    # Verify that an invalid HMAC is rejected
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        bad_response = await client.post(
            "/ring/account-link",
            json={
                "nonce": nonce,
                "signature": "deadbeef" * 8,  # Wrong signature
                "account_id": account_id,
            },
        )

    assert bad_response.status_code == 403
    assert bad_response.json()["error"] == "forbidden"


# ---------------------------------------------------------------------------
# Integration Test 3: Webhook delivery → storage → retrieval cycle
# Validates: Requirement 4.2
# ---------------------------------------------------------------------------


async def test_e2e_webhook_delivery_storage_retrieval() -> None:
    """Webhook delivery → storage → retrieval: full event lifecycle.

    Sends multiple webhook events, then verifies they can be retrieved
    from the token store with all fields preserved.

    Validates: Requirement 4.2
    """
    events = [
        {
            "event_type": "motion",
            "device_id": "device_front_door",
            "timestamp": "2024-03-15T14:30:00Z",
            "event_id": "evt_integration_001",
            "payload_data": "motion detected",
        },
        {
            "event_type": "ding",
            "device_id": "device_doorbell",
            "timestamp": "2024-03-15T14:31:00Z",
            "event_id": "evt_integration_002",
            "payload_data": "doorbell pressed",
        },
        {
            "event_type": "device_status",
            "device_id": "device_camera_1",
            "timestamp": "2024-03-15T14:32:00Z",
            "event_id": "evt_integration_003",
            "payload_data": "battery low",
        },
    ]

    transport = ASGITransport(app=app)
    async with AsyncClient(transport=transport, base_url="http://test") as client:
        # Deliver all webhook events
        for event in events:
            response = await client.post("/ring/webhook", json=event)
            assert response.status_code == 200
            assert response.json()["status"] == "received"

    # Retrieve events from the store and verify
    encryptor = FernetEncryptor(_ACTIVE_FERNET_KEY)
    token_store = TokenStore(_ACTIVE_DB_PATH, encryptor)

    stored_events = await token_store.get_recent_events(limit=10)

    # Verify all events were stored
    stored_event_ids = {e["event_id"] for e in stored_events}
    for event in events:
        assert event["event_id"] in stored_event_ids, f"Event {event['event_id']} should be stored"

    # Verify field preservation for the first event
    evt_001 = next(e for e in stored_events if e["event_id"] == "evt_integration_001")
    assert evt_001["event_type"] == "motion"
    assert evt_001["device_id"] == "device_front_door"
    assert evt_001["timestamp"] == "2024-03-15T14:30:00Z"
    assert "received_at" in evt_001


# ---------------------------------------------------------------------------
# Integration Test 4: Startup with missing env vars
# Validates: Requirement 6.8
# ---------------------------------------------------------------------------


def test_startup_missing_env_vars_descriptive_error() -> None:
    """Startup with missing required env vars produces descriptive error and exits.

    Validates: Requirement 6.8
    """
    # Run a subprocess that imports the config with missing env vars
    test_script = """\
import os
import sys

# Clear all required env vars
for var in ["RING_CLIENT_ID", "RING_CLIENT_SECRET", "RING_HMAC_KEY",
            "APP_API_KEY", "TOKEN_ENCRYPTION_KEY"]:
    os.environ.pop(var, None)

# Disable python-dotenv so a checked-in .env file cannot silently re-populate
# the environment. load_dotenv() searches cwd and parents for a .env file by
# default, which would defeat this test's pop() calls above.
import dotenv
dotenv.load_dotenv = lambda *args, **kwargs: False

try:
    from app.config import get_settings
    settings = get_settings()
    # If we get here, the config didn't fail-fast
    print("ERROR: Config did not raise for missing vars", file=sys.stderr)
    sys.exit(0)
except Exception as exc:
    error_msg = str(exc)
    print(error_msg, file=sys.stderr)
    # Verify the error message mentions the missing variables
    missing_vars = ["RING_CLIENT_ID", "RING_CLIENT_SECRET", "RING_HMAC_KEY",
                    "APP_API_KEY", "TOKEN_ENCRYPTION_KEY"]
    all_mentioned = all(var in error_msg for var in missing_vars)
    if all_mentioned:
        sys.exit(1)  # Expected: fail-fast with descriptive error
    else:
        print(f"ERROR: Not all missing vars mentioned in: {error_msg}", file=sys.stderr)
        sys.exit(2)
"""
    # Build a clean environment without the required vars
    clean_env = {
        k: v
        for k, v in os.environ.items()
        if k
        not in {
            "RING_CLIENT_ID",
            "RING_CLIENT_SECRET",
            "RING_HMAC_KEY",
            "APP_API_KEY",
            "TOKEN_ENCRYPTION_KEY",
        }
    }

    result = subprocess.run(
        [sys.executable, "-c", test_script],
        capture_output=True,
        text=True,
        cwd=os.path.join(os.path.dirname(__file__), ".."),
        env=clean_env,
    )

    assert result.returncode == 1, (
        f"Expected exit code 1 (fail-fast with descriptive error), "
        f"got {result.returncode}.\nstderr: {result.stderr}\nstdout: {result.stdout}"
    )

    # Verify the error message mentions the missing variables
    stderr = result.stderr
    for var in [
        "RING_CLIENT_ID",
        "RING_CLIENT_SECRET",
        "RING_HMAC_KEY",
        "APP_API_KEY",
        "TOKEN_ENCRYPTION_KEY",
    ]:
        assert var in stderr, (
            f"Error message should mention missing variable '{var}'. Got: {stderr}"
        )
