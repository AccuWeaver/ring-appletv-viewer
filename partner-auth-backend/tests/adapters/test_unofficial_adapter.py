"""Property and example tests for ``UnofficialRingAdapter``.

Property 10 (task 8.4): Stream session lifecycle invariants.
    For any random sequence of create/delete calls against a fake
    ``SipBridgeClient`` with ``max_concurrent in [1, 10]``: session IDs
    are unique, the live count never exceeds the cap, capacity errors
    raise before the sidecar is contacted, and ``lookup`` semantics
    after create/delete are consistent.

    Validates: Requirements 6.4, 6.5, 6.7.

Error translation examples (task 8.5):
    - Ring 404 on history → ``DeviceNotFoundError`` (→ HTTP 404).
    - Ring 404 on snapshot → ``SnapshotUnavailableError`` (→ HTTP 503).
    - Ring 402 on clip → ``SubscriptionRequiredError`` (→ HTTP 402).
    - Sidecar 15 s timeout → ``UpstreamTimeoutError`` (→ HTTP 504).
    - Snapshot and clip URLs are not cached at the adapter layer.

    Validates: Requirements 4.5, 5.2, 5.4, 5.5.
"""

from __future__ import annotations

import asyncio
import uuid
from typing import Any

import httpx
import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from app.adapters.errors import (
    DeviceNotFoundError,
    SnapshotUnavailableError,
    StreamCapacityExceededError,
    StreamSessionNotFoundError,
    SubscriptionRequiredError,
    UpstreamTimeoutError,
)
from app.adapters.session_map import StreamSessionMap
from app.adapters.sip_bridge_client import BridgeSession
from app.adapters.unofficial import UnofficialRingAdapter

# ---------------------------------------------------------------------------
# Fakes and helpers
# ---------------------------------------------------------------------------


class FakeConsumerClient:
    """Duck-typed stand-in for ``RingConsumerClient``.

    The adapter only calls ``get_devices``, ``get_history``,
    ``get_snapshot`` and ``get_clip_url`` on the client, so we bypass the
    real HTTP / OAuth stack and record call counts directly.
    """

    def __init__(self) -> None:
        self.get_devices_calls = 0
        self.get_history_calls: list[tuple[str, int]] = []
        self.get_snapshot_calls: list[str] = []
        self.get_clip_url_calls: list[str] = []
        self.raise_on_history: httpx.HTTPStatusError | None = None
        self.raise_on_snapshot: httpx.HTTPStatusError | None = None
        self.raise_on_clip: httpx.HTTPStatusError | None = None

    async def get_devices(self) -> list[dict[str, Any]]:
        self.get_devices_calls += 1
        return []

    async def get_history(self, device_id: str, limit: int) -> list[dict[str, Any]]:
        self.get_history_calls.append((device_id, limit))
        if self.raise_on_history is not None:
            raise self.raise_on_history
        return []

    async def get_snapshot(self, device_id: str) -> tuple[bytes, str]:
        self.get_snapshot_calls.append(device_id)
        if self.raise_on_snapshot is not None:
            raise self.raise_on_snapshot
        return b"img", "image/jpeg"

    async def get_clip_url(self, event_id: str) -> str:
        self.get_clip_url_calls.append(event_id)
        if self.raise_on_clip is not None:
            raise self.raise_on_clip
        return "https://cdn.ring.invalid/clip.mp4"


class FakeSipBridge:
    """Duck-typed stand-in for ``SipBridgeClient``.

    Returns a deterministic, strictly-increasing ``bridge_session_id`` so
    we can count the exact number of times ``start`` was touched, and a
    ``stop`` that is a no-op to mirror the sidecar's idempotent DELETE.
    """

    def __init__(self, *, start_raises: Exception | None = None) -> None:
        self.start_calls: list[str] = []
        self.stop_calls: list[str] = []
        self._start_raises = start_raises

    async def start(self, device_id: str) -> BridgeSession:
        self.start_calls.append(device_id)
        if self._start_raises is not None:
            raise self._start_raises
        return BridgeSession(
            bridge_session_id=f"br_{len(self.start_calls):04d}",
            rtsp_path=f"ring/{device_id}",
        )

    async def stop(self, bridge_session_id: str) -> None:
        self.stop_calls.append(bridge_session_id)

    async def healthy(self) -> bool:
        return True

    async def aclose(self) -> None:  # pragma: no cover - not used in tests
        return None


