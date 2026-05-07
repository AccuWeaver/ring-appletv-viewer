"""Property tests for token exchange and persistence round-trip.

# Feature: partner-auth-backend, Property 1: Token exchange and persistence round-trip
"""

import tempfile
from datetime import UTC, datetime, timedelta
from unittest.mock import AsyncMock

import httpx
from cryptography.fernet import Fernet
from hypothesis import given, settings
from hypothesis import strategies as st

from app.data.encryptor import FernetEncryptor
from app.data.token_store import TokenStore
from app.services.token_service import TokenService

# Generate a valid Fernet key for testing
TEST_FERNET_KEY = Fernet.generate_key().decode()


def _make_oauth_response(
    access_token: str,
    refresh_token: str,
    expires_in: int,
    scope: str | None,
) -> httpx.Response:
    """Create a mock httpx.Response simulating Ring's OAuth token endpoint."""
    body: dict = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "expires_in": expires_in,
        "token_type": "Bearer",
    }
    if scope is not None:
        body["scope"] = scope

    response = httpx.Response(
        status_code=200,
        json=body,
    )
    return response


@settings(max_examples=100)
@given(
    access_token=st.text(
        alphabet=st.characters(categories=("L", "N", "P", "S")),
        min_size=10,
        max_size=100,
    ),
    refresh_token=st.text(
        alphabet=st.characters(categories=("L", "N", "P", "S")),
        min_size=10,
        max_size=100,
    ),
    expires_in=st.integers(min_value=300, max_value=86400),
    scope=st.one_of(st.none(), st.text(min_size=1, max_size=50)),
)
async def test_token_exchange_persistence_round_trip(
    access_token: str,
    refresh_token: str,
    expires_in: int,
    scope: str | None,
) -> None:
    """Property 1: Token exchange and persistence round-trip

    For any valid authorization code and OAuth response, exchanging the code
    and reading back from TokenStore SHALL produce a TokenRecord with matching
    decrypted values.

    **Validates: Requirements 1.2, 1.3, 3.3**
    """
    # Set up a temporary SQLite database and real FernetEncryptor
    with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
        db_path = tmp.name

    encryptor = FernetEncryptor(TEST_FERNET_KEY)
    token_store = TokenStore(db_path, encryptor)
    await token_store.initialize()

    # Create a mock HTTP client that returns the generated OAuth response
    mock_response = _make_oauth_response(access_token, refresh_token, expires_in, scope)
    mock_client = AsyncMock(spec=httpx.AsyncClient)
    mock_client.post = AsyncMock(return_value=mock_response)

    # Create TokenService with the mock client
    token_service = TokenService(
        client_id="test_client_id",
        client_secret="test_client_secret",
        token_store=token_store,
        http_client=mock_client,
    )

    # Record time before exchange to validate expires_at
    before_exchange = datetime.now(UTC)

    # Exchange the code
    user_id = "test_user"
    result = await token_service.exchange_code(code="random_auth_code", user_id=user_id)

    after_exchange = datetime.now(UTC)

    # Read back from the token store
    stored = await token_store.get_tokens(user_id)

    # Assert tokens were stored and can be read back
    assert stored is not None, "Tokens should be stored after exchange"

    # Assert decrypted access_token matches original
    assert stored["access_token"] == access_token, (
        f"Stored access_token {stored['access_token']!r} != original {access_token!r}"
    )

    # Assert decrypted refresh_token matches original
    assert stored["refresh_token"] == refresh_token, (
        f"Stored refresh_token {stored['refresh_token']!r} != original {refresh_token!r}"
    )

    # Assert expires_at is approximately correct (within a few seconds tolerance)
    stored_expires_at = datetime.fromisoformat(stored["expires_at"])
    expected_min = before_exchange + timedelta(seconds=expires_in)
    expected_max = after_exchange + timedelta(seconds=expires_in)

    # Allow 5 seconds tolerance for test execution time
    tolerance = timedelta(seconds=5)
    assert stored_expires_at >= expected_min - tolerance, (
        f"expires_at {stored_expires_at} is too early "
        f"(expected >= {expected_min - tolerance})"
    )
    assert stored_expires_at <= expected_max + tolerance, (
        f"expires_at {stored_expires_at} is too late "
        f"(expected <= {expected_max + tolerance})"
    )

    # Assert token_type matches
    assert stored["token_type"] == "Bearer"

    # Assert scope matches
    assert stored["scope"] == scope, (
        f"Stored scope {stored['scope']!r} != original {scope!r}"
    )

    # Assert the exchange result also matches
    assert result["access_token"] == access_token
    assert result["refresh_token"] == refresh_token
    assert result["scope"] == scope


# Feature: partner-auth-backend, Property 4: Proactive token refresh decision (backend)


@settings(max_examples=100)
@given(
    offset_seconds=st.integers(min_value=-3600, max_value=3600),
)
async def test_proactive_token_refresh_decision(
    offset_seconds: int,
) -> None:
    """Property 4: Proactive token refresh decision (backend)

    For any TokenRecord with random expires_at, TokenService SHALL refresh
    if and only if current time is within 5 minutes of expiry or past it.

    **Validates: Requirements 3.2**
    """
    # Set up a temporary SQLite database and real FernetEncryptor
    with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
        db_path = tmp.name

    encryptor = FernetEncryptor(TEST_FERNET_KEY)
    token_store = TokenStore(db_path, encryptor)
    await token_store.initialize()

    # Store a token with expires_at = now + offset_seconds
    user_id = "refresh_test_user"
    now = datetime.now(UTC)
    expires_at = now + timedelta(seconds=offset_seconds)
    expires_at_iso = expires_at.isoformat()

    await token_store.save_tokens(
        user_id=user_id,
        access_token="existing_access_token",
        refresh_token="existing_refresh_token",
        expires_at=expires_at_iso,
        token_type="Bearer",
        scope="read",
    )

    # Create a mock HTTP client that returns a refreshed token response
    refreshed_response = httpx.Response(
        status_code=200,
        json={
            "access_token": "refreshed_access_token",
            "refresh_token": "refreshed_refresh_token",
            "expires_in": 3600,
            "token_type": "Bearer",
            "scope": "read",
        },
    )
    mock_client = AsyncMock(spec=httpx.AsyncClient)
    mock_client.post = AsyncMock(return_value=refreshed_response)

    # Create TokenService with the mock client
    token_service = TokenService(
        client_id="test_client_id",
        client_secret="test_client_secret",
        token_store=token_store,
        http_client=mock_client,
    )

    # Call get_valid_token
    result = await token_service.get_valid_token(user_id=user_id)

    # Determine expected behavior:
    # If offset <= 300 (5 minutes = 300 seconds), token is near expiry or expired
    # → should trigger a refresh (mock HTTP client should be called)
    # If offset > 300, token has more than 5 minutes remaining
    # → should return existing token without calling HTTP client
    if offset_seconds <= 300:
        # Refresh should have been triggered
        mock_client.post.assert_called_once()
        assert result["access_token"] == "refreshed_access_token", (
            f"Expected refreshed token when offset={offset_seconds}s "
            f"(within 5 min of expiry), got {result['access_token']!r}"
        )
    else:
        # No refresh should have occurred
        mock_client.post.assert_not_called()
        assert result["access_token"] == "existing_access_token", (
            f"Expected existing token when offset={offset_seconds}s "
            f"(more than 5 min from expiry), got {result['access_token']!r}"
        )
