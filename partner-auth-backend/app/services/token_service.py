"""Token lifecycle management service for Ring Partner OAuth 2.0 flow."""

from datetime import UTC, datetime, timedelta

import httpx

from app.data.token_store import TokenStore
from app.models.schemas import RingOAuthTokenResponse


class TokenNotFoundError(Exception):
    """Raised when no tokens exist for the requested user."""

    pass


class SessionInvalidError(Exception):
    """Raised when the user's session has been invalidated (e.g., Ring returned 401)."""

    pass


class UpstreamError(Exception):
    """Raised when Ring's OAuth server returns an unexpected error."""

    pass


# Time threshold for proactive token refresh (5 minutes)
_REFRESH_THRESHOLD = timedelta(minutes=5)


class TokenService:
    """Manages token exchange, retrieval, refresh, and invalidation.

    Communicates with Ring's OAuth endpoint to exchange authorization codes
    and refresh tokens. Stores encrypted tokens via the TokenStore.
    """

    RING_TOKEN_ENDPOINT = "https://oauth.ring.com/oauth/token"

    def __init__(
        self,
        client_id: str,
        client_secret: str,
        token_store: TokenStore,
        http_client: httpx.AsyncClient | None = None,
    ) -> None:
        """Initialize the TokenService.

        Args:
            client_id: Ring Partner OAuth client ID.
            client_secret: Ring Partner OAuth client secret.
            token_store: TokenStore instance for persisting tokens.
            http_client: Optional httpx.AsyncClient for making HTTP requests.
                         If not provided, a new client is created per request.
        """
        self._client_id = client_id
        self._client_secret = client_secret
        self._token_store = token_store
        self._http_client = http_client

    async def _get_http_client(self) -> httpx.AsyncClient:
        """Return the configured HTTP client or create a new one."""
        if self._http_client is not None:
            return self._http_client
        return httpx.AsyncClient()

    async def exchange_code(self, code: str, user_id: str = "default") -> dict:
        """Exchange an authorization code for access and refresh tokens.

        POSTs to Ring's OAuth token endpoint with the authorization code,
        parses the response, computes the expiration time, and stores the
        encrypted tokens.

        Args:
            code: The authorization code received from Ring.
            user_id: User identifier to associate tokens with.

        Returns:
            Dictionary with token data including access_token, refresh_token,
            expires_at, token_type, and scope.

        Raises:
            UpstreamError: If Ring's OAuth endpoint returns an error.
        """
        client = await self._get_http_client()
        owns_client = self._http_client is None

        try:
            response = await client.post(
                self.RING_TOKEN_ENDPOINT,
                data={
                    "grant_type": "authorization_code",
                    "code": code,
                    "client_id": self._client_id,
                    "client_secret": self._client_secret,
                },
                timeout=10.0,
            )

            if response.status_code != 200:
                raise UpstreamError(f"Ring OAuth token endpoint returned {response.status_code}")

            token_response = RingOAuthTokenResponse.model_validate(response.json())

            # Compute absolute expiration time
            expires_at = datetime.now(UTC) + timedelta(seconds=token_response.expires_in)
            expires_at_iso = expires_at.isoformat()

            # Store encrypted tokens
            await self._token_store.save_tokens(
                user_id=user_id,
                access_token=token_response.access_token,
                refresh_token=token_response.refresh_token,
                expires_at=expires_at_iso,
                token_type=token_response.token_type,
                scope=token_response.scope,
            )

            return {
                "access_token": token_response.access_token,
                "refresh_token": token_response.refresh_token,
                "expires_at": expires_at_iso,
                "token_type": token_response.token_type,
                "scope": token_response.scope,
            }
        finally:
            if owns_client:
                await client.aclose()

    async def get_valid_token(self, user_id: str = "default") -> dict:
        """Return a valid token for the user, refreshing proactively if needed.

        Retrieves stored tokens and checks validity. If the token is within
        5 minutes of expiry or already expired, triggers a proactive refresh.

        Args:
            user_id: User identifier to retrieve tokens for.

        Returns:
            Dictionary with token data.

        Raises:
            TokenNotFoundError: If no tokens exist for the user.
            SessionInvalidError: If the session has been invalidated.
        """
        tokens = await self._token_store.get_tokens(user_id)

        if tokens is None:
            raise TokenNotFoundError(f"No tokens found for user '{user_id}'")

        if not tokens["is_valid"]:
            raise SessionInvalidError(f"Session for user '{user_id}' has been invalidated")

        # Check if token needs proactive refresh
        expires_at = datetime.fromisoformat(tokens["expires_at"])
        now = datetime.now(UTC)

        if now >= expires_at - _REFRESH_THRESHOLD:
            # Token is expired or within 5 minutes of expiry — refresh
            return await self.refresh_token(user_id)

        return tokens

    async def refresh_token(self, user_id: str) -> dict:
        """Refresh tokens using the stored refresh token.

        POSTs to Ring's OAuth token endpoint with the refresh token. On
        success, updates the stored tokens. On Ring 401, marks the session
        as invalid.

        Args:
            user_id: User identifier whose tokens should be refreshed.

        Returns:
            Dictionary with updated token data.

        Raises:
            TokenNotFoundError: If no tokens exist for the user.
            SessionInvalidError: If Ring returns 401 (refresh token revoked).
            UpstreamError: If Ring returns any other error.
        """
        tokens = await self._token_store.get_tokens(user_id)

        if tokens is None:
            raise TokenNotFoundError(f"No tokens found for user '{user_id}'")

        client = await self._get_http_client()
        owns_client = self._http_client is None

        try:
            response = await client.post(
                self.RING_TOKEN_ENDPOINT,
                data={
                    "grant_type": "refresh_token",
                    "refresh_token": tokens["refresh_token"],
                    "client_id": self._client_id,
                    "client_secret": self._client_secret,
                },
                timeout=10.0,
            )

            if response.status_code == 401:
                await self.invalidate_session(user_id)
                raise SessionInvalidError(
                    f"Ring rejected refresh token for user '{user_id}'. "
                    "Session has been invalidated."
                )

            if response.status_code != 200:
                raise UpstreamError(
                    f"Ring OAuth token endpoint returned {response.status_code} during refresh"
                )

            token_response = RingOAuthTokenResponse.model_validate(response.json())

            # Compute new expiration time
            expires_at = datetime.now(UTC) + timedelta(seconds=token_response.expires_in)
            expires_at_iso = expires_at.isoformat()

            # Update stored tokens
            await self._token_store.update_tokens(
                user_id=user_id,
                access_token=token_response.access_token,
                refresh_token=token_response.refresh_token,
                expires_at=expires_at_iso,
            )

            return {
                "user_id": user_id,
                "access_token": token_response.access_token,
                "refresh_token": token_response.refresh_token,
                "expires_at": expires_at_iso,
                "token_type": token_response.token_type,
                "scope": token_response.scope,
                "is_valid": True,
            }
        finally:
            if owns_client:
                await client.aclose()

    async def invalidate_session(self, user_id: str) -> None:
        """Mark a user's session as invalid in the token store.

        Args:
            user_id: User identifier whose session should be invalidated.
        """
        await self._token_store.invalidate(user_id)
