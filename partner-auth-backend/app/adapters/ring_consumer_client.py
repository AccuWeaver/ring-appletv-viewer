"""HTTP client for the Ring consumer API (``api.ring.com``).

Handles OAuth access-token lifecycle, refresh-token rotation, outbound
rate limiting via ``RateLimitGovernor``, per-request retries with bounded
exponential backoff, and a small in-process response cache.

This client is deliberately purpose-built rather than depending on
``python-ring-doorbell``: that library is synchronous, carries a large
dependency tree, and does not expose the access-token lifecycle cleanly.
A focused ~300-line client gives us the exact control we need for
Requirements 3.3–3.5, 3.7, 3.8, 4.6, 5.5, and 8.3–8.6.
"""

from __future__ import annotations

import asyncio
import logging
import random
import time
from dataclasses import dataclass
from typing import Any, Final

import httpx

from app.adapters.errors import (
    AuthenticationRequiredError,
    UpstreamTimeoutError,
    UpstreamUnavailableError,
)
from app.adapters.rate_limit import RateLimitGovernor
from app.adapters.ring_schemas import RingOAuthTokenResponse
from app.adapters.types import AccessTokenCacheEntry
from app.data.refresh_token_store import RefreshTokenStore

logger = logging.getLogger(__name__)

# Upstream Ring hosts (Requirements 3.3, 3.7).
_OAUTH_URL: Final[str] = "https://oauth.ring.com/oauth/token"
_API_BASE: Final[str] = "https://api.ring.com"

# Access-token refresh threshold: refresh when
# ``expires_at - now <= REFRESH_THRESHOLD_SECONDS`` (Requirement 3.4).
REFRESH_THRESHOLD_SECONDS: Final[float] = 60.0

# Retry policy constants (Requirements 8.3, 8.4).
_MAX_5XX_RETRIES: Final[int] = 2
_INITIAL_BACKOFF_SECONDS: Final[float] = 1.0
_MAX_BACKOFF_SECONDS: Final[float] = 30.0

# Per-request timeout (Requirement 8.5).
_REQUEST_TIMEOUT_SECONDS: Final[float] = 10.0

# Response cache TTLs (Requirement 4.6).
_DEVICES_CACHE_TTL_SECONDS: Final[float] = 30.0
_HISTORY_CACHE_TTL_SECONDS: Final[float] = 10.0

# Delay between a snapshot-refresh POST and the retry GET. Empirically,
# Ring's cached-snapshot service takes ~300–500 ms to propagate a newly
# requested frame for powered cameras; battery cams may not respond at
# all. Keeping this low bounds the worst-case request latency.
_SNAPSHOT_REFRESH_SETTLE_SECONDS: Final[float] = 0.5

# OAuth client_id value used by the official Ring iOS app; matches the value
# ``ring-client-api`` uses when exchanging refresh tokens.
_OAUTH_CLIENT_ID: Final[str] = "ring_official_ios"


@dataclass(slots=True)
class _CacheEntry:
    """In-process response cache entry with a monotonic-time expiry."""

    data: Any
    expires_at: float


