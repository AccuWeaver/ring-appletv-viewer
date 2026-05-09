"""Integration test: SnapshotRefreshJob → SnapshotCache → SourceRouter pipeline.

Verifies that:
1. After _execute_cycle() runs, the cache is populated for each device.
2. Subsequent download_snapshot() calls are served from the cache without
   invoking the adapter again.

Requirements: 6.2, 6.4, 6.5
"""

from __future__ import annotations

from dataclasses import dataclass, field

import pytest

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.session_map import StreamSessionMap
from app.routing.health_manager import HealthManager
from app.routing.snapshot_cache import SnapshotCache
from app.routing.snapshot_refresh_job import SnapshotRefreshJob
from app.routing.source_router import SourceRouter

# ---------------------------------------------------------------------------
# FakeAdapter — returns a known snapshot payload and tracks call counts
# ---------------------------------------------------------------------------

_KNOWN_SNAPSHOT_BYTES = b"\x89PNG\r\n\x1a\n" + b"\x00" * 59  # 67-byte fake PNG
_KNOWN_CONTENT_TYPE = "image/png"
_DEVICE_IDS = ["device-alpha", "device-beta"]


@dataclass
class FakeAdapter(RingAdapter):
    """Minimal RingAdapter test double with call-count tracking.

    Returns a known snapshot payload for every device so the test can
    assert that the cache was populated with the expected bytes.
    """

    _mode: str = "unofficial"
    device_ids: list[str] = field(default_factory=lambda: list(_DEVICE_IDS))
    snapshot_call_count: dict[str, int] = field(default_factory=dict)

    def mode(self) -> str:
        return self._mode

    async def list_devices(self) -> dict:
        return {"data": [{"id": did} for did in self.device_ids]}

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        return []

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        self.snapshot_call_count[device_id] = self.snapshot_call_count.get(device_id, 0) + 1
        return SnapshotPayload(_KNOWN_SNAPSHOT_BYTES, _KNOWN_CONTENT_TYPE)

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        return {"url": "https://example.com/clip.mp4"}

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        return StreamSessionResult(
            sdp_answer="v=0\r\n",
            location=f"/mock/session/fake-{self._mode}",
            session_id=f"fake-{self._mode}",
        )

    async def delete_stream_session(self, session_id: str) -> None:
        pass


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _build_pipeline(
    adapter: FakeAdapter,
    *,
    ttl_fresh_seconds: int = 120,
    ttl_stale_serve_seconds: int = 600,
) -> tuple[SnapshotCache, SourceRouter, SnapshotRefreshJob]:
    """Construct the full refresh-job → cache → router pipeline."""
    cache = SnapshotCache(
        max_bytes=10_000_000,
        ttl_fresh_seconds=ttl_fresh_seconds,
        ttl_stale_serve_seconds=ttl_stale_serve_seconds,
    )
    router = SourceRouter(
        routing_profile=[adapter],
        health_manager=HealthManager(quarantine_threshold=10, quarantine_seconds=3600),
        snapshot_cache=cache,
        session_map=StreamSessionMap(),
    )
    job = SnapshotRefreshJob(source_router=router, interval_seconds=45)
    return cache, router, job


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_refresh_cycle_populates_cache_for_all_devices() -> None:
    """After _execute_cycle(), the cache has a fresh entry for every device.

    Requirements: 6.2, 6.5
    """
    adapter = FakeAdapter(device_ids=list(_DEVICE_IDS))
    cache, _router, job = _build_pipeline(adapter)

    # Cache must be empty before the cycle runs.
    assert cache.entry_count == 0, "Cache should be empty before the refresh cycle"

    await job._execute_cycle()

    # After the cycle, every device must have a fresh cache entry.
    assert cache.entry_count == len(_DEVICE_IDS), (
        f"Expected {len(_DEVICE_IDS)} cache entries after refresh cycle, got {cache.entry_count}"
    )
    for device_id in _DEVICE_IDS:
        entry = cache.get(device_id)
        assert entry is not None, (
            f"Expected a fresh cache entry for device_id={device_id!r} "
            "after the refresh cycle, but cache.get() returned None"
        )
        assert entry.content == _KNOWN_SNAPSHOT_BYTES, (
            f"Cache entry for {device_id!r} has unexpected content"
        )
        assert entry.content_type == _KNOWN_CONTENT_TYPE, (
            f"Cache entry for {device_id!r} has unexpected content_type"
        )
        assert entry.source_mode == adapter.mode(), (
            f"Cache entry for {device_id!r} has unexpected source_mode "
            f"(expected {adapter.mode()!r}, got {entry.source_mode!r})"
        )