def _http_status_error(status: int) -> httpx.HTTPStatusError:
    """Build a synthetic ``httpx.HTTPStatusError`` for the given status.

    The adapter only inspects ``exc.response.status_code`` when translating
    upstream errors, so a minimal request/response pair is enough.
    """
    request = httpx.Request("GET", "https://api.ring.com/test")
    response = httpx.Response(status, request=request)
    return httpx.HTTPStatusError(f"ring api {status}", request=request, response=response)


def _whep_mock_transport() -> httpx.MockTransport:
    """``MockTransport`` that returns 201 with a minimal SDP answer.

    The adapter only requires a 201 status and a decodable body; it
    records ``has_audio`` by scanning for ``m=audio`` in the answer, which
    this stub deliberately omits (video-only answer).
    """

    def handler(_request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            201,
            content=b"v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n",
            headers={"Content-Type": "application/sdp"},
        )

    return httpx.MockTransport(handler)


async def _build_adapter(
    consumer: FakeConsumerClient,
    sip: FakeSipBridge,
) -> tuple[UnofficialRingAdapter, httpx.AsyncClient]:
    """Construct an adapter with injected fakes and a WHEP mock transport.

    Returns the adapter plus the WHEP client so the caller can close it
    in a finally block (the adapter only closes WHEP clients it owns).
    """
    whep = httpx.AsyncClient(transport=_whep_mock_transport())
    adapter = UnofficialRingAdapter(
        client=consumer,  # type: ignore[arg-type]
        sip=sip,  # type: ignore[arg-type]
        sessions=StreamSessionMap(),
        max_concurrent=5,
        mediamtx_whep_base="http://mediamtx.test:8889",
        http=whep,
    )
    return adapter, whep


# ---------------------------------------------------------------------------
# Task 8.4 — Property 10: stream session lifecycle invariants
# ---------------------------------------------------------------------------


# Operation alphabet: either start a new session or tear one down. Both
# branches shrink cleanly; the list length dominates runtime and is kept
# modest so the Hypothesis loop stays well under the PBT deadline budget.
_operations = st.lists(
    st.sampled_from(["create", "delete"]),
    min_size=1,
    max_size=20,
)