class RingConsumerClient:
    """Async client for the Ring consumer API.

    All outbound API requests pass through the rate-limit governor; access
    tokens are cached in-memory and refreshed proactively under an
    ``asyncio.Lock`` so concurrent callers never trigger duplicate
    refreshes. Responses for device and history reads are cached briefly
    (Req 4.6); snapshots and clip URLs are never cached (Req 5.5).
    """

    def __init__(
        self,
        http: httpx.AsyncClient,
        governor: RateLimitGovernor,
        store: RefreshTokenStore,
        *,
        version: str = "0.1.0",
        snapshot_refresh_settle_seconds: float = _SNAPSHOT_REFRESH_SETTLE_SECONDS,
    ) -> None:
        self._http = http
        self._governor = governor
        self._store = store
        self._user_agent = f"ring-adapter-backend/{version}"
        self._access_token: AccessTokenCacheEntry | None = None
        self._token_lock = asyncio.Lock()
        self._cache: dict[str, _CacheEntry] = {}
        self._snapshot_refresh_settle = snapshot_refresh_settle_seconds

    # ------------------------------------------------------------------
    # Access-token lifecycle (Requirements 3.3, 3.4, 3.5, 3.7, 3.8)
    # ------------------------------------------------------------------

    async def ensure_access_token(self) -> str:
        """Return a valid access token, refreshing if near expiry.

        Guarded by ``self._token_lock`` so concurrent callers refresh at
        most once (Requirements 3.3, 3.4).
        """
        async with self._token_lock:
            now = time.time()
            if (
                self._access_token is None
                or (self._access_token.expires_at - now) <= REFRESH_THRESHOLD_SECONDS
            ):
                await self._refresh()
            assert self._access_token is not None  # noqa: S101 - invariant after _refresh
            return self._access_token.token

    async def _refresh(self) -> None:
        """Exchange the stored refresh token for a new access token.

        - Rotates the refresh token in the store if Ring returns a new
          value (Requirement 3.5).
        - On HTTP 401, marks the stored token invalid **before** raising
          ``AuthenticationRequiredError`` (Requirement 3.7). The order
          matters: the store must record the invalidation even if the
          caller later drops the raised exception.

        Raises:
            AuthenticationRequiredError: no stored refresh token, or
                Ring rejected the refresh with 401.
            UpstreamUnavailableError: OAuth returned 5xx or a non-200,
                non-401 status, or a transport error occurred.
            UpstreamTimeoutError: OAuth request exceeded the per-request
                timeout.
        """
        refresh_token = await self._store.load()
        if refresh_token is None:
            raise AuthenticationRequiredError(
                "no refresh token available; regenerate via ring-auth-cli"
            )

        try:
            response = await self._http.post(
                _OAUTH_URL,
                data={
                    "grant_type": "refresh_token",
                    "refresh_token": refresh_token,
                    "client_id": _OAUTH_CLIENT_ID,
                },
                headers={"User-Agent": self._user_agent},
                timeout=_REQUEST_TIMEOUT_SECONDS,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("ring oauth timeout") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError(f"ring oauth transport error: {exc!r}") from exc

        if response.status_code == 401:
            await self._store.mark_invalid()
            logger.warning("ring_auth_failure status=401 action=refresh_token_invalidated")
            raise AuthenticationRequiredError(
                "refresh token rejected by Ring; regenerate via ring-auth-cli"
            )

        if response.status_code >= 500:
            raise UpstreamUnavailableError(f"ring oauth returned {response.status_code}")

        if response.status_code != 200:
            raise UpstreamUnavailableError(f"unexpected oauth status {response.status_code}")

        parsed = RingOAuthTokenResponse.model_validate(response.json())
        new_refresh = parsed.refresh_token
        if new_refresh is not None and new_refresh != refresh_token:
            # Atomic rotation in the store; token values are never logged.
            await self._store.rotate(new_refresh)
            logger.info("ring_refresh_token_rotated")

        self._access_token = AccessTokenCacheEntry(
            token=parsed.access_token,
            expires_at=time.time() + parsed.expires_in,
        )

    # ------------------------------------------------------------------
    # Public API operations (Requirements 4.6, 5.5)
    # ------------------------------------------------------------------

    async def get_devices(self) -> list[dict[str, Any]]:
        """Return the raw Ring device list, cached for 30 s (Req 4.6).

        Ring's ``/clients_api/ring_devices`` endpoint returns a structured
        envelope with separate arrays per device family (``doorbots``,
        ``authorized_doorbots``, ``stickup_cams``, ``chimes``,
        ``base_stations``, ``other``). We flatten these into a single list
        of dicts and leave Pydantic parsing to the caller (the
        ``UnofficialRingAdapter`` mapper), keeping this module schema-free.
        """
        cached = self._cache_get("devices")
        if cached is not None:
            return cached  # type: ignore[no-any-return]

        raw = await self._get_json("/clients_api/ring_devices")
        flattened: list[dict[str, Any]] = []
        if isinstance(raw, dict):
            for key in (
                "doorbots",
                "authorized_doorbots",
                "stickup_cams",
                "chimes",
                "base_stations",
                "other",
            ):
                entries = raw.get(key)
                if not entries:
                    continue
                for entry in entries:
                    if isinstance(entry, dict):
                        flattened.append(entry)
        elif isinstance(raw, list):
            flattened = [x for x in raw if isinstance(x, dict)]

        self._cache_set("devices", flattened, _DEVICES_CACHE_TTL_SECONDS)
        return flattened

    async def get_history(self, device_id: str, limit: int) -> list[dict[str, Any]]:
        """Return up to ``limit`` raw history events, cached for 10 s (Req 4.6)."""
        cache_key = f"history:{device_id}:{limit}"
        cached = self._cache_get(cache_key)
        if cached is not None:
            return cached  # type: ignore[no-any-return]

        raw = await self._get_json(
            f"/clients_api/doorbots/{device_id}/history",
            params={"limit": limit},
        )
        events: list[dict[str, Any]] = (
            [x for x in raw if isinstance(x, dict)] if isinstance(raw, list) else []
        )
        self._cache_set(cache_key, events, _HISTORY_CACHE_TTL_SECONDS)
        return events

    async def get_snapshot(self, device_id: str) -> tuple[bytes, str]:
        """Return ``(image_bytes, content_type)``. Never cached (Req 5.5).

        Strategy:

        1. GET ``/clients_api/snapshots/image/{device_id}`` — Ring's
           cached snapshot. Fast (one round trip) and produces a usable
           JPEG whenever Ring has a recent capture.
        2. If step 1 returns 404 (no cached image), POST the same path
           to nudge Ring into capturing a fresh frame, wait briefly, and
           re-GET. Ring reliably returns a capture within a few seconds
           for powered cameras; battery cams may take longer or refuse.
        3. Any non-2xx after the retry propagates as-is for the adapter
           layer to map (``SnapshotUnavailableError`` on 404, etc.).

        The verbs and paths match ``ring-client-api``'s implementation
        (``GET`` and ``POST`` of ``/clients_api/snapshots/image/{id}``)
        so behavior stays predictable when debugging against Ring's
        own client.
        """
        response = await self._request("GET", f"/clients_api/snapshots/image/{device_id}")

        if response.status_code == 404:
            logger.info("ring_snapshot_refresh_requested device_id=%s", device_id)
            # Best-effort refresh: errors here are non-fatal — we still try
            # the second GET and let its status drive the outcome.
            #
            # The verb is PUT, not POST. ``ring-client-api`` uses:
            #   PUT /clients_api/snapshots/update_all
            #   body: {"doorbot_ids": [<id>], "refresh": true}
            # POST returns 405 Method Not Allowed.
            try:
                refresh_resp = await self._request(
                    "PUT",
                    "/clients_api/snapshots/update_all",
                    json={"doorbot_ids": [int(device_id)], "refresh": True},
                )
                logger.info(
                    "ring_snapshot_refresh_posted device_id=%s status=%d allow=%s",
                    device_id,
                    refresh_resp.status_code,
                    refresh_resp.headers.get("allow", ""),
                )
            except Exception as exc:  # pragma: no cover - logged and swallowed
                logger.info(
                    "ring_snapshot_refresh_post_failed device_id=%s error=%r",
                    device_id,
                    exc,
                )

            # Give Ring a moment to capture. Half a second is enough for
            # wired cameras in practice; battery cams may still 404, in
            # which case the adapter maps to `snapshot_unavailable` and
            # the tvOS client can retry later.
            await asyncio.sleep(self._snapshot_refresh_settle)

            response = await self._request("GET", f"/clients_api/snapshots/image/{device_id}")

        response.raise_for_status()
        content_type = response.headers.get("content-type", "image/jpeg")
        return response.content, content_type

    async def get_clip_url(self, event_id: str) -> str:
        """Return a signed clip URL. Never cached (Req 5.5).

        Ring may either return a 302 redirect whose ``Location`` is the
        pre-signed URL, or a 200 JSON body with a ``url`` field. Both
        shapes are handled here; any other response becomes
        ``UpstreamUnavailableError`` for the adapter to classify.
        """
        response = await self._request(
            "GET",
            f"/clients_api/dings/{event_id}/recording",
            follow_redirects=False,
        )
        if response.status_code in (301, 302, 303, 307, 308):
            location = response.headers.get("location")
            if location:
                return location
        if response.status_code == 200:
            data = response.json()
            if isinstance(data, dict):
                url = data.get("url")
                if isinstance(url, str) and url:
                    return url
        # Let the adapter translate non-2xx via HTTPStatusError semantics.
        response.raise_for_status()
        raise UpstreamUnavailableError(f"unexpected clip response status={response.status_code}")

    # ------------------------------------------------------------------
    # Request plumbing: governor → auth → retries
    # ------------------------------------------------------------------

    async def _get_json(self, path: str, params: dict[str, Any] | None = None) -> Any:
        response = await self._request("GET", path, params=params)
        response.raise_for_status()
        return response.json()

    async def _request(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json: Any | None = None,
        follow_redirects: bool = True,
    ) -> httpx.Response:
        """Execute a governor-shaped, bounded-retry request to Ring.

        Implements the retry policy from Requirements 8.3 and 8.4:

        - 429: honor ``Retry-After`` if present; otherwise exponential
          backoff starting at 1 s, doubling up to a 30 s cap.
        - 5xx: retry up to ``_MAX_5XX_RETRIES`` times (3 total attempts)
          with the same capped-exponential backoff, then raise
          ``UpstreamUnavailableError``.
        - Transport-level timeouts / errors raise ``UpstreamTimeoutError``
          or ``UpstreamUnavailableError`` immediately (no retry).
        """
        await self._governor.acquire()
        token = await self.ensure_access_token()
        url = f"{_API_BASE}{path}"
        headers = {
            "Authorization": f"Bearer {token}",
            "User-Agent": self._user_agent,  # Requirement 8.6
        }

        attempt_5xx = 0
        backoff = _INITIAL_BACKOFF_SECONDS
        while True:
            try:
                response = await self._http.request(
                    method,
                    url,
                    params=params,
                    json=json,
                    headers=headers,
                    follow_redirects=follow_redirects,
                    timeout=_REQUEST_TIMEOUT_SECONDS,
                )
            except httpx.TimeoutException as exc:
                raise UpstreamTimeoutError(f"ring api timeout: {method} {path}") from exc
            except httpx.HTTPError as exc:
                raise UpstreamUnavailableError(
                    f"ring api transport error: {method} {path}: {exc!r}"
                ) from exc

            # 429: honor Retry-After; otherwise exponential backoff (Req 8.3).
            if response.status_code == 429:
                retry_after = _parse_retry_after(response.headers.get("retry-after"))
                if retry_after is None:
                    retry_after = min(backoff, _MAX_BACKOFF_SECONDS)
                    backoff = min(backoff * 2, _MAX_BACKOFF_SECONDS)
                await asyncio.sleep(retry_after)
                continue

            # 5xx: bounded retry with capped exponential backoff (Req 8.4).
            if 500 <= response.status_code < 600:
                if attempt_5xx >= _MAX_5XX_RETRIES:
                    raise UpstreamUnavailableError(
                        f"ring api {response.status_code} after "
                        f"{attempt_5xx + 1} attempts: {method} {path}"
                    )
                attempt_5xx += 1
                sleep_for = min(backoff, _MAX_BACKOFF_SECONDS)
                backoff = min(backoff * 2, _MAX_BACKOFF_SECONDS)
                # Small jitter avoids synchronised retry storms when
                # multiple callers see the same 5xx burst.
                await asyncio.sleep(sleep_for + random.uniform(0, 0.25))
                continue

            return response

    # ------------------------------------------------------------------
    # Response cache (Requirement 4.6)
    # ------------------------------------------------------------------

    def _cache_get(self, key: str) -> Any:
        entry = self._cache.get(key)
        if entry is None:
            return None
        if time.monotonic() >= entry.expires_at:
            self._cache.pop(key, None)
            return None
        return entry.data

    def _cache_set(self, key: str, data: Any, ttl_seconds: float) -> None:
        self._cache[key] = _CacheEntry(data=data, expires_at=time.monotonic() + ttl_seconds)


def _parse_retry_after(header_value: str | None) -> float | None:
    """Parse a ``Retry-After`` header value expressed in seconds.

    Ring returns ``Retry-After`` as an integer number of seconds. The
    HTTP-date form is not observed in the wild for ``api.ring.com``; if
    it appears, we fall through to the exponential backoff path by
    returning ``None`` rather than attempting a full RFC 7231 parse.
    """
    if not header_value:
        return None
    try:
        return float(header_value)
    except ValueError:
        return None
