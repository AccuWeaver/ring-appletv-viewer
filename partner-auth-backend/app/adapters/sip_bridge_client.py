"""HTTP client for the Node.js SIP bridge sidecar.

The ``ring-sip-bridge`` sidecar (see ``ring-sip-bridge/`` in the repo) owns
the Ring SIP state machine and publishes RTSP to mediamtx. This Python
client is a thin controller: it tells the sidecar to start or stop a
session and never inspects RTP traffic itself.

Refresh tokens are injected per-call via the ``refresh_token_provider``
callable (typically ``RefreshTokenStore.load``) so this client holds no
secrets between invocations and the store remains the single source of
truth (Requirement 13.3).
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Final

import httpx

from app.adapters.errors import (
    AuthenticationRequiredError,
    StreamCapacityExceededError,
    UpstreamTimeoutError,
    UpstreamUnavailableError,
)

logger = logging.getLogger(__name__)

_START_TIMEOUT_SECONDS: Final[float] = 15.0  # SIP negotiation is slow
_STOP_TIMEOUT_SECONDS: Final[float] = 5.0
_HEALTH_TIMEOUT_SECONDS: Final[float] = 3.0


@dataclass(frozen=True, slots=True)
class BridgeSession:
    """Return value of :meth:`SipBridgeClient.start`.

    ``rtsp_path`` and ``hls_path`` are mutually exclusive — exactly one
    is populated depending on the ``output`` requested at start time.
    Empty string for whichever one is not in use keeps the type simple
    and round-trippable across JSON.
    """

    bridge_session_id: str
    rtsp_path: str = ""
    hls_path: str = ""


RefreshTokenProvider = Callable[[], Awaitable[str | None]]


class SipBridgeClient:
    """Thin HTTP controller for the Node sidecar.

    The client can either own its underlying ``httpx.AsyncClient`` (default)
    or share one provided by the caller for connection pooling. When the
    client owns the HTTP client, :meth:`aclose` will close it.
    """

    def __init__(
        self,
        base_url: str,
        refresh_token_provider: RefreshTokenProvider,
        *,
        http: httpx.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._get_refresh_token = refresh_token_provider
        # If no client is injected, create our own; callers may share a
        # client for connection pooling. ``_owned_client`` is non-None only
        # when this instance created the client and must close it on
        # ``aclose()``.
        self._owned_client: httpx.AsyncClient | None = None
        if http is None:
            http = httpx.AsyncClient()
            self._owned_client = http
        self._http = http

    async def start(
        self, device_id: str, *, output: str = "rtsp"
    ) -> BridgeSession:
        """Negotiate a new SIP session for ``device_id`` via the sidecar.

        Args:
            device_id: Ring camera id to stream from.
            output: ``"rtsp"`` (default, publishes to mediamtx) or
                ``"hls"`` (sidecar writes fMP4 segments and serves them).

        Raises:
            AuthenticationRequiredError: when the refresh-token provider
                returns ``None`` (no stored token).
            StreamCapacityExceededError: sidecar returned 409 ``device_busy``.
            UpstreamUnavailableError: sidecar returned 5xx or any other
                non-2xx, or a transport error occurred.
            UpstreamTimeoutError: POST exceeded 15 s.
        """
        refresh_token = await self._get_refresh_token()
        if refresh_token is None:
            raise AuthenticationRequiredError("no refresh token available for sip bridge start")

        url = f"{self._base_url}/sessions"
        try:
            response = await self._http.post(
                url,
                json={
                    "device_id": device_id,
                    "refresh_token": refresh_token,
                    "output": output,
                },
                timeout=_START_TIMEOUT_SECONDS,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("sip bridge start timeout") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError(f"sip bridge transport error: {exc!r}") from exc

        if response.status_code == 409:
            raise StreamCapacityExceededError(
                f"sip bridge rejected session for {device_id}: device busy"
            )
        if 500 <= response.status_code < 600:
            raise UpstreamUnavailableError(f"sip bridge returned {response.status_code}")
        if response.status_code not in (200, 201):
            raise UpstreamUnavailableError(f"sip bridge unexpected status {response.status_code}")

        data = response.json()
        return BridgeSession(
            bridge_session_id=str(data["bridge_session_id"]),
            rtsp_path=str(data.get("rtsp_path") or ""),
            hls_path=str(data.get("hls_path") or ""),
        )

    async def stop(self, bridge_session_id: str) -> None:
        """Terminate a session by id. Idempotent.

        A 404 from the sidecar is treated as success — the session was
        already gone. Non-2xx / non-404 results raise
        :class:`UpstreamUnavailableError` so the adapter can log them; they
        do not block cleanup.
        """
        url = f"{self._base_url}/sessions/{bridge_session_id}"
        try:
            response = await self._http.delete(url, timeout=_STOP_TIMEOUT_SECONDS)
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("sip bridge stop timeout") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError(f"sip bridge stop transport error: {exc!r}") from exc

        if response.status_code in (200, 202, 204, 404):
            return
        raise UpstreamUnavailableError(f"sip bridge stop unexpected status {response.status_code}")

    async def healthy(self) -> bool:
        """Return True if the sidecar responds 2xx to ``GET /health``."""
        url = f"{self._base_url}/health"
        try:
            response = await self._http.get(url, timeout=_HEALTH_TIMEOUT_SECONDS)
        except httpx.HTTPError:
            return False
        return 200 <= response.status_code < 300

    async def aclose(self) -> None:
        """Close the owned httpx client, if any.

        Safe to call multiple times; a no-op when the HTTP client was
        injected by the caller.
        """
        if self._owned_client is not None:
            await self._owned_client.aclose()
            self._owned_client = None
