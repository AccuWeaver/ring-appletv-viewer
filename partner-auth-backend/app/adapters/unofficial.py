"""Unofficial Ring adapter — the real-account backend implementation.

Composes the Ring consumer API client, the SIP bridge sidecar client, and
the in-memory stream session map to serve the same ``RingAdapter``
interface as ``MockRingAdapter``. All upstream Ring errors are translated
into ``RingAdapterError`` subclasses; the route layer's global exception
handler maps those back to HTTP responses.
"""

from __future__ import annotations

import logging
import time
import uuid
from functools import wraps

import httpx

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.errors import (
    DeviceNotFoundError,
    RingAdapterError,
    SnapshotUnavailableError,
    SubscriptionRequiredError,
    UpstreamTimeoutError,
    UpstreamUnavailableError,
)
from app.adapters.mappers import is_camera_kind, map_device, map_event
from app.adapters.ring_consumer_client import RingConsumerClient
from app.adapters.ring_schemas import RingDevice, RingEvent
from app.adapters.session_map import StreamSessionMap
from app.adapters.sip_bridge_client import SipBridgeClient
from app.adapters.types import StreamSession

logger = logging.getLogger(__name__)

_MEDIAMTX_WHEP_TIMEOUT_SECONDS: float = 10.0


def _logged(operation: str):
    """Wrap an async adapter method with a structured entry/exit log record.

    Emits one ``adapter_call`` INFO record after the wrapped method
    completes. Fields:

    * ``mode`` — adapter mode (``unofficial`` here).
    * ``operation`` — logical operation name passed to the decorator.
    * ``device_id`` — extracted from the ``device_id`` kwarg when present
      or from the first positional argument if it's a string; ``None``
      for methods without a device scope (e.g. ``list_devices``).
    * ``outcome`` — one of ``ok``, ``timeout``, ``adapter_error``, or
      ``upstream_error`` (mapped from the exception type raised, if any).

    Exceptions are re-raised after logging; this decorator never swallows
    errors. Correlation with the owning request happens via the request
    logging middleware, which logs ``request_id`` against the same
    handler invocation. Requirement 11.1.
    """

    def decorator(func):
        @wraps(func)
        async def wrapper(self, *args, **kwargs):
            device_id = kwargs.get("device_id")
            if device_id is None and args and isinstance(args[0], str):
                device_id = args[0]
            try:
                result = await func(self, *args, **kwargs)
            except UpstreamTimeoutError:
                logger.info(
                    "adapter_call mode=%s operation=%s device_id=%s outcome=timeout",
                    self.mode(),
                    operation,
                    device_id,
                )
                raise
            except RingAdapterError:
                logger.info(
                    "adapter_call mode=%s operation=%s device_id=%s outcome=adapter_error",
                    self.mode(),
                    operation,
                    device_id,
                )
                raise
            except Exception:
                logger.info(
                    "adapter_call mode=%s operation=%s device_id=%s outcome=upstream_error",
                    self.mode(),
                    operation,
                    device_id,
                )
                raise
            logger.info(
                "adapter_call mode=%s operation=%s device_id=%s outcome=ok",
                self.mode(),
                operation,
                device_id,
            )
            return result

        return wrapper

    return decorator


