"""Partner Ring Adapter.

Wraps the Ring Partner API at ``https://api.amazonvision.com/v1`` to provide
devices, events, snapshots, clips, and WHEP live-streaming via the partner
OAuth access-token path already implemented in ``partner-auth-backend``.
"""

from __future__ import annotations

import time
import uuid
from collections.abc import Awaitable, Callable

import httpx

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.errors import (
    AuthenticationRequiredError,
    DeviceNotFoundError,
    RateLimitedError,
    SnapshotUnavailableError,
    SubscriptionRequiredError,
    UpstreamTimeoutError,
    UpstreamUnavailableError,
)
from app.adapters.session_map import StreamSessionMap
from app.adapters.types import PartnerStreamSession


class PartnerRingAdapter(RingAdapter):
    """RingAdapter implementation wrapping the Partner API at api.amazonvision.com/v1."""

    PARTNER_BASE = "https://api.amazonvision.com/v1"

    def __init__(
        self,
        http: httpx.AsyncClient,
        token_provider: Callable[[], Awaitable[str]],
        session_map: StreamSessionMap,
    ) -> None:
        self._http = http
        self._token_provider = token_provider
        self._session_map = session_map

    def mode(self) -> str:
        return "partner"

    async def list_devices(self) -> dict:
        """GET /v1/devices → JSON:API shape."""
        try:
            token = await self._token_provider()
            resp = await self._http.get(
                f"{self.PARTNER_BASE}/devices",
                headers={"Authorization": f"Bearer {token}"},
                timeout=10.0,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("list_devices timed out") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError("list_devices network error") from exc
        self._raise_for_status(resp, "list_devices")
        return resp.json()

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        """GET /v1/history/devices/{device_id}/events?limit={limit}."""
        try:
            token = await self._token_provider()
            resp = await self._http.get(
                f"{self.PARTNER_BASE}/history/devices/{device_id}/events",
                params={"limit": limit},
                headers={"Authorization": f"Bearer {token}"},
                timeout=10.0,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("list_events timed out") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError("list_events network error") from exc
        self._raise_for_status(resp, "list_events")
        return resp.json()

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        """POST /v1/devices/{device_id}/media/image/download."""
        try:
            token = await self._token_provider()
            resp = await self._http.post(
                f"{self.PARTNER_BASE}/devices/{device_id}/media/image/download",
                headers={"Authorization": f"Bearer {token}"},
                timeout=10.0,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("download_snapshot timed out") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError("download_snapshot network error") from exc
        self._raise_for_snapshot_status(resp)
        return SnapshotPayload(
            content=resp.content,
            content_type=resp.headers.get("content-type", "image/jpeg"),
        )

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        """POST /v1/devices/{device_id}/media/video/download."""
        try:
            token = await self._token_provider()
            body: dict = {"event_id": event_id} if event_id else {}
            resp = await self._http.post(
                f"{self.PARTNER_BASE}/devices/{device_id}/media/video/download",
                json=body,
                headers={"Authorization": f"Bearer {token}"},
                timeout=10.0,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("download_video timed out") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError("download_video network error") from exc
        self._raise_for_status(resp, "download_video")
        return resp.json()

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        """POST /v1/devices/{device_id}/media/streaming/whep/sessions."""
        try:
            token = await self._token_provider()
            resp = await self._http.post(
                f"{self.PARTNER_BASE}/devices/{device_id}/media/streaming/whep/sessions",
                content=sdp_offer.encode(),
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/sdp",
                },
                timeout=10.0,
            )
        except httpx.TimeoutException as exc:
            raise UpstreamTimeoutError("create_stream_session timed out") from exc
        except httpx.HTTPError as exc:
            raise UpstreamUnavailableError("create_stream_session network error") from exc
        self._raise_for_whep_status(resp)
        session_id = str(uuid.uuid4())
        partner_session_url = resp.headers["location"]
        await self._session_map.bind(
            PartnerStreamSession(
                session_id=session_id,
                partner_session_url=partner_session_url,
                device_id=device_id,
                created_at=time.time(),
                state="active",
            )
        )
        return StreamSessionResult(
            sdp_answer=resp.text,
            location=f"/mock/session/{session_id}",
            session_id=session_id,
        )

    async def delete_stream_session(self, session_id: str) -> None:
        """DELETE the partner session URL, then remove from session map."""
        session = await self._session_map.lookup(session_id)
        assert isinstance(session, PartnerStreamSession)
        try:
            token = await self._token_provider()
            await self._http.delete(
                session.partner_session_url,
                headers={"Authorization": f"Bearer {token}"},
                timeout=5.0,
            )
        finally:
            await self._session_map.remove(session_id)

    async def aclose(self) -> None:
        """Close the owned httpx client."""
        await self._http.aclose()

    # ------------------------------------------------------------------
    # Failure-class mapping helpers
    # ------------------------------------------------------------------

    def _raise_for_whep_status(self, resp: httpx.Response) -> None:
        """Map Partner WHEP HTTP status to a RingAdapterError.

        201 → success (no raise)
        401 → AuthenticationRequiredError
        402 → SubscriptionRequiredError
        403, 404 → DeviceNotFoundError
        429 → RateLimitedError
        5xx → UpstreamUnavailableError
        Other non-2xx → UpstreamUnavailableError
        """
        status = resp.status_code
        if 200 <= status < 300:
            return
        if status == 401:
            raise AuthenticationRequiredError(f"WHEP auth rejected: {status}")
        if status == 402:
            raise SubscriptionRequiredError(f"WHEP subscription required: {status}")
        if status in (403, 404):
            raise DeviceNotFoundError(f"WHEP device not found: {status}")
        if status == 429:
            raise RateLimitedError(f"WHEP rate limited: {status}")
        raise UpstreamUnavailableError(f"WHEP upstream error: {status}")

    def _raise_for_snapshot_status(self, resp: httpx.Response) -> None:
        """Map Partner snapshot HTTP status to a RingAdapterError.

        200 → success (no raise)
        204, 404 → SnapshotUnavailableError
        401 → AuthenticationRequiredError
        5xx → UpstreamUnavailableError
        Other non-2xx → UpstreamUnavailableError
        """
        status = resp.status_code
        if status == 200:
            return
        if status in (204, 404):
            raise SnapshotUnavailableError(f"snapshot unavailable: {status}")
        if status == 401:
            raise AuthenticationRequiredError(f"snapshot auth rejected: {status}")
        raise UpstreamUnavailableError(f"snapshot upstream error: {status}")

    def _raise_for_status(self, resp: httpx.Response, operation: str = "") -> None:
        """General HTTP status mapping for list_devices, list_events, download_video.

        2xx → success (no raise)
        401 → AuthenticationRequiredError
        402 → SubscriptionRequiredError
        403, 404 → DeviceNotFoundError
        429 → RateLimitedError
        5xx → UpstreamUnavailableError
        Other non-2xx → UpstreamUnavailableError
        """
        status = resp.status_code
        if 200 <= status < 300:
            return
        label = f"{operation} " if operation else ""
        if status == 401:
            raise AuthenticationRequiredError(f"{label}auth rejected: {status}")
        if status == 402:
            raise SubscriptionRequiredError(f"{label}subscription required: {status}")
        if status in (403, 404):
            raise DeviceNotFoundError(f"{label}device not found: {status}")
        if status == 429:
            raise RateLimitedError(f"{label}rate limited: {status}")
        raise UpstreamUnavailableError(f"{label}upstream error: {status}")
