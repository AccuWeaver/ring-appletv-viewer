"""Mock Ring adapter.

Preserves the byte-for-byte response shape produced by
``app/routes/mock_ring_api.py`` so the tvOS app can be exercised end-to-end
without real Ring credentials. All constants and helpers are ported verbatim
from the legacy module.
"""

import uuid
from datetime import UTC, datetime, timedelta

import httpx

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.session_map import StreamSessionMap
from app.adapters.types import MockStreamSession

# ---------------------------------------------------------------------------
# Mock device data (ported verbatim from app/routes/mock_ring_api.py)
# ---------------------------------------------------------------------------

MOCK_DEVICES = [
    {
        "id": "device_front_door",
        "type": "doorbell_pro",
        "attributes": {
            "name": "Front Door",
            "model": "doorbell_pro",
            "firmware_version": "3.48.42",
            "power_source": "hardwired",
            "status": "online",
        },
    },
    {
        "id": "device_backyard",
        "type": "spotlight_cam",
        "attributes": {
            "name": "Backyard Camera",
            "model": "spotlight_cam",
            "firmware_version": "3.46.10",
            "power_source": "battery",
            "status": "online",
        },
    },
    {
        "id": "device_garage",
        "type": "stickup_cam",
        "attributes": {
            "name": "Garage Cam",
            "model": "stickup_cam",
            "firmware_version": "3.44.5",
            "power_source": "hardwired",
            "status": "online",
        },
    },
    {
        "id": "device_indoor",
        "type": "indoor_cam",
        "attributes": {
            "name": "Living Room",
            "model": "indoor_cam",
            "firmware_version": "3.50.1",
            "power_source": "hardwired",
            "status": "offline",
        },
    },
]


def _generate_mock_events(device_id: str, count: int = 10) -> list[dict]:
    """Generate fake event history for a device."""
    event_types = ["motion", "ding", "motion", "motion", "ding"]
    events = []
    now = datetime.now(UTC)
    for i in range(count):
        events.append(
            {
                "id": f"evt_{device_id}_{i:03d}",
                "device_id": device_id,
                "type": event_types[i % len(event_types)],
                "created_at": (now - timedelta(hours=i, minutes=i * 7)).isoformat(),
                "duration": 15 + (i * 3),
            }
        )
    return events


# 1x1 blue PNG pixel (placeholder snapshot)
_BLUE_PIXEL_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


# Fixed HLS test stream used by the legacy /media/video/download handler.
_HLS_TEST_STREAM_URL = (
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
    "bipbop_16x9/bipbop_16x9_variant.m3u8"
)


# Stub SDP answer returned when mediamtx is not reachable. Ported verbatim
# from the legacy route so the WHEP fallback path stays byte-identical.
_STUB_SDP_ANSWER = (
    "v=0\r\n"
    "o=- 0 0 IN IP4 127.0.0.1\r\n"
    "s=-\r\n"
    "t=0 0\r\n"
    "a=group:BUNDLE 0\r\n"
    "m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
    "c=IN IP4 0.0.0.0\r\n"
    "a=rtcp:9 IN IP4 0.0.0.0\r\n"
    "a=ice-ufrag:mock\r\n"
    "a=ice-pwd:mockmockmockmockmockmock\r\n"
    "a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00"
    ":00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00\r\n"
    "a=setup:active\r\n"
    "a=mid:0\r\n"
    "a=recvonly\r\n"
    "a=rtpmap:96 H264/90000\r\n"
)


class MockRingAdapter(RingAdapter):
    """Mock implementation that serves canned responses and proxies WHEP locally.

    No outbound calls are made to ``*.ring.com``. The WHEP endpoint forwards
    SDP offers to a local ``mediamtx`` instance if reachable; otherwise it
    falls back to the stub SDP answer.

    An optional ``session_map`` may be supplied so that ``create_stream_session``
    binds sessions and ``SourceRouter.delete_stream_session`` can look them up.
    When no map is provided a private one is used (backward-compatible behaviour).
    """

    def __init__(
        self,
        mediamtx_whep_url: str,
        session_map: StreamSessionMap | None = None,
    ) -> None:
        self._whep_url = mediamtx_whep_url
        self._sessions = session_map if session_map is not None else StreamSessionMap()

    def mode(self) -> str:
        return "mock"

    async def list_devices(self) -> dict:
        return {"data": MOCK_DEVICES}

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        return _generate_mock_events(device_id, count=min(limit, 50))

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        return SnapshotPayload(content=_BLUE_PIXEL_PNG, content_type="image/png")

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        return {"url": _HLS_TEST_STREAM_URL}

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        session_id = str(uuid.uuid4())
        location = f"/mock/session/{session_id}"

        try:
            async with httpx.AsyncClient(timeout=10.0) as client:
                proxy_response = await client.post(
                    self._whep_url,
                    content=sdp_offer.encode(),
                    headers={"Content-Type": "application/sdp"},
                )

            if proxy_response.status_code == 201:
                sdp_answer = proxy_response.content.decode()
            else:
                sdp_answer = _STUB_SDP_ANSWER
        except (httpx.ConnectError, httpx.TimeoutException, httpx.ReadTimeout):
            # mediamtx not running — fall through to stub
            sdp_answer = _STUB_SDP_ANSWER

        # Bind to the session map so SourceRouter.delete_stream_session can
        # look up the session and dispatch back to this adapter.
        import time

        await self._sessions.bind(
            MockStreamSession(
                session_id=session_id,
                device_id=device_id,
                created_at=time.time(),
            )
        )

        return StreamSessionResult(
            sdp_answer=sdp_answer,
            location=location,
            session_id=session_id,
        )

    async def delete_stream_session(self, session_id: str) -> None:
        # Legacy behavior is a no-op acknowledgement; nothing to tear down.
        return None