@settings(
    max_examples=25,
    deadline=None,
    suppress_health_check=[
        HealthCheck.function_scoped_fixture,
        HealthCheck.too_slow,
    ],
)
@given(
    max_concurrent=st.integers(min_value=1, max_value=10),
    ops=_operations,
)
def test_property10_stream_session_lifecycle_invariants(
    max_concurrent: int, ops: list[str]
) -> None:
    """**Validates: Requirements 6.4, 6.5, 6.7**

    Invariants exercised for every random sequence of creates and deletes:
      - Unique UUID v4 ``session_id`` for every successful create (6.4).
      - Live count tracks the caller's model exactly and never exceeds
        ``max_concurrent`` (6.7).
      - ``StreamCapacityExceededError`` raises BEFORE the sidecar is
        contacted; the fake's ``start`` call count is unchanged (6.7).
      - After ``delete_stream_session`` completes, ``session_map.lookup``
        raises ``StreamSessionNotFoundError`` for that id (6.5).
    """

    async def run() -> None:
        sessions = StreamSessionMap()
        sip = FakeSipBridge()
        consumer = FakeConsumerClient()
        whep = httpx.AsyncClient(transport=_whep_mock_transport())
        try:
            adapter = UnofficialRingAdapter(
                client=consumer,  # type: ignore[arg-type]
                sip=sip,  # type: ignore[arg-type]
                sessions=sessions,
                max_concurrent=max_concurrent,
                mediamtx_whep_base="http://mediamtx.test:8889",
                http=whep,
            )

            active_ids: list[str] = []
            device_counter = 0

            for op in ops:
                if op == "create":
                    prior_start_calls = len(sip.start_calls)
                    device_id = f"dev_{device_counter}"
                    device_counter += 1
                    try:
                        result = await adapter.create_stream_session(
                            device_id=device_id, sdp_offer="v=0"
                        )
                    except StreamCapacityExceededError:
                        # Capacity rejection must happen before the sidecar
                        # is touched (Req 6.7) and must not mutate the map.
                        assert len(sip.start_calls) == prior_start_calls
                        assert await sessions.count() == len(active_ids)
                        continue

                    # Success path: id is a fresh UUID v4.
                    sid = result.session_id
                    uuid.UUID(sid, version=4)
                    assert sid not in active_ids
                    active_ids.append(sid)

                    # Live count tracks our model and stays under the cap.
                    assert await sessions.count() == len(active_ids)
                    assert len(active_ids) <= max_concurrent

                else:  # delete
                    if not active_ids:
                        continue  # nothing to delete in this step
                    # FIFO removal to keep the interleaving interesting.
                    sid = active_ids.pop(0)
                    await adapter.delete_stream_session(sid)

                    # lookup after delete must raise (Req 6.5).
                    with pytest.raises(StreamSessionNotFoundError):
                        await sessions.lookup(sid)
                    assert await sessions.count() == len(active_ids)

            # Final state matches our local model.
            assert await sessions.count() == len(active_ids)

            # Tear down any sessions the random sequence left active.
            await adapter.aclose()
            assert await sessions.count() == 0
        finally:
            await whep.aclose()

    asyncio.run(run())


# ---------------------------------------------------------------------------
# Task 8.5 — Example tests for error translation
# ---------------------------------------------------------------------------


async def test_ring_404_on_history_maps_to_device_not_found() -> None:
    """Ring 404 on history → ``DeviceNotFoundError`` (→ HTTP 404).

    Validates Requirement 4.5.
    """
    consumer = FakeConsumerClient()
    consumer.raise_on_history = _http_status_error(404)
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        with pytest.raises(DeviceNotFoundError) as exc_info:
            await adapter.list_events("missing_device", limit=10)
        assert exc_info.value.http_status == 404
    finally:
        await whep.aclose()


async def test_ring_404_on_snapshot_maps_to_snapshot_unavailable() -> None:
    """Ring 404 on snapshot → ``SnapshotUnavailableError`` (→ HTTP 503).

    Validates Requirement 5.2.
    """
    consumer = FakeConsumerClient()
    consumer.raise_on_snapshot = _http_status_error(404)
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        with pytest.raises(SnapshotUnavailableError) as exc_info:
            await adapter.download_snapshot("dev_1")
        assert exc_info.value.http_status == 503
    finally:
        await whep.aclose()


async def test_ring_204_on_snapshot_maps_to_snapshot_unavailable() -> None:
    """Ring 204 on snapshot → ``SnapshotUnavailableError`` (→ HTTP 503).

    Validates Requirement 5.2.
    """
    consumer = FakeConsumerClient()
    consumer.raise_on_snapshot = _http_status_error(204)
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        with pytest.raises(SnapshotUnavailableError) as exc_info:
            await adapter.download_snapshot("dev_1")
        assert exc_info.value.http_status == 503
    finally:
        await whep.aclose()


async def test_ring_429_on_snapshot_maps_to_rate_limited() -> None:
    """Ring 429 on snapshot → ``RateLimitedError`` (→ HTTP 429).

    Validates Requirement 5.3.
    """
    from app.adapters.errors import RateLimitedError

    consumer = FakeConsumerClient()
    consumer.raise_on_snapshot = _http_status_error(429)
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        with pytest.raises(RateLimitedError) as exc_info:
            await adapter.download_snapshot("dev_1")
        assert exc_info.value.http_status == 429
    finally:
        await whep.aclose()


