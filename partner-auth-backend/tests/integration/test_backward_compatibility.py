"""Backward compatibility integration test (task 18.4).

Verifies that all six ``/mock/*`` endpoints return the expected response
shapes regardless of the routing profile, and that the ``X-Ring-Source``
header is present on every response.

The session-scoped ``_install_mock_adapter`` fixture in ``conftest.py``
installs a ``MockRingAdapter`` + ``SourceRouter`` into
``app.dependency_overrides`` for the whole test session, so these tests
exercise the full FastAPI route layer (including header injection) without
needing a running lifespan.

Requirements: 12.1–12.6
"""

from __future__ import annotations

import pytest
from httpx import ASGITransport, AsyncClient

from app.main import app

_HLS_STREAM_URL = (
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
    "bipbop_16x9/bipbop_16x9_variant.m3u8"
)


@pytest.fixture
async def client() -> AsyncClient:
    """Thin async client wired to the ASGI app.

    The session-scoped ``_install_mock_adapter`` autouse fixture (conftest.py)
    has already installed the MockRingAdapter + SourceRouter overrides, so
    no lifespan context is needed here.
    """
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as c:
        yield c


# ---------------------------------------------------------------------------
# 1. GET /mock/devices
# ---------------------------------------------------------------------------


async def test_get_devices_returns_200_with_data_array(client: AsyncClient) -> None:
    """Requirement 12.1, 12.3 — shape unchanged, X-Ring-Source present."""
    response = await client.get("/mock/devices")

    assert response.status_code == 200
    body = response.json()
    assert "data" in body, "response body must contain a 'data' key"
    assert isinstance(body["data"], list), "'data' must be a JSON array"
    assert len(body["data"]) > 0, "'data' array must not be empty"
    assert "X-Ring-Source" in response.headers


# ---------------------------------------------------------------------------
# 2. GET /mock/history/devices/{device_id}/events
# ---------------------------------------------------------------------------


async def test_get_events_returns_200_with_json_array(client: AsyncClient) -> None:
    """Requirement 12.1, 12.3 — shape unchanged, X-Ring-Source present."""
    response = await client.get(
        "/mock/history/devices/device_front_door/events",
        params={"limit": 5},
    )

    assert response.status_code == 200
    body = response.json()
    assert isinstance(body, list), "response body must be a JSON array"
    assert len(body) == 5
    for event in body:
        assert "id" in event
        assert "device_id" in event
        assert "type" in event
    assert "X-Ring-Source" in response.headers


async def test_get_events_path_parameter_is_device_id(client: AsyncClient) -> None:
    """Requirement 12.2 — path parameter name ``device_id`` unchanged."""
    response = await client.get(
        "/mock/history/devices/device_backyard/events",
        params={"limit": 3},
    )

    assert response.status_code == 200
    body = response.json()
    assert isinstance(body, list)
    for event in body:
        assert event["device_id"] == "device_backyard"


# ---------------------------------------------------------------------------
# 3. POST /mock/devices/{device_id}/media/image/download
# ---------------------------------------------------------------------------


async def test_download_snapshot_returns_200_with_image_bytes(
    client: AsyncClient,
) -> None:
    """Requirement 12.1, 12.3, 12.5 — image bytes, content-type, X-Ring-Source."""
    response = await client.post("/mock/devices/device_front_door/media/image/download")

    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/")
    assert len(response.content) > 0, "response body must contain image bytes"
    assert "X-Ring-Source" in response.headers


# ---------------------------------------------------------------------------
# 4. POST /mock/devices/{device_id}/media/video/download
# ---------------------------------------------------------------------------


async def test_download_video_returns_200_with_url(client: AsyncClient) -> None:
    """Requirement 12.1, 12.3 — JSON body with ``url`` key, X-Ring-Source present."""
    response = await client.post("/mock/devices/device_front_door/media/video/download")

    assert response.status_code == 200
    body = response.json()
    assert "url" in body, "response body must contain a 'url' key"
    assert isinstance(body["url"], str) and body["url"].startswith("http")
    assert "X-Ring-Source" in response.headers


# ---------------------------------------------------------------------------
# 5. POST /mock/devices/{device_id}/media/streaming/whep/sessions
# ---------------------------------------------------------------------------


async def test_create_whep_session_returns_201_with_sdp_and_location(
    client: AsyncClient,
) -> None:
    """Requirement 12.1, 12.3, 12.4 — 201, application/sdp, Location header."""
    sdp_offer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"
    response = await client.post(
        "/mock/devices/device_front_door/media/streaming/whep/sessions",
        content=sdp_offer.encode(),
        headers={"Content-Type": "application/sdp"},
    )

    assert response.status_code == 201
    assert response.headers["content-type"].startswith("application/sdp")
    assert "location" in response.headers
    assert response.headers["location"].startswith("/mock/session/")
    assert response.text.startswith("v=0"), "SDP answer must start with 'v=0'"
    assert "X-Ring-Source" in response.headers


# ---------------------------------------------------------------------------
# 6. DELETE /mock/session/{session_id}
# ---------------------------------------------------------------------------


async def test_delete_session_returns_200_with_status_deleted(
    client: AsyncClient,
) -> None:
    """Requirement 12.1, 12.3 — 200, ``{"status": "deleted"}``, X-Ring-Source."""
    # Create a session first so we have a valid session_id.
    sdp_offer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"
    create_response = await client.post(
        "/mock/devices/device_front_door/media/streaming/whep/sessions",
        content=sdp_offer.encode(),
        headers={"Content-Type": "application/sdp"},
    )
    assert create_response.status_code == 201
    session_id = create_response.headers["location"].removeprefix("/mock/session/")

    response = await client.delete(f"/mock/session/{session_id}")

    assert response.status_code == 200
    assert response.json() == {"status": "deleted"}
    assert "X-Ring-Source" in response.headers


# ---------------------------------------------------------------------------
# Cross-cutting: X-Ring-Source header is present on all six endpoints
# ---------------------------------------------------------------------------


async def test_x_ring_source_header_present_on_all_endpoints(
    client: AsyncClient,
) -> None:
    """Requirement 12.6 — X-Ring-Source is additive and present on every response."""
    sdp_offer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"

    responses = [
        await client.get("/mock/devices"),
        await client.get("/mock/history/devices/device_front_door/events"),
        await client.post("/mock/devices/device_front_door/media/image/download"),
        await client.post("/mock/devices/device_front_door/media/video/download"),
        await client.post(
            "/mock/devices/device_front_door/media/streaming/whep/sessions",
            content=sdp_offer.encode(),
            headers={"Content-Type": "application/sdp"},
        ),
    ]

    # Grab a session_id for the DELETE test.
    whep_response = responses[-1]
    assert whep_response.status_code == 201
    session_id = whep_response.headers["location"].removeprefix("/mock/session/")
    responses.append(await client.delete(f"/mock/session/{session_id}"))

    for resp in responses:
        assert "X-Ring-Source" in resp.headers, (
            f"X-Ring-Source missing on {resp.request.method} {resp.request.url}"
        )
        # The header value must be a non-empty mode string.
        assert resp.headers["X-Ring-Source"] in {"mock", "unofficial", "partner"}, (
            f"Unexpected X-Ring-Source value: {resp.headers['X-Ring-Source']!r}"
        )
