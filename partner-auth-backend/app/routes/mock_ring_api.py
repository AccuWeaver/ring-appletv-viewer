"""Mock Ring Partner API endpoints for local development.

Simulates the Ring Partner API responses so the tvOS app can be tested
end-to-end without real Ring credentials or app registration.

Endpoints mirror the real Ring Partner API paths under /mock:
- GET /mock/devices
- GET /mock/devices/{device_id}/history/devices/{device_id}/events  (legacy)
- GET /mock/history/devices/{device_id}/events
- POST /mock/devices/{device_id}/media/image/download
- POST /mock/devices/{device_id}/media/video/download
- POST /mock/devices/{device_id}/media/streaming/whep/sessions
- DELETE /mock/session/{session_id}
"""

import os
import uuid
from datetime import UTC, datetime, timedelta

import httpx
from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, Response

router = APIRouter(prefix="/mock")

# URL of the local WHEP server (mediamtx). Configurable so the backend can
# run in docker-compose and reach mediamtx via service name.
MEDIAMTX_WHEP_URL = os.environ.get(
    "MEDIAMTX_WHEP_URL", "http://localhost:8889/test/whep"
)

# ---------------------------------------------------------------------------
# Mock device data
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


# ---------------------------------------------------------------------------
# GET /mock/devices
# ---------------------------------------------------------------------------


@router.get("/devices")
async def get_devices() -> JSONResponse:
    """Return a list of mock Ring devices in JSON:API format."""
    return JSONResponse(status_code=200, content={"data": MOCK_DEVICES})


# ---------------------------------------------------------------------------
# GET /mock/history/devices/{device_id}/events
# ---------------------------------------------------------------------------


@router.get("/history/devices/{device_id}/events")
async def get_events(device_id: str, limit: int = 10) -> JSONResponse:
    """Return mock event history for a device."""
    events = _generate_mock_events(device_id, count=min(limit, 50))
    return JSONResponse(status_code=200, content=events)


# ---------------------------------------------------------------------------
# POST /mock/devices/{device_id}/media/image/download
# ---------------------------------------------------------------------------

# 1x1 blue PNG pixel (placeholder snapshot)
_BLUE_PIXEL_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


@router.post("/devices/{device_id}/media/image/download")
async def download_snapshot(device_id: str) -> Response:
    """Return a placeholder snapshot image."""
    return Response(content=_BLUE_PIXEL_PNG, media_type="image/png")


# ---------------------------------------------------------------------------
# POST /mock/devices/{device_id}/media/video/download
# ---------------------------------------------------------------------------


@router.post("/devices/{device_id}/media/video/download")
async def download_video(device_id: str, request: Request) -> JSONResponse:
    """Return a playable HLS test video URL."""
    return JSONResponse(
        status_code=200,
        content={
            "url": "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8"
        },
    )


# ---------------------------------------------------------------------------
# POST /mock/devices/{device_id}/media/streaming/whep/sessions
# ---------------------------------------------------------------------------


@router.post("/devices/{device_id}/media/streaming/whep/sessions")
async def create_whep_session(device_id: str, request: Request) -> Response:
    """Mock WHEP session creation that proxies to local mediamtx.

    Forwards the SDP offer to the local mediamtx WHEP endpoint
    (http://localhost:8889/test/whep) and returns the real SDP answer.
    This gives the tvOS app an actual WebRTC video stream to render
    without needing Ring credentials.

    Requires mediamtx + ffmpeg running locally:
      mediamtx &
      ffmpeg -re -f lavfi -i testsrc2=size=1280x720:rate=30 \\
        -c:v libx264 -preset ultrafast -tune zerolatency \\
        -f rtsp rtsp://localhost:8554/test &

    If mediamtx is not running, falls back to a stub SDP answer.
    """
    body = await request.body()
    session_id = str(uuid.uuid4())

    try:
        async with httpx.AsyncClient(timeout=10.0) as client:
            proxy_response = await client.post(
                MEDIAMTX_WHEP_URL,
                content=body,
                headers={"Content-Type": "application/sdp"},
            )

        if proxy_response.status_code == 201:
            # Real SDP answer from mediamtx — return it with our own Location header
            return Response(
                content=proxy_response.content,
                status_code=201,
                media_type="application/sdp",
                headers={"Location": f"/mock/session/{session_id}"},
            )
    except (httpx.ConnectError, httpx.TimeoutException, httpx.ReadTimeout):
        # mediamtx not running — fall through to stub
        pass

    # Stub SDP answer (won't establish real media, but lets the flow proceed)
    answer_sdp = (
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

    return Response(
        content=answer_sdp,
        status_code=201,
        media_type="application/sdp",
        headers={"Location": f"/mock/session/{session_id}"},
    )


# ---------------------------------------------------------------------------
# DELETE /mock/session/{session_id}
# ---------------------------------------------------------------------------


@router.delete("/session/{session_id}")
async def delete_session(session_id: str) -> JSONResponse:
    """Acknowledge WHEP session deletion."""
    return JSONResponse(status_code=200, content={"status": "deleted"})