class UnofficialRingAdapter(RingAdapter):
    """Adapter that serves the tvOS app from a user's real Ring account."""

    def __init__(
        self,
        *,
        client: RingConsumerClient,
        sip: SipBridgeClient,
        sessions: StreamSessionMap,
        max_concurrent: int,
        mediamtx_whep_base: str,
        http: httpx.AsyncClient | None = None,
    ) -> None:
        self._client = client
        self._sip = sip
        self._sessions = sessions
        self._max_concurrent = max_concurrent
        self._mediamtx_whep_base = mediamtx_whep_base.rstrip("/")
        # Optional separate httpx client for mediamtx WHEP traffic so it
        # does not share the Ring-API client's rate-limit path. If omitted
        # we create our own and close it on aclose().
        self._owned_whep: httpx.AsyncClient | None = None
        if http is None:
            http = httpx.AsyncClient()
            self._owned_whep = http
        self._whep = http

    def mode(self) -> str:
        return "unofficial"

    # ------------------------------------------------------------------
    # Read operations
    # ------------------------------------------------------------------

    @_logged("list_devices")
    async def list_devices(self) -> dict:
        try:
            raw_devices = await self._client.get_devices()
        except httpx.HTTPStatusError as exc:
            raise UpstreamUnavailableError(
                f"ring devices {exc.response.status_code}"
            ) from exc
        parsed: list[RingDevice] = []
        for d in raw_devices:
            try:
                parsed.append(RingDevice.model_validate(d))
            except Exception as exc:  # schema drift — skip unparseable entries
                logger.warning("ring_device_unparseable error=%r", exc)
        # Filter to devices the tvOS app can actually display (Req 4.1):
        # cameras and doorbells only. Chimes, beams, and other non-camera
        # accessories are hidden at the adapter boundary so every client
        # gets the same contract.
        cameras = [d for d in parsed if is_camera_kind(d.kind)]
        dropped = [d.kind for d in parsed if not is_camera_kind(d.kind)]
        if dropped:
            logger.info(
                "list_devices_filtered kept=%d dropped_kinds=%s",
                len(cameras),
                sorted(set(dropped)),
            )
        return {"data": [map_device(d).model_dump() for d in cameras]}

    @_logged("list_events")
    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        try:
            raw_events = await self._client.get_history(device_id, limit=limit)
        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            if status == 404:
                # Device id not visible to this account (Requirement 4.5).
                raise DeviceNotFoundError(
                    f"device {device_id} not found"
                ) from exc
            raise UpstreamUnavailableError(
                f"ring history {status}"
            ) from exc

        parsed: list[RingEvent] = []
        for e in raw_events:
            try:
                parsed.append(RingEvent.model_validate(e))
            except Exception as exc:
                logger.warning("ring_event_unparseable error=%r", exc)
        mapped: list[dict] = []
        for ev in parsed:
            try:
                mapped.append(map_event(ev, device_id=device_id).model_dump())
            except ValueError:
                # Unsupported kind (on_demand, alarm, …) — drop, don't fail.
                continue
        return mapped[:limit]

    @_logged("download_snapshot")
    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        try:
            content, content_type = await self._client.get_snapshot(device_id)
        except httpx.HTTPStatusError as exc:
            if exc.response.status_code == 404:
                raise SnapshotUnavailableError(
                    f"no snapshot for {device_id}"
                ) from exc
            raise UpstreamUnavailableError(
                f"ring snapshot {exc.response.status_code}"
            ) from exc
        return SnapshotPayload(content=content, content_type=content_type)

    @_logged("download_video")
    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        if event_id is None:
            # Ring's clip endpoint requires an event_id. The mock adapter
            # tolerates None (it returns a canned URL). The tvOS client
            # always provides a concrete event id; we guard defensively so
            # the route maps to 404 rather than 500 if it ever doesn't.
            raise DeviceNotFoundError("event_id required for clip download")
        try:
            url = await self._client.get_clip_url(event_id)
        except httpx.HTTPStatusError as exc:
            status = exc.response.status_code
            if status == 402:
                raise SubscriptionRequiredError(
                    "Ring Protect subscription required"
                ) from exc
            if status == 404:
                raise DeviceNotFoundError(
                    f"clip not found for event {event_id}"
                ) from exc
            raise UpstreamUnavailableError(f"ring clip {status}") from exc
        return {"url": url}

    # ------------------------------------------------------------------
    # Stream lifecycle
    # ------------------------------------------------------------------

    @_logged("create_stream_session")
    async def create_stream_session(
        self, device_id: str, sdp_offer: str
    ) -> StreamSessionResult:
        # Capacity check first (Req 6.7). Raises StreamCapacityExceededError.
        await self._sessions.check_capacity(self._max_concurrent)

        # Start the Ring SIP session via the Node sidecar. Raises
        # StreamCapacityExceededError (409), UpstreamUnavailableError (5xx),
        # UpstreamTimeoutError (15 s cap).
        bridge = await self._sip.start(device_id)

        # Bind the backend-generated session_id → sidecar/device/path map.
        session_id = str(uuid.uuid4())
        session = StreamSession(
            session_id=session_id,
            bridge_session_id=bridge.bridge_session_id,
            device_id=device_id,
            mediamtx_path=bridge.rtsp_path,
            created_at=time.time(),
            state="active",
            has_audio=False,  # updated from the SDP answer below if present
        )
        await self._sessions.bind(session)

        # SIP leg is now established between the sidecar and Ring.
        logger.info(
            "sip_bridge_lifecycle event=sip_established session_id=%s device_id=%s mode=%s",
            session_id,
            device_id,
            self.mode(),
        )

        # Proxy the SDP offer to the mediamtx WHEP endpoint for the RTSP
        # path the sidecar just started publishing to.
        whep_url = f"{self._mediamtx_whep_base}/{bridge.rtsp_path}/whep"
        try:
            response = await self._whep.post(
                whep_url,
                content=sdp_offer.encode(),
                headers={"Content-Type": "application/sdp"},
                timeout=_MEDIAMTX_WHEP_TIMEOUT_SECONDS,
            )
        except httpx.TimeoutException as exc:
            await self._cleanup_failed_session(session)
            raise UpstreamTimeoutError("mediamtx whep timeout") from exc
        except httpx.HTTPError as exc:
            await self._cleanup_failed_session(session)
            raise UpstreamUnavailableError(
                f"mediamtx whep transport error: {exc!r}"
            ) from exc

        if response.status_code != 201:
            await self._cleanup_failed_session(session)
            raise UpstreamUnavailableError(
                f"mediamtx whep returned {response.status_code}"
            )

        sdp_answer = response.content.decode()
        session.has_audio = "m=audio" in sdp_answer

        # mediamtx accepted the WHEP subscription; the sidecar's RTSP
        # publish is now actively being consumed.
        logger.info(
            "sip_bridge_lifecycle event=rtsp_publish_started session_id=%s device_id=%s mode=%s",
            session_id,
            device_id,
            self.mode(),
        )

        logger.info(
            "stream_session_created session_id=%s device_id=%s has_audio=%s",
            session_id,
            device_id,
            session.has_audio,
        )
        return StreamSessionResult(
            sdp_answer=sdp_answer,
            location=f"/mock/session/{session_id}",
            session_id=session_id,
        )

    @_logged("delete_stream_session")
    async def delete_stream_session(self, session_id: str) -> None:
        session = await self._sessions.lookup(session_id)
        try:
            await self._sip.stop(session.bridge_session_id)
        finally:
            await self._sessions.remove(session_id)
        # RTSP publish stopped first (the sidecar tears down the publish
        # leg before closing the SIP dialog); we surface both events so
        # that downstream correlation tools see the full teardown order.
        logger.info(
            "sip_bridge_lifecycle event=rtsp_publish_stopped session_id=%s device_id=%s mode=%s",
            session_id,
            session.device_id,
            self.mode(),
        )
        logger.info(
            "sip_bridge_lifecycle event=sip_terminated session_id=%s device_id=%s mode=%s",
            session_id,
            session.device_id,
            self.mode(),
        )
        logger.info(
            "stream_session_deleted session_id=%s device_id=%s",
            session_id,
            session.device_id,
        )

    # ------------------------------------------------------------------
    # Shutdown
    # ------------------------------------------------------------------

    async def aclose(self) -> None:
        """Tear down every active stream session, then close owned clients."""
        sessions = await self._sessions.clear()
        for session in sessions:
            try:
                await self._sip.stop(session.bridge_session_id)
            except Exception as exc:
                logger.warning(
                    "sip bridge stop failed on aclose session_id=%s error=%r",
                    session.session_id,
                    exc,
                )
            # Emit sip_terminated regardless of stop outcome: from the
            # adapter's point of view the session is gone (the sidecar's
            # own watchdog will reap any residue).
            logger.info(
                "sip_bridge_lifecycle event=sip_terminated session_id=%s device_id=%s mode=%s",
                session.session_id,
                session.device_id,
                self.mode(),
            )
        if self._owned_whep is not None:
            await self._owned_whep.aclose()
            self._owned_whep = None

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    async def _cleanup_failed_session(self, session: StreamSession) -> None:
        """Best-effort cleanup after the mediamtx WHEP proxy fails.

        Removes the session from the map and asks the sidecar to stop.
        Both operations are best-effort; any residual Ring SIP session on
        the sidecar will be reaped by its own watchdog.
        """
        await self._sessions.remove(session.session_id)
        try:
            await self._sip.stop(session.bridge_session_id)
        except Exception as exc:
            logger.warning(
                "sip bridge stop failed during cleanup session_id=%s error=%r",
                session.session_id,
                exc,
            )