async def test_ring_401_on_snapshot_maps_to_authentication_required() -> None:
    """Ring 401 on snapshot → ``AuthenticationRequiredError`` (→ HTTP 401).

    Validates Requirement 5.5.
    """
    from app.adapters.errors import AuthenticationRequiredError

    consumer = FakeConsumerClient()
    consumer.raise_on_snapshot = _http_status_error(401)
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        with pytest.raises(AuthenticationRequiredError) as exc_info:
            await adapter.download_snapshot("dev_1")
        assert exc_info.value.http_status == 401
    finally:
        await whep.aclose()


async def test_ring_402_on_clip_maps_to_subscription_required() -> None:
    """Ring 402 on clip → ``SubscriptionRequiredError`` (→ HTTP 402).

    Validates Requirement 5.4.
    """
    consumer = FakeConsumerClient()
    consumer.raise_on_clip = _http_status_error(402)
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        with pytest.raises(SubscriptionRequiredError) as exc_info:
            await adapter.download_video("dev_1", event_id="evt_1")
        assert exc_info.value.http_status == 402
    finally:
        await whep.aclose()


async def test_sidecar_timeout_propagates_as_upstream_timeout() -> None:
    """Sidecar 15 s timeout → ``UpstreamTimeoutError`` (→ HTTP 504).

    ``SipBridgeClient.start`` raises ``UpstreamTimeoutError`` when its
    15 s POST deadline lapses; the adapter must surface that error
    verbatim rather than wrapping it as an ``UpstreamUnavailableError``.
    """
    consumer = FakeConsumerClient()
    sip = FakeSipBridge(start_raises=UpstreamTimeoutError("sip bridge start timeout"))
    adapter, whep = await _build_adapter(consumer, sip)
    try:
        with pytest.raises(UpstreamTimeoutError) as exc_info:
            await adapter.create_stream_session("dev_1", sdp_offer="v=0")
        assert exc_info.value.http_status == 504
    finally:
        await whep.aclose()


async def test_snapshot_and_clip_are_not_cached_at_adapter_layer() -> None:
    """Adapter does not cache snapshot or clip URL responses (Req 5.5).

    Two successive adapter calls MUST result in two underlying client
    calls. (The adapter is the layer the tvOS app observes; caching at
    any layer beneath it would still leak stale URLs to the client.)
    """
    consumer = FakeConsumerClient()
    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        await adapter.download_snapshot("dev_1")
        await adapter.download_snapshot("dev_1")
        await adapter.download_video("dev_1", event_id="evt_1")
        await adapter.download_video("dev_1", event_id="evt_1")
    finally:
        await whep.aclose()

    assert consumer.get_snapshot_calls == ["dev_1", "dev_1"]
    assert consumer.get_clip_url_calls == ["evt_1", "evt_1"]


# ---------------------------------------------------------------------------
# list_devices filters non-camera kinds (Requirement 4.1)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_list_devices_filters_non_camera_kinds() -> None:
    """**Validates: Requirement 4.1**

    The adapter is contracted to return "the user's cameras and doorbells"
    from ``/mock/devices``. Ring's consumer API lumps every account
    accessory into one list (cameras, chimes, beams lights, keypads),
    so the adapter must apply ``is_camera_kind`` before emitting results.

    Given a mixed Ring response (2 cameras, 1 doorbell, 2 chimes, 1 base
    station), the adapter SHALL emit exactly 3 resources whose IDs match
    the camera-bearing devices and whose ``type`` values include no chime
    kinds.
    """
    mixed = [
        {"id": 1, "kind": "cocoa_doorbell", "description": "Front Door"},
        {"id": 2, "kind": "stickup_cam_v3", "description": "Backyard"},
        {"id": 3, "kind": "cocoa_floodlight", "description": "Driveway"},
        {"id": 4, "kind": "chime_v3", "description": "Downstairs"},
        {"id": 5, "kind": "chime_pro_v2", "description": "Office"},
        {"id": 6, "kind": "base_station_v1", "description": "Alarm Base"},
    ]

    consumer = FakeConsumerClient()

    async def _get_devices() -> list[dict[str, Any]]:
        consumer.get_devices_calls += 1
        return mixed

    # Rebind the method on this instance only so we don't perturb the shared fake.
    consumer.get_devices = _get_devices  # type: ignore[method-assign]

    adapter, whep = await _build_adapter(consumer, FakeSipBridge())
    try:
        result = await adapter.list_devices()
    finally:
        await whep.aclose()

    ids = sorted(int(d["id"]) for d in result["data"])
    kinds = {d["type"] for d in result["data"]}

    assert ids == [1, 2, 3], "expected only camera-bearing devices"
    assert "chime_v3" not in kinds
    assert "chime_pro_v2" not in kinds
    assert "base_station_v1" not in kinds


