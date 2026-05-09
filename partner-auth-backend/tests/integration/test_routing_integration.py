"""Integration tests for end-to-end routing with mocked HTTP clients.

Tests the full FastAPI app with a SourceRouter injected via
``app.dependency_overrides``, using FakeAdapter instances to simulate
routing profiles without any real upstream calls.

Scenarios covered:
1. Profile [unofficial, mock] where unofficial succeeds → X-Ring-Source: unofficial
2. Profile [unofficial, mock] where unofficial fails (UpstreamUnavailableError)
   and mock succeeds → X-Ring-Source: mock
3. GET /mock/devices returns 200 with correct X-Ring-Source header
4. POST .../image/download returns 200 with correct X-Ring-Source header

Requirements: 1.4, 1.5, 1.8, 12.1–12.6
"""

from __future__ import annotations

from dataclasses import dataclass, field

import pytest
from httpx import ASGITransport, AsyncClient

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.errors import UpstreamUnavailableError
from app.adapters.session_map import StreamSessionMap
from app.dependencies import get_source_router
from app.main import app
from app.routing.health_manager import HealthManager
from app.routing.snapshot_cache import SnapshotCache
from app.routing.source_router import SourceRouter

# ---------------------------------------------------------------------------
# FakeAdapter — configurable test double (mirrors test_source_router_property.py)
# ---------------------------------------------------------------------------


@dataclass
class FakeAdapter(RingAdapter):
    """Minimal RingAdapter test double for integration tests.

    Attributes:
        _mode: The mode string returned by mode().
        should_succeed: If True, all operations return a dummy payload.
            If False, all operations raise UpstreamUnavailableError
            (a fallback-eligible failure).
        call_count: Tracks how many times any operation was invoked.
    """

    _mode: str
    should_succeed: bool = True
    call_count: int = field(default=0, init=False)

    def mode(self) -> str:
        return self._mode

    def _result_or_raise(self, value):
        self.call_count += 1
        if not self.should_succeed:
            raise UpstreamUnavailableError(f"{self._mode} unavailable")
        return value

    async def list_devices(self) -> dict:
        return self._result_or_raise(
            {
                "data": [
                    {
                        "id": f"device_{self._mode}_1",
                        "type": "doorbell_pro",
                        "attributes": {
                            "name": f"{self._mode} Front Door",
                            "model": "doorbell_pro",
                            "firmware_version": "1.0.0",
                            "power_source": "hardwired",
                            "status": "online",
                        },
                    }
                ]
            }
        )

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        return self._result_or_raise([])

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        return self._result_or_raise(
            SnapshotPayload(content=b"\x89PNG fake", content_type="image/png")
        )

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        return self._result_or_raise({"url": "https://example.com/clip.mp4"})

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        return self._result_or_raise(
            StreamSessionResult(
                sdp_answer="v=0\r\n",
                location=f"/mock/session/fake-{self._mode}",
                session_id=f"fake-{self._mode}",
            )
        )

    async def delete_stream_session(self, session_id: str) -> None:
        self._result_or_raise(None)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_router(adapters: list[FakeAdapter]) -> SourceRouter:
    """Build a SourceRouter with a fresh HealthManager and empty SnapshotCache."""
    return SourceRouter(
        routing_profile=adapters,
        health_manager=HealthManager(quarantine_threshold=100, quarantine_seconds=3600),
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,  # always stale so cache never short-circuits
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def override_source_router():
    """Context manager that installs a SourceRouter override and cleans up after."""
    saved = app.dependency_overrides.get(get_source_router)

    def _install(router: SourceRouter):
        app.dependency_overrides[get_source_router] = lambda: router

    yield _install

    # Restore previous override (the conftest session-scoped mock adapter)
    if saved is not None:
        app.dependency_overrides[get_source_router] = saved
    else:
        app.dependency_overrides.pop(get_source_router, None)


# ---------------------------------------------------------------------------
# Scenario 1: Profile [unofficial, mock] — unofficial succeeds
# X-Ring-Source must be "unofficial"
# Requirements: 1.4, 1.8, 12.1, 12.3
# ---------------------------------------------------------------------------


async def test_get_devices_unofficial_succeeds_x_ring_source_is_unofficial(
    override_source_router,
) -> None:
    """When unofficial succeeds, X-Ring-Source header must be 'unofficial'.

    Requirements: 1.4, 1.8, 12.1
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=True)
    mock = FakeAdapter(_mode="mock", should_succeed=True)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/mock/devices")

    assert response.status_code == 200
    assert response.headers["x-ring-source"] == "unofficial", (
        f"Expected X-Ring-Source: unofficial, got: {response.headers.get('x-ring-source')!r}"
    )
    # Unofficial was called; mock was not
    assert unofficial.call_count == 1
    assert mock.call_count == 0


# ---------------------------------------------------------------------------
# Scenario 2: Profile [unofficial, mock] — unofficial fails, mock succeeds
# X-Ring-Source must be "mock"
# Requirements: 1.5, 1.8, 12.1
# ---------------------------------------------------------------------------


async def test_get_devices_unofficial_fails_fallback_to_mock_x_ring_source_is_mock(
    override_source_router,
) -> None:
    """When unofficial fails with UpstreamUnavailableError, router falls back to mock.

    X-Ring-Source header must be 'mock'.
    Requirements: 1.5, 1.8, 12.1
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=False)
    mock = FakeAdapter(_mode="mock", should_succeed=True)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/mock/devices")

    assert response.status_code == 200
    assert response.headers["x-ring-source"] == "mock", (
        f"Expected X-Ring-Source: mock after fallback, got: {response.headers.get('x-ring-source')!r}"
    )
    # Unofficial was attempted; mock was called as fallback
    assert unofficial.call_count == 1
    assert mock.call_count == 1


