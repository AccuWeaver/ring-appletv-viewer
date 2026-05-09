"""Thin HTTP client for the go2rtc control plane.

go2rtc exposes a small REST API for managing named streams and serves
live HLS (fMP4) at ``/api/stream.m3u8?src=<name>``. This client is how
the backend registers per-camera Ring streams on demand and returns the
public HLS URL to the tvOS client.

The client is intentionally tiny — stream lifecycle is stateless on the
backend side. When a camera's stream is re-requested we upsert it via
``PUT /api/streams`` (go2rtc treats a PUT as an idempotent create-or-
replace). Teardown is optional because go2rtc tears the Ring producer
down automatically when the last consumer disconnects.

Token handling: the raw Ring refresh token never flows through this
client; callers pass in the already-wrapped AuthConfig envelope (see
``scripts/wrap-ring-token.py``). We never log URLs that contain the
token — structured log lines only reference the stream name.
"""

from __future__ import annotations

import logging
from typing import Final
from urllib.parse import urlencode

import httpx

from app.adapters.errors import UpstreamTimeoutError, UpstreamUnavailableError

logger = logging.getLogger(__name__)

_REQUEST_TIMEOUT_SECONDS: Final[float] = 5.0


class Go2rtcClient:
    """Manage named Ring streams on a local go2rtc instance.

    ``public_base_url`` is the URL the *client* should use to fetch the
    HLS playlist — typically ``http://localhost:1984`` when go2rtc is
    reached via a Docker port publish. ``internal_base_url`` is the URL
    the backend uses to talk to go2rtc (e.g. the docker-compose service
    name). They may be the same value outside container environments.
    """

    def __init__(
        self,
        *,
        internal_base_url: str,
        public_base_url: str,
        wrapped_refresh_token: str,
        http: httpx.AsyncClient | None = None,
    ) -> None:
        self._internal_base = internal_base_url.rstrip("/")
        self._public_base = public_base_url.rstrip("/")
        self._token = wrapped_refresh_token
        self._owned_http: httpx.AsyncClient | None = None
        if http is None:
            http = httpx.AsyncClient()
            self._owned_http = http
        self._http = http

    @property
    def is_configured(self) -> bool:
        """Whether the client has enough config to serve HLS.

        Returns False when the wrapped refresh token is empty; callers
        should fall back to the mediamtx path in that case.
        """
        return bool(self._token)

    def stream_name(self, device_id: str) -> str:
        """Canonical go2rtc stream name for a camera."""
        return f"ring_{device_id}"

    def public_hls_url(self, device_id: str) -> str:
        """Publicly reachable HLS master playlist URL.

        Uses the ``mp4=flac`` codec filter so AVPlayer on tvOS gets a
        CMAF-compatible fMP4 stream instead of the legacy TS fallback.
        """
        return (
            f"{self._public_base}/api/stream.m3u8"
            f"?src={self.stream_name(device_id)}&mp4=flac"
        )

    async def ensure_stream(self, device_id: str, camera_id: str) -> None:
        """Upsert a Ring stream on go2rtc.

        Idempotent: repeated calls with the same device/camera just
        replace the registration. Errors are surfaced as adapter errors
        so the router's health tracking sees them.
        """
        src = "ring:?" + urlencode(
            {
                "device_id": device_id,
                "camera_id": camera_id,
                "refresh_token": self._token,
            }
        )
        params = {"name": self.stream_name(device_id), "src": src}
        url = f"{self._internal_base}/api/streams"
        try:
            response = await self._http.put(
                url, params=params, timeout=_REQUEST_TIMEOUT_SECONDS
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("go2rtc ensure_stream timeout") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError(f"go2rtc transport error: {exc!r}") from exc

        # go2rtc returns 200 on success and 400 when it can't persist to
        # its config file (read-only mount, YAML error, etc.). Those 400s
        # are recoverable — the stream is still registered in-memory.
        # Treat only 5xx as fatal so a misconfigured volume doesn't kill
        # live video.
        if response.status_code >= 500:
            raise UpstreamUnavailableError(
                f"go2rtc ensure_stream returned {response.status_code}"
            )
        logger.info(
            "go2rtc_stream_upsert name=%s status=%d",
            self.stream_name(device_id),
            response.status_code,
        )

    async def delete_stream(self, device_id: str) -> None:
        """Remove a Ring stream. Best-effort — errors are logged but not raised."""
        params = {"src": self.stream_name(device_id)}
        url = f"{self._internal_base}/api/streams"
        try:
            await self._http.delete(url, params=params, timeout=_REQUEST_TIMEOUT_SECONDS)
        except httpx.HTTPError as exc:
            logger.warning(
                "go2rtc delete_stream failed name=%s error=%r",
                self.stream_name(device_id),
                exc,
            )

    async def aclose(self) -> None:
        if self._owned_http is not None:
            await self._owned_http.aclose()
            self._owned_http = None