@pytest.mark.asyncio
async def test_subsequent_snapshot_requests_served_from_cache() -> None:
    """After _execute_cycle(), download_snapshot() is served from cache.

    The adapter must NOT be called again for a second download_snapshot()
    request because the cache entry is still fresh.

    Requirements: 6.2, 6.4, 6.5
    """
    device_id = _DEVICE_IDS[0]
    adapter = FakeAdapter(device_ids=[device_id])
    cache, router, job = _build_pipeline(adapter)

    # Run the refresh cycle — this populates the cache.
    await job._execute_cycle()

    # The adapter should have been called exactly once (by the refresh job).
    calls_after_refresh = adapter.snapshot_call_count.get(device_id, 0)
    assert calls_after_refresh == 1, (
        f"Expected adapter to be called once during refresh cycle, got {calls_after_refresh}"
    )

    # Now call download_snapshot() via the router — should hit the cache.
    result = await router.download_snapshot(device_id)

    assert result.payload is not None, "Expected a payload from the cached snapshot"
    assert isinstance(result.payload, SnapshotPayload), (
        f"Expected SnapshotPayload, got {type(result.payload)}"
    )
    assert result.payload.content == _KNOWN_SNAPSHOT_BYTES, (
        "Cached snapshot content does not match the known bytes"
    )
    assert result.payload.content_type == _KNOWN_CONTENT_TYPE, (
        "Cached snapshot content_type does not match"
    )

    # The adapter must NOT have been called again — the cache served the response.
    calls_after_router = adapter.snapshot_call_count.get(device_id, 0)
    assert calls_after_router == 1, (
        f"Expected adapter call count to remain at 1 after cache hit, "
        f"got {calls_after_router}. The router should have served from cache "
        "without invoking the adapter."
    )


@pytest.mark.asyncio
async def test_cache_age_not_set_for_fresh_cache_hit() -> None:
    """A fresh cache hit must NOT set cache_age_seconds (no stale-serve header).

    Requirements: 6.2, 6.9
    """
    device_id = _DEVICE_IDS[0]
    adapter = FakeAdapter(device_ids=[device_id])
    _cache, router, job = _build_pipeline(adapter, ttl_fresh_seconds=120)

    await job._execute_cycle()

    result = await router.download_snapshot(device_id)

    assert result.payload is not None, "Expected a payload from the fresh cache"
    assert result.cache_age_seconds is None, (
        f"Expected cache_age_seconds=None for a fresh cache hit, "
        f"got cache_age_seconds={result.cache_age_seconds}. "
        "The X-Ring-Snapshot-Age header must only be set for stale entries."
    )


@pytest.mark.asyncio
async def test_source_mode_from_cache_entry_matches_adapter() -> None:
    """The source_mode on a cached result must match the adapter that produced it.

    Requirements: 6.2, 6.10
    """
    device_id = _DEVICE_IDS[0]
    adapter = FakeAdapter(_mode="unofficial", device_ids=[device_id])
    _cache, router, job = _build_pipeline(adapter)

    await job._execute_cycle()

    result = await router.download_snapshot(device_id)

    assert result.source_mode == "unofficial", (
        f"Expected source_mode='unofficial' from cached entry, "
        f"got source_mode={result.source_mode!r}"
    )


@pytest.mark.asyncio
async def test_refresh_cycle_with_single_device() -> None:
    """Refresh cycle works correctly with a single device.

    Requirements: 6.5
    """
    device_id = "device-solo"
    adapter = FakeAdapter(device_ids=[device_id])
    cache, router, job = _build_pipeline(adapter)

    await job._execute_cycle()

    assert cache.entry_count == 1
    entry = cache.get(device_id)
    assert entry is not None
    assert entry.content == _KNOWN_SNAPSHOT_BYTES

    # Second call via router must be served from cache.
    result = await router.download_snapshot(device_id)
    assert result.payload is not None
    assert result.payload.content == _KNOWN_SNAPSHOT_BYTES
    assert adapter.snapshot_call_count.get(device_id, 0) == 1, (
        "Adapter must not be called again after cache is populated"
    )


@pytest.mark.asyncio
async def test_refresh_cycle_with_no_devices_leaves_cache_empty() -> None:
    """Refresh cycle with an empty device list leaves the cache empty.

    Requirements: 6.5
    """
    adapter = FakeAdapter(device_ids=[])
    cache, _router, job = _build_pipeline(adapter)

    await job._execute_cycle()

    assert cache.entry_count == 0, "Cache should remain empty when the device list is empty"