# ---------------------------------------------------------------------------
# Scenario 3: GET /mock/devices returns 200 with correct X-Ring-Source
# Requirements: 1.8, 12.1
# ---------------------------------------------------------------------------


async def test_get_devices_returns_200_with_x_ring_source_header(
    override_source_router,
) -> None:
    """GET /mock/devices returns 200 and X-Ring-Source header is set.

    Requirements: 1.8, 12.1
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=True)
    mock = FakeAdapter(_mode="mock", should_succeed=True)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/mock/devices")

    assert response.status_code == 200
    assert "x-ring-source" in response.headers, (
        "X-Ring-Source header must be present on GET /mock/devices response"
    )
    assert response.headers["x-ring-source"] == "unofficial"
    # Verify response body has the expected shape
    data = response.json()
    assert "data" in data
    assert isinstance(data["data"], list)


# ---------------------------------------------------------------------------
# Scenario 4: POST .../image/download returns 200 with correct X-Ring-Source
# Requirements: 1.8, 12.3
# ---------------------------------------------------------------------------


async def test_download_snapshot_returns_200_with_x_ring_source_header(
    override_source_router,
) -> None:
    """POST /mock/devices/{device_id}/media/image/download returns 200 with X-Ring-Source.

    Requirements: 1.8, 12.3
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=True)
    mock = FakeAdapter(_mode="mock", should_succeed=True)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.post("/mock/devices/device_front_door/media/image/download")

    assert response.status_code == 200
    assert "x-ring-source" in response.headers, (
        "X-Ring-Source header must be present on POST .../image/download response"
    )
    assert response.headers["x-ring-source"] == "unofficial"
    assert response.headers["content-type"].startswith("image/png")


# ---------------------------------------------------------------------------
# Scenario 4b: POST .../image/download with fallback — X-Ring-Source: mock
# Requirements: 1.5, 1.7, 1.8, 12.3
# ---------------------------------------------------------------------------