# ---------------------------------------------------------------------------
# Task 10.3 — Property 13: Capacity Enforcement
# ---------------------------------------------------------------------------


@settings(
    max_examples=50,
    deadline=None,
    suppress_health_check=[
        HealthCheck.function_scoped_fixture,
        HealthCheck.too_slow,
    ],
)
@given(
    max_concurrent=st.integers(min_value=1, max_value=10),
    sessions_to_create=st.integers(min_value=0, max_value=10),
)
def test_property13_capacity_enforcement(
    max_concurrent: int,
    sessions_to_create: int,
) -> None:
    """**Validates: Requirements 3.5**

    Property 13: Capacity Enforcement.

    When the session map already holds ``max_concurrent`` sessions,
    ``create_stream_session`` MUST raise ``StreamCapacityExceededError``
    WITHOUT contacting the SIP bridge (i.e. ``sip.start`` call count is
    unchanged).

    For cases where ``sessions_to_create < max_concurrent`` the map has
    room; the call succeeds and the SIP bridge IS contacted exactly once.
    """
    # Clamp sessions_to_create to [0, max_concurrent] so the generator
    # covers the boundary (full) and sub-capacity cases.
    sessions_to_create = min(sessions_to_create, max_concurrent)

    async def run() -> None:
        sessions = StreamSessionMap()
        sip = FakeSipBridge()
        consumer = FakeConsumerClient()
        whep = httpx.AsyncClient(transport=_whep_mock_transport())
        try:
            adapter = UnofficialRingAdapter(
                client=consumer,  # type: ignore[arg-type]
                sip=sip,  # type: ignore[arg-type]
                sessions=sessions,
                max_concurrent=max_concurrent,
                mediamtx_whep_base="http://mediamtx.test:8889",
                http=whep,
            )

            # Pre-fill the session map with ``sessions_to_create`` sessions.
            for i in range(sessions_to_create):
                await adapter.create_stream_session(device_id=f"dev_prefill_{i}", sdp_offer="v=0")

            assert await sessions.count() == sessions_to_create

            # Record the SIP bridge start call count before the probe call.
            start_calls_before = len(sip.start_calls)

            if sessions_to_create == max_concurrent:
                # Map is at capacity — must raise without touching the bridge.
                with pytest.raises(StreamCapacityExceededError):
                    await adapter.create_stream_session(device_id="dev_probe", sdp_offer="v=0")

                # SIP bridge must NOT have been called.
                assert len(sip.start_calls) == start_calls_before, (
                    f"sip.start was called {len(sip.start_calls) - start_calls_before} "
                    f"time(s) after capacity was exceeded "
                    f"(max_concurrent={max_concurrent}, active={sessions_to_create})"
                )

                # Session count must be unchanged.
                assert await sessions.count() == max_concurrent
            else:
                # Map has room — call must succeed and bridge must be contacted.
                result = await adapter.create_stream_session(device_id="dev_probe", sdp_offer="v=0")
                assert result.session_id  # non-empty UUID
                assert len(sip.start_calls) == start_calls_before + 1
                assert await sessions.count() == sessions_to_create + 1

        finally:
            await whep.aclose()

    asyncio.run(run())