async def test_download_snapshot_fallback_to_mock_x_ring_source_is_mock(
    override_source_router,
) -> None:
    """POST .../image/download falls back to mock when unofficial is quarantined.

    The "always show real data" guard (Req 7.1) prevents mock from being used
    for live media while any real source has Health_State=up. The guard check
    happens AFTER the failure is recorded in the routing loop — so when
    unofficial fails and is immediately quarantined (threshold=1), the guard
    check for mock sees unofficial as down and allows mock to serve.

    Requirements: 1.5, 1.7, 1.8, 12.3
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=False)
    mock = FakeAdapter(_mode="mock", should_succeed=True)

    # Use quarantine threshold=1 so unofficial is quarantined after one failure.
    # When the routing loop reaches mock, unofficial is already quarantined
    # (Health_State=down), so _has_real_source_up() returns False and mock is used.
    health_manager = HealthManager(quarantine_threshold=1, quarantine_seconds=3600)
    router = SourceRouter(
        routing_profile=[unofficial, mock],
        health_manager=health_manager,
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # unofficial fails → quarantined immediately (threshold=1).
        # When loop reaches mock, _has_real_source_up() returns False (unofficial is down).
        # Mock is allowed to serve the snapshot.
        response = await client.post("/mock/devices/device_front_door/media/image/download")

    assert response.status_code == 200
    assert response.headers["x-ring-source"] == "mock", (
        f"Expected X-Ring-Source: mock after unofficial quarantined, "
        f"got: {response.headers.get('x-ring-source')!r}"
    )
    # unofficial was attempted once and quarantined; mock served the response
    assert unofficial.call_count == 1
    assert mock.call_count == 1


# ---------------------------------------------------------------------------
# Routing profile order is respected: first healthy source wins
# Requirements: 1.4, 1.8
# ---------------------------------------------------------------------------


async def test_routing_profile_order_first_healthy_source_wins(
    override_source_router,
) -> None:
    """The first healthy source in the profile is always used.

    Requirements: 1.4, 1.8
    """
    # Profile: [unofficial(fails), mock(succeeds)]
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=False)
    mock = FakeAdapter(_mode="mock", should_succeed=True)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/mock/devices")

    assert response.status_code == 200
    # Unofficial was tried first (fallback-eligible failure), then mock succeeded
    assert unofficial.call_count == 1
    assert mock.call_count == 1
    assert response.headers["x-ring-source"] == "mock"


# ---------------------------------------------------------------------------
# All sources fail → 502 error response
# Requirements: 1.11
# ---------------------------------------------------------------------------


async def test_all_sources_fail_returns_error_response(
    override_source_router,
) -> None:
    """When all sources fail with UpstreamUnavailableError, the response is an error.

    Requirements: 1.11
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=False)
    mock = FakeAdapter(_mode="mock", should_succeed=False)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        response = await client.get("/mock/devices")

    # Both sources failed; the route handler raises the error → 502
    assert response.status_code == 502
    assert unofficial.call_count == 1
    assert mock.call_count == 1


# ---------------------------------------------------------------------------
# X-Ring-Source is present on all /mock/* endpoints
# Requirements: 1.8, 12.1–12.6
# ---------------------------------------------------------------------------


async def test_x_ring_source_header_present_on_all_mock_endpoints(
    override_source_router,
) -> None:
    """X-Ring-Source header is present on all /mock/* route responses.

    Requirements: 1.8, 12.1–12.6
    """
    unofficial = FakeAdapter(_mode="unofficial", should_succeed=True)
    mock = FakeAdapter(_mode="mock", should_succeed=True)
    router = _make_router([unofficial, mock])
    override_source_router(router)

    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
        # 12.1: GET /mock/devices
        r1 = await client.get("/mock/devices")
        assert r1.status_code == 200
        assert "x-ring-source" in r1.headers, "Missing X-Ring-Source on GET /mock/devices"

        # 12.2: GET /mock/history/devices/{device_id}/events
        r2 = await client.get("/mock/history/devices/device_front_door/events")
        assert r2.status_code == 200
        assert "x-ring-source" in r2.headers, "Missing X-Ring-Source on GET /mock/history/..."

        # 12.3: POST /mock/devices/{device_id}/media/image/download
        r3 = await client.post("/mock/devices/device_front_door/media/image/download")
        assert r3.status_code == 200
        assert "x-ring-source" in r3.headers, "Missing X-Ring-Source on POST .../image/download"

        # 12.4: POST /mock/devices/{device_id}/media/video/download
        r4 = await client.post("/mock/devices/device_front_door/media/video/download")
        assert r4.status_code == 200
        assert "x-ring-source" in r4.headers, "Missing X-Ring-Source on POST .../video/download"

    # All responses should have X-Ring-Source: unofficial (first healthy source)
    for r in [r1, r2, r3, r4]:
        assert r.headers["x-ring-source"] == "unofficial"
