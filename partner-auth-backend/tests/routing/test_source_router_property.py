"""Property-based tests for SourceRouter.

# Feature: ring-adapter-live-media

Properties covered:
- Property 5: X-Ring-Source Header Correctness (Requirements 1.8, 6.10, 13.1)
- Property 8: Cache-First Snapshot Path (Requirements 6.2, 13.3)
- Property 9: Stale-Serve with Age Header (Requirements 6.8, 6.9, 6.10)
"""

from __future__ import annotations

import asyncio
import logging
import time as _time
import uuid as _uuid
from contextlib import contextmanager, suppress
from dataclasses import dataclass, field
from unittest.mock import patch

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.errors import (
    AuthenticationRequiredError,
    DeviceNotFoundError,
    RateLimitedError,
    RingAdapterError,
    StreamCapacityExceededError,
    SubscriptionRequiredError,
    UpstreamUnavailableError,
)
from app.adapters.failure_class import FALLBACK_ELIGIBLE, FailureClass
from app.adapters.session_map import StreamSessionMap
from app.adapters.types import (
    BaseStreamSession,
    MockStreamSession,
    PartnerStreamSession,
    UnofficialStreamSession,
)
from app.routing.health_manager import HealthManager
from app.routing.snapshot_cache import SnapshotCache
from app.routing.source_result import SourceResult
from app.routing.source_router import SourceRouter

# ---------------------------------------------------------------------------
# FakeAdapter — configurable test double
# ---------------------------------------------------------------------------


@dataclass
class FakeAdapter(RingAdapter):
    """Minimal RingAdapter test double.

    Attributes:
        _mode: The mode string returned by mode().
        should_succeed: If True, all operations return a dummy payload.
            If False, all operations raise UpstreamUnavailableError
            (a fallback-eligible failure).
        non_fallback_error: If set, raises this error instead of the
            default UpstreamUnavailableError (used to test non-fallback stops).
    """

    _mode: str
    should_succeed: bool = True
    non_fallback_error: RingAdapterError | None = None
    download_snapshot_calls: list[str] = field(default_factory=list)

    def mode(self) -> str:
        return self._mode

    async def list_devices(self) -> dict:
        return self._result_or_raise({"data": []})

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        return self._result_or_raise([])

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        self.download_snapshot_calls.append(device_id)
        return self._result_or_raise(SnapshotPayload(b"img", "image/jpeg"))

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

    def _result_or_raise(self, value):
        if self.non_fallback_error is not None:
            raise self.non_fallback_error
        if not self.should_succeed:
            raise UpstreamUnavailableError(f"{self._mode} unavailable")
        return value


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

VALID_MODES = ["partner", "unofficial", "mock"]


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


def _make_router_with_cache(
    adapters: list[FakeAdapter],
    cache: SnapshotCache,
) -> SourceRouter:
    """Build a SourceRouter with a caller-supplied SnapshotCache."""
    return SourceRouter(
        routing_profile=adapters,
        health_manager=HealthManager(quarantine_threshold=100, quarantine_seconds=3600),
        snapshot_cache=cache,
        session_map=StreamSessionMap(),
    )


def _run(coro) -> SourceResult:
    """Run an async coroutine synchronously in tests."""
    return asyncio.run(coro)


# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

# A non-empty list of distinct mode strings drawn from VALID_MODES.
# We use permutations of a subset so modes are always distinct (no duplicate
# adapters in the profile, which the router doesn't support).
distinct_modes_st = st.lists(
    st.sampled_from(VALID_MODES),
    min_size=1,
    max_size=3,
    unique=True,
)

# Index into a list of adapters — used to pick which adapter succeeds.
# Generated lazily via st.data() so we can constrain to the actual list size.


# ===========================================================================
# Property 5: X-Ring-Source Header Correctness
# **Validates: Requirements 1.8, 6.10, 13.1**
# ===========================================================================

# ---------------------------------------------------------------------------
# Property 5a: Primary source success — source_mode equals that source's mode()
#
# When the first adapter in the profile succeeds, SourceResult.source_mode
# must equal that adapter's mode().
#
# Validates: Requirements 1.8, 13.1
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(modes=distinct_modes_st)
def test_source_mode_equals_succeeding_adapter_mode(modes: list[str]) -> None:
    """**Validates: Requirements 1.8, 13.1**

    Property 5a: When the first adapter succeeds, source_mode equals its mode().
    """
    # All adapters succeed; the first one in the profile should be used.
    adapters = [FakeAdapter(_mode=m, should_succeed=True) for m in modes]
    router = _make_router(adapters)

    result = _run(router.list_devices())

    assert result.source_mode == modes[0], (
        f"Expected source_mode={modes[0]!r} (first adapter), "
        f"got source_mode={result.source_mode!r} for profile={modes}"
    )
    assert result.payload is not None, "Expected a payload on success"


# ---------------------------------------------------------------------------
# Property 5b: Fallback — source_mode equals the mode of the source that
# ultimately succeeded after earlier sources failed with fallback-eligible errors.
#
# Validates: Requirements 1.8, 6.10, 13.1
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    modes=distinct_modes_st,
    data=st.data(),
)
def test_source_mode_equals_fallback_adapter_mode(modes: list[str], data) -> None:
    """**Validates: Requirements 1.8, 6.10, 13.1**

    Property 5b: When fallback occurs, source_mode equals the mode of the
    adapter that ultimately succeeded.
    """
    if len(modes) < 2:
        # Need at least 2 adapters to test fallback
        return

    # Pick a success index: at least one adapter fails before it
    success_idx = data.draw(st.integers(min_value=1, max_value=len(modes) - 1))

    adapters = [
        FakeAdapter(_mode=m, should_succeed=(i == success_idx)) for i, m in enumerate(modes)
    ]
    router = _make_router(adapters)

    result = _run(router.list_devices())

    expected_mode = modes[success_idx]
    assert result.source_mode == expected_mode, (
        f"Expected source_mode={expected_mode!r} (fallback adapter at index {success_idx}), "
        f"got source_mode={result.source_mode!r} for profile={modes}"
    )
    assert result.payload is not None, (
        f"Expected a payload when adapter at index {success_idx} succeeds"
    )


# ---------------------------------------------------------------------------
# Property 5c: All sources fail — source_mode equals the mode of the last
# attempted source (the last in the profile that was not quarantined).
#
# Validates: Requirements 1.8, 13.1
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(modes=distinct_modes_st)
def test_source_mode_equals_last_attempted_when_all_fail(modes: list[str]) -> None:
    """**Validates: Requirements 1.8, 13.1**

    Property 5c: When all sources fail with fallback-eligible errors,
    source_mode equals the mode of the last attempted source.
    """
    adapters = [FakeAdapter(_mode=m, should_succeed=False) for m in modes]
    router = _make_router(adapters)

    result = _run(router.list_devices())

    # The last adapter in the profile is the last attempted
    expected_mode = modes[-1]
    assert result.source_mode == expected_mode, (
        f"Expected source_mode={expected_mode!r} (last adapter), "
        f"got source_mode={result.source_mode!r} for profile={modes}"
    )
    assert result.payload is None, "Expected no payload when all sources fail"
    assert result.error is not None, "Expected an error when all sources fail"


# ---------------------------------------------------------------------------
# Property 5d: Non-fallback failure — source_mode equals the failing adapter's
# mode(), even though routing stopped immediately.
#
# Validates: Requirements 1.8, 13.1
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    modes=distinct_modes_st,
    data=st.data(),
)
def test_source_mode_equals_non_fallback_failing_adapter_mode(modes: list[str], data) -> None:
    """**Validates: Requirements 1.8, 13.1**

    Property 5d: When a non-fallback failure occurs, source_mode equals the
    mode of the adapter that raised the non-fallback error.
    """
    # Pick which adapter raises the non-fallback error
    fail_idx = data.draw(st.integers(min_value=0, max_value=len(modes) - 1))

    adapters = []
    for i, m in enumerate(modes):
        if i < fail_idx:
            # Adapters before fail_idx fail with fallback-eligible errors
            # so routing continues until it reaches fail_idx.
            adapters.append(FakeAdapter(_mode=m, should_succeed=False))
        elif i == fail_idx:
            # This adapter raises a non-fallback error
            adapters.append(
                FakeAdapter(
                    _mode=m,
                    should_succeed=False,
                    non_fallback_error=AuthenticationRequiredError("token expired"),
                )
            )
        else:
            # Adapters after fail_idx are never reached
            adapters.append(FakeAdapter(_mode=m, should_succeed=True))

    router = _make_router(adapters)

    result = _run(router.list_devices())

    expected_mode = modes[fail_idx]
    assert result.source_mode == expected_mode, (
        f"Expected source_mode={expected_mode!r} (non-fallback failing adapter at "
        f"index {fail_idx}), got source_mode={result.source_mode!r} for profile={modes}"
    )
    assert result.payload is None, "Expected no payload on non-fallback failure"
    assert result.error is not None, "Expected an error on non-fallback failure"


# ---------------------------------------------------------------------------
# Property 5e: source_mode is consistent across all operations
#
# The source_mode invariant must hold for every operation type, not just
# list_devices. We verify it for list_events, download_video, and
# create_stream_session with a single-adapter profile.
#
# Validates: Requirements 1.8, 6.10, 13.1
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    mode=st.sampled_from(VALID_MODES),
    operation=st.sampled_from(["list_devices", "list_events", "download_video"]),
)
def test_source_mode_consistent_across_operations(mode: str, operation: str) -> None:
    """**Validates: Requirements 1.8, 6.10, 13.1**

    Property 5e: source_mode equals the adapter's mode() for every operation type.
    """
    adapter = FakeAdapter(_mode=mode, should_succeed=True)
    router = _make_router([adapter])

    if operation == "list_devices":
        result = _run(router.list_devices())
    elif operation == "list_events":
        result = _run(router.list_events("device-1", 10))
    elif operation == "download_video":
        result = _run(router.download_video("device-1", None))
    else:
        pytest.fail(f"Unexpected operation: {operation}")

    assert result.source_mode == mode, (
        f"Expected source_mode={mode!r} for operation={operation!r}, "
        f"got source_mode={result.source_mode!r}"
    )
    assert result.payload is not None


# ===========================================================================
# Property 9: Stale-Serve with Age Header
# **Validates: Requirements 6.8, 6.9, 6.10**
# ===========================================================================

# ---------------------------------------------------------------------------
# Strategies for Property 9
# ---------------------------------------------------------------------------

# Device IDs: short non-empty strings
_device_id_st = st.text(
    alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd"), whitelist_characters="-_"),
    min_size=1,
    max_size=20,
)

# Snapshot content: non-empty bytes
_snapshot_content_st = st.binary(min_size=1, max_size=512)

# Source modes for the cache entry
_source_mode_st = st.sampled_from(["unofficial", "partner", "mock"])

# TTL_fresh: between 10 and 120 seconds
_ttl_fresh_st = st.integers(min_value=10, max_value=120)


@given(
    device_id=_device_id_st,
    content=_snapshot_content_st,
    content_type=st.sampled_from(["image/jpeg", "image/png"]),
    cached_source_mode=_source_mode_st,
    ttl_fresh=_ttl_fresh_st,
    # stale_age_seconds: age of the cache entry, clamped to (ttl_fresh, ttl_stale_serve)
    # ttl_stale_serve is fixed at ttl_fresh * 10 to give a wide stale window.
    stale_age_seconds=st.integers(min_value=1, max_value=899),
)
@settings(max_examples=200)
def test_stale_serve_with_age_header(
    device_id: str,
    content: bytes,
    content_type: str,
    cached_source_mode: str,
    ttl_fresh: int,
    stale_age_seconds: int,
) -> None:
    """**Validates: Requirements 6.8, 6.9, 6.10**

    Property 9: Stale-Serve with Age Header

    When all adapters in the profile fail with UpstreamUnavailableError and
    the Snapshot_Cache contains a stale-but-servable entry for the device:

    1. SourceResult.payload contains the stale cached bytes (Requirement 6.8).
    2. SourceResult.cache_age_seconds equals the actual age in whole seconds
       (Requirement 6.9).
    3. SourceResult.source_mode equals the source_mode stored in the cache
       entry (Requirement 6.10).
    """
    # Fix ttl_stale_serve to be 10× ttl_fresh so there is always a wide stale window.
    ttl_stale_serve = ttl_fresh * 10  # e.g. 100–1200 seconds

    # Clamp stale_age_seconds to (ttl_fresh, ttl_stale_serve) exclusive so the
    # entry is stale (age > ttl_fresh) but still servable (age < ttl_stale_serve).
    stale_age_seconds = max(ttl_fresh + 1, min(stale_age_seconds, ttl_stale_serve - 1))

    # Anchor "now" to a fixed epoch offset for determinism.
    now = 1_700_000_000.0
    fetched_at = now - stale_age_seconds

    # Build a cache with the chosen TTL parameters.
    cache = SnapshotCache(
        ttl_fresh_seconds=ttl_fresh,
        ttl_stale_serve_seconds=ttl_stale_serve,
    )

    # Pre-populate the cache with a stale entry by freezing time at fetched_at.
    with patch("app.routing.snapshot_cache.time.time", return_value=fetched_at):
        cache.put(
            device_id=device_id,
            content=content,
            content_type=content_type,
            source_mode=cached_source_mode,
        )

    # Build a SourceRouter whose entire profile fails with UpstreamUnavailableError.
    # Use two real-source modes so the "always show real data" guard does not
    # interfere (mock is not in the profile).
    failing_adapters: list[RingAdapter] = [
        FakeAdapter(_mode="unofficial", should_succeed=False),
        FakeAdapter(_mode="partner", should_succeed=False),
    ]
    router = SourceRouter(
        routing_profile=failing_adapters,
        health_manager=HealthManager(quarantine_threshold=100, quarantine_seconds=3600),
        snapshot_cache=cache,
        session_map=StreamSessionMap(),
    )

    # Run download_snapshot with time frozen at `now` so age_seconds is deterministic.
    with patch("app.routing.snapshot_cache.time.time", return_value=now):
        result = _run(router.download_snapshot(device_id))

    # --- Assertions ---

    # 1. Payload must contain the stale cached bytes (Requirement 6.8).
    assert result.payload is not None, (
        "Expected a stale cache payload but got None — stale-serve did not trigger. "
        f"device_id={device_id!r}, stale_age_seconds={stale_age_seconds}, "
        f"ttl_fresh={ttl_fresh}, ttl_stale_serve={ttl_stale_serve}"
    )
    assert isinstance(result.payload, SnapshotPayload), (
        f"Expected SnapshotPayload, got {type(result.payload)}"
    )
    assert result.payload.content == content, (
        "Stale payload content does not match the cached bytes"
    )
    assert result.payload.content_type == content_type, (
        "Stale payload content_type does not match the cached content_type"
    )

    # 2. cache_age_seconds must equal the actual age in whole seconds (Requirement 6.9).
    expected_age = int(now - fetched_at)  # mirrors SnapshotCacheEntry.age_seconds()
    assert result.cache_age_seconds == expected_age, (
        f"Expected cache_age_seconds={expected_age}, got {result.cache_age_seconds}. "
        f"stale_age_seconds={stale_age_seconds}, now={now}, fetched_at={fetched_at}"
    )

    # 3. source_mode must equal the mode stored in the cache entry (Requirement 6.10).
    assert result.source_mode == cached_source_mode, (
        f"Expected source_mode={cached_source_mode!r}, got {result.source_mode!r}"
    )


# ===========================================================================
# Property 4: Real Data Guarantee
#
# Tests that mock is NEVER used for live media when a real source is up,
# and that mock IS used when all real sources are quarantined.
#
# **Validates: Requirements 1.7, 7.1, 7.2, 7.4**
# ===========================================================================

_REAL_MODES = ["unofficial", "partner"]
_MOCK_MODE = "mock"

# Live-media operations subject to the "always show real data" guard.
_live_media_op_st = st.sampled_from(["create_stream_session", "download_snapshot"])

# Non-live-media operations NOT subject to the guard.
_non_live_op_st = st.sampled_from(["list_devices", "list_events", "download_video"])


def _make_router_with_quarantine(
    adapters: list[FakeAdapter],
    *,
    quarantine_threshold: int = 3,
) -> tuple[SourceRouter, HealthManager]:
    """Build a SourceRouter with a configurable quarantine threshold.

    Returns both the router and the HealthManager so tests can drive
    sources into quarantine.
    """
    hm = HealthManager(
        quarantine_threshold=quarantine_threshold,
        quarantine_seconds=3600,
    )
    router = SourceRouter(
        routing_profile=adapters,
        health_manager=hm,
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )
    return router, hm


def _quarantine_source(
    hm: HealthManager,
    mode: str,
    operation: str,
    threshold: int,
) -> None:
    """Drive a source into quarantine by recording threshold failures."""
    for _ in range(threshold):
        hm.record_failure(mode, operation, FailureClass.UPSTREAM_UNAVAILABLE)


async def _invoke_live_media_op(router: SourceRouter, operation: str) -> SourceResult:
    """Invoke a live-media operation on the router."""
    if operation == "create_stream_session":
        return await router.create_stream_session("dev-1", "v=0\r\n")
    elif operation == "download_snapshot":
        return await router.download_snapshot("dev-1")
    else:
        raise ValueError(f"unknown live-media operation: {operation!r}")


# ---------------------------------------------------------------------------
# Property 4a: Mock is NEVER called for live media when a real source is up
#
# For any profile containing at least one real source and mock, when the
# real source(s) are healthy (up), the mock adapter must never be invoked
# for live-media operations.
#
# Validates: Requirements 1.7, 7.1, 7.2, 7.4
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    real_modes=st.lists(
        st.sampled_from(_REAL_MODES),
        min_size=1,
        max_size=2,
        unique=True,
    ),
    operation=_live_media_op_st,
)
def test_mock_never_called_when_real_source_is_up(
    real_modes: list[str],
    operation: str,
) -> None:
    """**Validates: Requirements 1.7, 7.1, 7.2, 7.4**

    Property 4a: Real Data Guarantee (positive case)

    When the profile contains at least one real source AND mock, and the
    real source(s) are healthy, the mock adapter MUST NOT be called for
    live-media operations (create_stream_session, download_snapshot).
    """
    # Build profile: real sources first (all healthy), then mock
    real_adapters = [_CountingFakeAdapter(_mode=m, should_succeed=True) for m in real_modes]
    mock_adapter = _CountingFakeAdapter(_mode=_MOCK_MODE, should_succeed=True)
    profile = real_adapters + [mock_adapter]

    router = _make_router(profile)

    _run(_invoke_live_media_op(router, operation))

    assert mock_adapter.call_count == 0, (
        f"Mock adapter was called {mock_adapter.call_count} time(s) for "
        f"operation={operation!r} with real modes={real_modes!r} all healthy. "
        "Mock must never be used for live media when a real source is up."
    )

    # Exactly one real adapter should have been called (the first healthy one)
    total_real_calls = sum(a.call_count for a in real_adapters)
    assert total_real_calls == 1, (
        f"Expected exactly 1 real adapter call, got {total_real_calls} "
        f"(real_modes={real_modes!r}, operation={operation!r})"
    )


# ---------------------------------------------------------------------------
# Property 4b: Mock IS used when all real sources are quarantined
#
# When every real source in the profile is quarantined (Health_State=down),
# the router MUST fall through to mock for live-media operations.
#
# Validates: Requirements 1.7, 7.2
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    real_modes=st.lists(
        st.sampled_from(_REAL_MODES),
        min_size=1,
        max_size=2,
        unique=True,
    ),
    operation=_live_media_op_st,
    quarantine_threshold=st.integers(min_value=1, max_value=5),
)
def test_mock_is_used_when_all_real_sources_quarantined(
    real_modes: list[str],
    operation: str,
    quarantine_threshold: int,
) -> None:
    """**Validates: Requirements 1.7, 7.2**

    Property 4b: Real Data Guarantee (inverse case)

    When every real source in the profile is quarantined (Health_State=down),
    the router MUST attempt the mock adapter for live-media operations.
    """
    real_adapters = [_CountingFakeAdapter(_mode=m, should_succeed=True) for m in real_modes]
    mock_adapter = _CountingFakeAdapter(_mode=_MOCK_MODE, should_succeed=True)
    profile = real_adapters + [mock_adapter]

    router, hm = _make_router_with_quarantine(profile, quarantine_threshold=quarantine_threshold)

    # Quarantine all real sources for this operation
    for mode in real_modes:
        _quarantine_source(hm, mode, operation, quarantine_threshold)

    _run(_invoke_live_media_op(router, operation))

    assert mock_adapter.call_count == 1, (
        f"Expected mock adapter to be called exactly once when all real sources "
        f"are quarantined, but call_count={mock_adapter.call_count} "
        f"(real_modes={real_modes!r}, operation={operation!r})"
    )

    # Quarantined real adapters must NOT have been called
    for adapter in real_adapters:
        assert adapter.call_count == 0, (
            f"Quarantined real adapter mode={adapter.mode()!r} was called "
            f"{adapter.call_count} time(s) — quarantined sources must be skipped."
        )


# ---------------------------------------------------------------------------
# Property 4c: Mock not called when second real source is up after first fails
#
# When the first real source fails with a fallback-eligible error and a second
# real source is healthy, the router must use the second real source and must
# NOT fall through to mock.
#
# Validates: Requirements 1.5, 1.7, 7.1
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(operation=_live_media_op_st)
def test_mock_not_called_when_second_real_source_is_up(operation: str) -> None:
    """**Validates: Requirements 1.5, 1.7, 7.1**

    Property 4c: Real Data Guarantee (two real sources, first fails)

    When the first real source returns a fallback-eligible error and the
    second real source is healthy, the router must use the second real source
    and must NOT call mock.
    """
    failing_real = _CountingFakeAdapter(
        _mode="unofficial",
        should_succeed=False,  # raises UpstreamUnavailableError (fallback-eligible)
    )
    healthy_real = _CountingFakeAdapter(_mode="partner", should_succeed=True)
    mock_adapter = _CountingFakeAdapter(_mode=_MOCK_MODE, should_succeed=True)
    profile = [failing_real, healthy_real, mock_adapter]

    router = _make_router(profile)

    _run(_invoke_live_media_op(router, operation))

    assert mock_adapter.call_count == 0, (
        f"Mock was called {mock_adapter.call_count} time(s) even though a "
        f"healthy real source (partner) was available. operation={operation!r}"
    )
    assert failing_real.call_count == 1, (
        f"Expected failing real adapter to be attempted once, "
        f"got call_count={failing_real.call_count}"
    )
    assert healthy_real.call_count == 1, (
        f"Expected healthy real adapter to be called once, got call_count={healthy_real.call_count}"
    )


# ---------------------------------------------------------------------------
# Property 4d: Real-data guard does NOT apply to non-live-media operations
#
# For non-live-media operations (list_devices, list_events, download_video),
# mock may be used normally when it is the only source in the profile.
#
# Validates: Requirements 1.7 (guard is scoped to Live_Media_Path)
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(operation=_non_live_op_st)
def test_real_data_guard_does_not_apply_to_non_live_media(operation: str) -> None:
    """**Validates: Requirements 1.7**

    Property 4d: Real-data guard is scoped to live-media operations only.

    For non-live-media operations, mock may be used even when it is the
    only source in the profile — the guard must not interfere.
    """
    mock_adapter = _CountingFakeAdapter(_mode=_MOCK_MODE, should_succeed=True)
    router = _make_router([mock_adapter])

    async def _invoke_non_live(op: str) -> SourceResult:
        if op == "list_devices":
            return await router.list_devices()
        elif op == "list_events":
            return await router.list_events("dev-1", 10)
        elif op == "download_video":
            return await router.download_video("dev-1", None)
        else:
            raise ValueError(f"unknown non-live operation: {op!r}")

    _run(_invoke_non_live(operation))

    assert mock_adapter.call_count == 1, (
        f"Expected mock to be called for non-live-media op={operation!r}, "
        f"got call_count={mock_adapter.call_count}"
    )


# ===========================================================================
# Property 3: Non-Fallback Stops Routing
#
# Feature: ring-adapter-live-media
# Validates: Requirements 1.6
# ===========================================================================

# Non-fallback error types (per design: AUTHENTICATION, NOT_FOUND,
# SUBSCRIPTION_REQUIRED, RATE_LIMITED, CAPACITY_EXCEEDED, INTERNAL,
# CONFIGURATION are all non-fallback).
_NON_FALLBACK_ERROR_TYPES = [
    AuthenticationRequiredError,
    DeviceNotFoundError,
    SubscriptionRequiredError,
    RateLimitedError,
    StreamCapacityExceededError,
]

# Sanity-check at import time: all listed errors must be non-fallback.
for _err_cls in _NON_FALLBACK_ERROR_TYPES:
    assert _err_cls.failure_class not in FALLBACK_ELIGIBLE, (
        f"{_err_cls.__name__}.failure_class={_err_cls.failure_class!r} "
        f"is in FALLBACK_ELIGIBLE — it should be non-fallback"
    )


class _CountingFakeAdapter(FakeAdapter):
    """FakeAdapter that counts how many times each operation is called."""

    def __init__(self, _mode: str, **kwargs) -> None:
        super().__init__(_mode=_mode, **kwargs)
        self.call_count: int = 0

    async def list_devices(self) -> dict:
        self.call_count += 1
        return await super().list_devices()

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        self.call_count += 1
        return await super().list_events(device_id, limit)

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        self.call_count += 1
        return await super().download_snapshot(device_id)

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        self.call_count += 1
        return await super().download_video(device_id, event_id)

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        self.call_count += 1
        return await super().create_stream_session(device_id, sdp_offer)


_non_fallback_error_st = st.sampled_from(_NON_FALLBACK_ERROR_TYPES)

# Number of additional adapters after the first (1–2 fallback adapters)
_extra_adapter_count_st = st.integers(min_value=1, max_value=2)

# Operations that go through _route_operation (not delete_stream_session which
# uses direct dispatch, and not download_snapshot which has cache-first logic).
_ROUTED_OPERATIONS = ["list_devices", "list_events", "download_video", "create_stream_session"]
_operation_st = st.sampled_from(_ROUTED_OPERATIONS)


async def _invoke_router_operation(router: SourceRouter, operation: str) -> SourceResult:
    """Dispatch the named operation on the router with dummy arguments."""
    if operation == "list_devices":
        return await router.list_devices()
    elif operation == "list_events":
        return await router.list_events(device_id="device-1", limit=10)
    elif operation == "download_video":
        return await router.download_video(device_id="device-1", event_id=None)
    elif operation == "create_stream_session":
        return await router.create_stream_session(device_id="device-1", sdp_offer="v=0\r\n")
    else:
        raise ValueError(f"Unknown operation: {operation!r}")


@settings(max_examples=300)
@given(
    error_cls=_non_fallback_error_st,
    extra_count=_extra_adapter_count_st,
    operation=_operation_st,
)
def test_non_fallback_error_stops_routing_immediately(
    error_cls: type,
    extra_count: int,
    operation: str,
) -> None:
    """Property 3: Non-Fallback Stops Routing.

    When the first adapter in the profile raises a non-fallback error,
    the router must return immediately without calling any subsequent adapter.

    **Validates: Requirements 1.6**
    """
    # First adapter raises a non-fallback error
    first = _CountingFakeAdapter(
        _mode="primary",
        should_succeed=False,
        non_fallback_error=error_cls("injected non-fallback failure"),
    )
    # Subsequent adapters succeed — they must never be called
    rest = [
        _CountingFakeAdapter(_mode=f"fallback_{i}", should_succeed=True) for i in range(extra_count)
    ]

    router = SourceRouter(
        routing_profile=[first, *rest],
        health_manager=HealthManager(quarantine_threshold=1000, quarantine_seconds=3600),
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )

    result: SourceResult = asyncio.run(
        _invoke_router_operation(router, operation)
    )

    # The first adapter must have been called exactly once
    assert first.call_count == 1, (
        f"Expected first adapter to be called exactly once, got {first.call_count} "
        f"(error_cls={error_cls.__name__}, operation={operation!r})"
    )

    # No subsequent adapter should have been called
    for i, fallback in enumerate(rest):
        assert fallback.call_count == 0, (
            f"Fallback adapter {i} was called {fallback.call_count} time(s) "
            f"after non-fallback error {error_cls.__name__!r} on operation {operation!r}. "
            f"Non-fallback errors must stop routing immediately."
        )

    # The result must carry the error (payload is None)
    assert result.payload is None, (
        f"Expected payload=None for non-fallback failure, got {result.payload!r} "
        f"(error_cls={error_cls.__name__}, operation={operation!r})"
    )
    assert result.error is not None, (
        f"Expected error to be set in SourceResult for non-fallback failure "
        f"(error_cls={error_cls.__name__}, operation={operation!r})"
    )
    assert isinstance(result.error, error_cls), (
        f"Expected error to be instance of {error_cls.__name__}, "
        f"got {type(result.error).__name__!r} (operation={operation!r})"
    )

    # The failure_class of the returned error must be non-fallback
    assert result.error.failure_class not in FALLBACK_ELIGIBLE, (
        f"Returned error has fallback-eligible failure_class={result.error.failure_class!r}, "
        f"but it should be non-fallback (error_cls={error_cls.__name__})"
    )

    # source_mode must be the mode of the first (failing) adapter
    assert result.source_mode == "primary", (
        f"Expected source_mode='primary', got {result.source_mode!r} "
        f"(error_cls={error_cls.__name__}, operation={operation!r})"
    )


# ===========================================================================
# Property 8: Cache-First Snapshot Path
# Validates: Requirements 6.2, 13.3
# ===========================================================================

# Strategies for Property 8
_p8_device_id_st = st.text(
    min_size=1,
    max_size=64,
    alphabet=st.characters(
        whitelist_categories=("Lu", "Ll", "Nd"),
        whitelist_characters="-_",
    ),
)
_p8_snapshot_content_st = st.binary(min_size=1, max_size=4096)


@given(
    device_id=_p8_device_id_st,
    content=_p8_snapshot_content_st,
)
@settings(max_examples=200)
def test_fresh_cache_hit_skips_all_adapters(device_id: str, content: bytes) -> None:
    """**Validates: Requirements 6.2, 13.3**

    Property 8a: Cache-First Snapshot Path

    When the SnapshotCache contains a fresh entry for device_id, the
    SourceRouter MUST return the cached bytes without invoking any adapter.

    Verified properties:
    - No adapter in the profile has its download_snapshot called.
    - SourceResult.payload contains the cached bytes.
    - SourceResult.cache_age_seconds is None (fresh hit has no age header).
    """
    fake = FakeAdapter(_mode="unofficial", should_succeed=True)
    cache = SnapshotCache(
        max_bytes=10_000_000,
        ttl_fresh_seconds=60,
        ttl_stale_serve_seconds=600,
    )
    router = _make_router_with_cache([fake], cache)

    base_time = 1_000_000.0

    with patch("app.routing.snapshot_cache.time.time") as mock_time:
        # Pre-populate the cache with a fresh entry at base_time.
        mock_time.return_value = base_time
        cache.put(
            device_id=device_id,
            content=content,
            content_type="image/jpeg",
            source_mode="unofficial",
        )

        # Call download_snapshot while the entry is still fresh (age = 0s).
        mock_time.return_value = base_time  # no time has passed

        result: SourceResult = asyncio.run(router.download_snapshot(device_id))

    # 1. No adapter was called.
    assert fake.download_snapshot_calls == [], (
        f"Expected no adapter calls, but got: {fake.download_snapshot_calls}"
    )

    # 2. Returned payload contains the cached bytes.
    assert isinstance(result.payload, SnapshotPayload), (
        f"Expected SnapshotPayload, got {type(result.payload)}"
    )
    assert result.payload.content == content, (
        f"Payload bytes mismatch: expected {content!r}, got {result.payload.content!r}"
    )

    # 3. cache_age_seconds is None for a fresh hit (no X-Ring-Snapshot-Age header).
    assert result.cache_age_seconds is None, (
        f"Expected cache_age_seconds=None for fresh hit, got {result.cache_age_seconds}"
    )


@given(
    device_id=_p8_device_id_st,
    content=_p8_snapshot_content_st,
    num_adapters=st.integers(min_value=1, max_value=3),
)
@settings(max_examples=100)
def test_fresh_cache_hit_skips_all_adapters_in_profile(
    device_id: str, content: bytes, num_adapters: int
) -> None:
    """**Validates: Requirements 6.2, 13.3**

    Property 8b: A fresh cache hit skips ALL adapters in the routing profile,
    regardless of how many are configured.
    """
    adapters = [FakeAdapter(_mode=f"fake-{i}", should_succeed=True) for i in range(num_adapters)]
    cache = SnapshotCache(
        max_bytes=10_000_000,
        ttl_fresh_seconds=60,
        ttl_stale_serve_seconds=600,
    )
    router = _make_router_with_cache(adapters, cache)

    base_time = 2_000_000.0

    with patch("app.routing.snapshot_cache.time.time") as mock_time:
        mock_time.return_value = base_time
        cache.put(
            device_id=device_id,
            content=content,
            content_type="image/jpeg",
            source_mode="unofficial",
        )

        # Still fresh — no time elapsed.
        mock_time.return_value = base_time

        result: SourceResult = asyncio.run(router.download_snapshot(device_id))

    # Every adapter in the profile must have been skipped.
    for adapter in adapters:
        assert adapter.download_snapshot_calls == [], (
            f"Adapter {adapter.mode()!r} was called despite a fresh cache entry"
        )

    assert isinstance(result.payload, SnapshotPayload)
    assert result.payload.content == content
    assert result.cache_age_seconds is None


# ===========================================================================
# Property 2: Routing Determinism
#
# Tests that sources are attempted in strict profile order, skipping only
# quarantined ones. After a success, no further adapters are called. After
# all fallback-eligible failures, the last error is returned.
#
# **Validates: Requirements 1.4, 1.5, 1.11**
# ===========================================================================

# ---------------------------------------------------------------------------
# FakeAdapterWithOutcomes — records calls and returns configurable outcomes
# ---------------------------------------------------------------------------

# Fallback-eligible error classes for the non-snapshot path
_FALLBACK_ERROR_CLASSES: list[type[RingAdapterError]] = [
    UpstreamUnavailableError,
]

_SUCCESS = "success"


class FakeAdapterWithOutcomes(RingAdapter):
    """Configurable test double for RingAdapter.

    Takes a mode name and a list of outcomes (``"success"`` or a
    ``RingAdapterError`` subclass). Each call to any operation consumes the
    next outcome from the list. Records which operations were called and in
    what order.
    """

    def __init__(self, mode_name: str, outcomes: list) -> None:
        self._mode_name = mode_name
        self._outcomes = list(outcomes)
        self._outcome_index = 0
        self.calls: list[str] = []  # operation names in call order

    def mode(self) -> str:
        return self._mode_name

    def _next_outcome(self, operation: str) -> None:
        """Record the call and raise if the next outcome is an error."""
        self.calls.append(operation)
        if self._outcome_index >= len(self._outcomes):
            return  # default to success if outcomes exhausted
        outcome = self._outcomes[self._outcome_index]
        self._outcome_index += 1
        if outcome != _SUCCESS:
            raise outcome()

    async def list_devices(self) -> dict:
        self._next_outcome("list_devices")
        return {"data": []}

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        self._next_outcome("list_events")
        return []

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        self._next_outcome("download_snapshot")
        return SnapshotPayload(content=b"fake", content_type="image/jpeg")

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        self._next_outcome("download_video")
        return {"url": "https://example.com/video.mp4"}

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        self._next_outcome("create_stream_session")
        return StreamSessionResult(
            sdp_answer="v=0\r\n",
            location=f"/mock/session/fake-{self._mode_name}",
            session_id=f"fake-{self._mode_name}",
        )

    async def delete_stream_session(self, session_id: str) -> None:
        self._next_outcome("delete_stream_session")


# ---------------------------------------------------------------------------
# Helpers for Property 2 tests
# ---------------------------------------------------------------------------


def _run_p2(coro) -> SourceResult:
    """Run an async coroutine synchronously using asyncio.run() (Python 3.12 compatible)."""
    return asyncio.run(coro)


def _make_router_p2(
    adapters: list[FakeAdapterWithOutcomes],
    quarantine_threshold: int = 100,
) -> SourceRouter:
    """Build a SourceRouter with a permissive HealthManager (no quarantine)."""
    return SourceRouter(
        routing_profile=adapters,  # type: ignore[arg-type]
        health_manager=HealthManager(
            quarantine_threshold=quarantine_threshold,
            quarantine_seconds=3600,
        ),
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )


def _make_router_p2_with_health(
    adapters: list[FakeAdapterWithOutcomes],
    health: HealthManager,
) -> SourceRouter:
    """Build a SourceRouter with a specific HealthManager."""
    return SourceRouter(
        routing_profile=adapters,  # type: ignore[arg-type]
        health_manager=health,
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )


# Outcome strategy: success or a fallback-eligible error class
_outcome_st = st.sampled_from([_SUCCESS] + _FALLBACK_ERROR_CLASSES)

# Profile modes: 1–3 distinct modes
_profile_modes_st = st.lists(
    st.sampled_from(["mock", "unofficial", "partner"]),
    min_size=1,
    max_size=3,
    unique=True,
)


# ---------------------------------------------------------------------------
# Property 2a: First adapter in profile is called first on success
#
# When the first adapter succeeds, only it should be called.
#
# Validates: Requirements 1.4
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(modes=_profile_modes_st)
def test_p2_first_adapter_called_on_success(modes: list[str]) -> None:
    """Property 2a: First adapter in profile is called first on success.

    **Validates: Requirements 1.4**
    """
    adapters = [FakeAdapterWithOutcomes(mode, [_SUCCESS]) for mode in modes]
    router = _make_router_p2(adapters)

    result = _run_p2(router.list_devices())

    # Only the first adapter should have been called
    assert adapters[0].calls == ["list_devices"], (
        f"Expected only first adapter ({modes[0]}) to be called, "
        f"but calls were: {[a.calls for a in adapters]}"
    )
    for i, adapter in enumerate(adapters[1:], start=1):
        assert adapter.calls == [], (
            f"Adapter {i} ({modes[i]}) should not have been called, but got calls: {adapter.calls}"
        )
    assert result.source_mode == modes[0]
    assert result.payload is not None


# ---------------------------------------------------------------------------
# Property 2b: Fallback proceeds in strict profile order
#
# After a fallback-eligible failure, the next adapter in profile order is tried.
#
# Validates: Requirements 1.4, 1.5
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(modes=_profile_modes_st)
def test_p2_fallback_proceeds_in_profile_order(modes: list[str]) -> None:
    """Property 2b: After fallback-eligible failure, next adapter in order is tried.

    **Validates: Requirements 1.4, 1.5**
    """
    if len(modes) < 2:
        return  # Need at least 2 adapters to test fallback

    # First adapter fails, second succeeds
    adapters = [
        FakeAdapterWithOutcomes(modes[0], [UpstreamUnavailableError]),
        *[FakeAdapterWithOutcomes(mode, [_SUCCESS]) for mode in modes[1:]],
    ]
    router = _make_router_p2(adapters)

    result = _run_p2(router.list_devices())

    assert adapters[0].calls == ["list_devices"], (
        f"Expected first adapter ({modes[0]}) to be called once, got: {adapters[0].calls}"
    )
    assert adapters[1].calls == ["list_devices"], (
        f"Expected second adapter ({modes[1]}) to be called once, got: {adapters[1].calls}"
    )
    for i, adapter in enumerate(adapters[2:], start=2):
        assert adapter.calls == [], (
            f"Adapter {i} ({modes[i]}) should not have been called after success, "
            f"got: {adapter.calls}"
        )
    assert result.source_mode == modes[1]
    assert result.payload is not None


# ---------------------------------------------------------------------------
# Property 2c: Quarantined adapters are skipped entirely
#
# An adapter that is quarantined must not be called at all.
#
# Validates: Requirements 1.4, 1.5
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(modes=_profile_modes_st)
def test_p2_quarantined_adapters_are_skipped(modes: list[str]) -> None:
    """Property 2c: Quarantined adapters are skipped entirely.

    **Validates: Requirements 1.4, 1.5**
    """
    if len(modes) < 2:
        return  # Need at least 2 adapters to test quarantine skip

    # Quarantine the first adapter by recording enough failures to hit threshold
    health = HealthManager(quarantine_threshold=1, quarantine_seconds=3600)
    health.record_failure(modes[0], "list_devices", FALLBACK_ELIGIBLE.__iter__().__next__())

    adapters = [FakeAdapterWithOutcomes(mode, [_SUCCESS]) for mode in modes]
    router = _make_router_p2_with_health(adapters, health)

    result = _run_p2(router.list_devices())

    # First adapter must NOT have been called (it's quarantined)
    assert adapters[0].calls == [], (
        f"Quarantined adapter ({modes[0]}) should not have been called, "
        f"but got calls: {adapters[0].calls}"
    )
    assert adapters[1].calls == ["list_devices"], (
        f"Expected second adapter ({modes[1]}) to be called, got: {adapters[1].calls}"
    )
    assert result.source_mode == modes[1]
    assert result.payload is not None


# ---------------------------------------------------------------------------
# Property 2d: After a success, no further adapters are called
#
# Once any adapter succeeds, the routing loop stops immediately.
#
# Validates: Requirements 1.4
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    modes=_profile_modes_st,
    n_failures=st.integers(min_value=0),
)
def test_p2_no_further_adapters_called_after_success(modes: list[str], n_failures: int) -> None:
    """Property 2d: After a success, no further adapters are called.

    **Validates: Requirements 1.4**
    """
    n_failures = n_failures % len(modes)  # clamp to [0, len(modes) - 1]

    adapters = []
    for i, mode in enumerate(modes):
        if i < n_failures:
            adapters.append(FakeAdapterWithOutcomes(mode, [UpstreamUnavailableError]))
        else:
            adapters.append(FakeAdapterWithOutcomes(mode, [_SUCCESS]))

    router = _make_router_p2(adapters)
    result = _run_p2(router.list_devices())

    # Adapters 0..n_failures should each have been called exactly once
    for i in range(n_failures + 1):
        assert adapters[i].calls == ["list_devices"], (
            f"Adapter {i} ({modes[i]}) should have been called exactly once, "
            f"got: {adapters[i].calls}"
        )
    # Adapters after the successful one must NOT have been called
    for i in range(n_failures + 1, len(modes)):
        assert adapters[i].calls == [], (
            f"Adapter {i} ({modes[i]}) should not have been called after success at "
            f"index {n_failures}, got: {adapters[i].calls}"
        )
    assert result.source_mode == modes[n_failures]
    assert result.payload is not None


# ---------------------------------------------------------------------------
# Property 2e: After all fallback-eligible failures, the last error is returned
#
# When every adapter fails with a fallback-eligible error, the SourceResult
# must carry the error from the last adapter attempted.
#
# Validates: Requirements 1.11
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(modes=_profile_modes_st)
def test_p2_last_error_returned_when_all_fail(modes: list[str]) -> None:
    """Property 2e: After all fallback-eligible failures, the last error is returned.

    **Validates: Requirements 1.11**
    """
    adapters = [FakeAdapterWithOutcomes(mode, [UpstreamUnavailableError]) for mode in modes]
    router = _make_router_p2(adapters)

    result = _run_p2(router.list_devices())

    # All adapters should have been called in order
    for i, adapter in enumerate(adapters):
        assert adapter.calls == ["list_devices"], (
            f"Adapter {i} ({modes[i]}) should have been called exactly once, got: {adapter.calls}"
        )

    assert result.payload is None, (
        f"Expected payload=None when all adapters fail, got: {result.payload}"
    )
    assert result.error is not None, "Expected error to be set when all adapters fail"
    assert isinstance(result.error, UpstreamUnavailableError), (
        f"Expected UpstreamUnavailableError, got: {type(result.error).__name__}"
    )
    # source_mode should be the last adapter's mode
    assert result.source_mode == modes[-1], (
        f"Expected source_mode={modes[-1]!r} (last adapter), got: {result.source_mode!r}"
    )


# ===========================================================================
# Property 16: Fallback Observability
#
# Tests that fallback routing decisions produce structured log records with
# "fallback" in the message, and that the record contains the source mode
# and operation name.
#
# **Validates: Requirements 13.6**
# ===========================================================================


class _CapturingHandler(logging.Handler):
    """In-process log handler that accumulates LogRecord objects.

    Used instead of pytest's ``caplog`` fixture because Hypothesis resets
    function-scoped fixtures only once per test function, not between
    generated examples.  This handler is created fresh inside each
    ``@given`` body so every example starts with an empty record list.
    """

    def __init__(self) -> None:
        super().__init__()
        self.records: list[logging.LogRecord] = []

    def emit(self, record: logging.LogRecord) -> None:
        self.records.append(record)


@contextmanager
def _capture_source_router_logs():
    """Context manager that captures INFO+ records from app.routing.source_router.

    Yields the _CapturingHandler so callers can inspect .records after the
    block exits.
    """
    handler = _CapturingHandler()
    handler.setLevel(logging.INFO)
    target_logger = logging.getLogger("app.routing.source_router")
    # Ensure the logger propagates at INFO level
    original_level = target_logger.level
    target_logger.setLevel(logging.INFO)
    target_logger.addHandler(handler)
    try:
        yield handler
    finally:
        target_logger.removeHandler(handler)
        target_logger.setLevel(original_level)


# ---------------------------------------------------------------------------
# Strategies for Property 16
# ---------------------------------------------------------------------------

# Operations routed through _route_operation (not delete_stream_session).
# We exclude create_stream_session here because it is a live-media operation
# subject to the "always show real data" guard: when mock is the first adapter
# and a real source is also in the profile, mock is skipped by the guard
# before it even gets a chance to fail, so no fallback log is emitted.
# The fallback observability property is about the logging mechanism itself,
# which is fully exercised by the non-live-media operations.
_p16_operations = ["list_devices", "list_events", "download_video"]
_p16_operation_st = st.sampled_from(_p16_operations)

# Distinct mode names for the profile adapters (2–3 so fallback is possible)
_p16_modes_st = st.lists(
    st.sampled_from(["partner", "unofficial", "mock"]),
    min_size=2,
    max_size=3,
    unique=True,
)


async def _invoke_p16_operation(router: SourceRouter, operation: str) -> SourceResult:
    """Dispatch the named operation on the router with dummy arguments."""
    if operation == "list_devices":
        return await router.list_devices()
    elif operation == "list_events":
        return await router.list_events(device_id="device-1", limit=10)
    elif operation == "download_video":
        return await router.download_video(device_id="device-1", event_id=None)
    elif operation == "create_stream_session":
        return await router.create_stream_session(device_id="device-1", sdp_offer="v=0\r\n")
    else:
        raise ValueError(f"Unknown operation: {operation!r}")


def _make_router_p16(adapters: list) -> SourceRouter:
    """Build a SourceRouter with a permissive HealthManager (no quarantine)."""
    return SourceRouter(
        routing_profile=adapters,
        health_manager=HealthManager(quarantine_threshold=100, quarantine_seconds=3600),
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )


# ---------------------------------------------------------------------------
# Property 16a: Fallback log record is emitted when fallback occurs
#
# When the first adapter fails with a fallback-eligible error and the second
# succeeds, the logger for source_router must emit a record whose message
# contains "fallback", the failing source's mode, and the operation name.
#
# Validates: Requirements 13.6
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    modes=_p16_modes_st,
    operation=_p16_operation_st,
)
def test_fallback_log_record_emitted_on_fallback(
    modes: list[str],
    operation: str,
) -> None:
    """**Validates: Requirements 13.6**

    Property 16a: Fallback Observability

    When the first adapter in the profile fails with a fallback-eligible error
    and routing falls back to the next adapter, the SourceRouter MUST emit a
    structured log record that:

    1. Contains the word "fallback" in the message.
    2. Contains the failing source's mode in the message.
    3. Contains the operation name in the message.
    """
    failing_mode = modes[0]
    adapters: list[RingAdapter] = [
        FakeAdapter(_mode=failing_mode, should_succeed=False),  # raises UpstreamUnavailableError
        *[FakeAdapter(_mode=m, should_succeed=True) for m in modes[1:]],
    ]
    router = _make_router_p16(adapters)

    with _capture_source_router_logs() as handler:
        result = asyncio.run(_invoke_p16_operation(router, operation))

    # The routing must have succeeded (second adapter is healthy)
    assert result.payload is not None, (
        f"Expected a successful result after fallback, got payload=None "
        f"(modes={modes!r}, operation={operation!r})"
    )

    # Find log records that are routing decision=fallback records
    fallback_records = [r for r in handler.records if "decision=fallback" in r.getMessage()]

    # 1. At least one fallback log record must have been emitted.
    assert len(fallback_records) >= 1, (
        f"Expected at least one log record containing 'decision=fallback', "
        f"but none were found. All records: {[r.getMessage() for r in handler.records]!r} "
        f"(modes={modes!r}, operation={operation!r})"
    )

    # 2. At least one fallback record must contain the failing source's mode.
    mode_in_record = any(failing_mode in r.getMessage() for r in fallback_records)
    assert mode_in_record, (
        f"No decision=fallback log record contains the failing source mode {failing_mode!r}. "
        f"Fallback records: {[r.getMessage() for r in fallback_records]!r} "
        f"(modes={modes!r}, operation={operation!r})"
    )

    # 3. At least one fallback record must contain the operation name.
    op_in_record = any(operation in r.getMessage() for r in fallback_records)
    assert op_in_record, (
        f"No decision=fallback log record contains the operation name {operation!r}. "
        f"Fallback records: {[r.getMessage() for r in fallback_records]!r} "
        f"(modes={modes!r}, operation={operation!r})"
    )


# ---------------------------------------------------------------------------
# Property 16b: No fallback log record when first adapter succeeds
#
# When the first adapter succeeds, no "fallback" log record should be emitted.
#
# Validates: Requirements 13.6 (contrapositive — no spurious fallback logs)
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    modes=_p16_modes_st,
    operation=_p16_operation_st,
)
def test_no_fallback_log_when_primary_succeeds(
    modes: list[str],
    operation: str,
) -> None:
    """**Validates: Requirements 13.6**

    Property 16b: No fallback log record when primary source succeeds.

    When the first adapter in the profile succeeds, the SourceRouter MUST NOT
    emit any log record containing "fallback" for that request.
    """
    adapters: list[RingAdapter] = [
        FakeAdapter(_mode=m, should_succeed=True) for m in modes
    ]
    router = _make_router_p16(adapters)

    with _capture_source_router_logs() as handler:
        result = asyncio.run(_invoke_p16_operation(router, operation))

    assert result.payload is not None, (
        f"Expected successful result when all adapters succeed "
        f"(modes={modes!r}, operation={operation!r})"
    )

    fallback_records = [r for r in handler.records if "decision=fallback" in r.getMessage()]
    assert len(fallback_records) == 0, (
        f"Expected no decision=fallback log records when primary succeeds, "
        f"but found: {[r.getMessage() for r in fallback_records]!r} "
        f"(modes={modes!r}, operation={operation!r})"
    )


# ---------------------------------------------------------------------------
# Property 16c: Fallback log count equals number of fallback-eligible failures
#
# For a profile of N adapters where the first K fail with fallback-eligible
# errors and adapter K+1 succeeds, exactly K fallback log records should be
# emitted.
#
# Validates: Requirements 13.6
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    modes=_p16_modes_st,
    data=st.data(),
)
def test_fallback_log_count_matches_fallback_failures(
    modes: list[str],
    data: st.DataObject,
) -> None:
    """**Validates: Requirements 13.6**

    Property 16c: Fallback log count matches number of fallback-eligible failures.

    For a profile where the first K adapters fail with fallback-eligible errors
    and adapter K+1 succeeds, exactly K "fallback" log records must be emitted.
    """
    if len(modes) < 2:
        return  # Need at least 2 adapters

    # Pick how many adapters fail before success (1 to len-1)
    n_failures = data.draw(st.integers(min_value=1, max_value=len(modes) - 1))

    adapters: list[RingAdapter] = []
    for i, m in enumerate(modes):
        if i < n_failures:
            adapters.append(FakeAdapter(_mode=m, should_succeed=False))
        else:
            adapters.append(FakeAdapter(_mode=m, should_succeed=True))

    router = _make_router_p16(adapters)

    with _capture_source_router_logs() as handler:
        result = asyncio.run(_invoke_p16_operation(router, "list_devices"))

    assert result.payload is not None, (
        f"Expected successful result (modes={modes!r}, n_failures={n_failures})"
    )

    fallback_records = [r for r in handler.records if "decision=fallback" in r.getMessage()]

    assert len(fallback_records) == n_failures, (
        f"Expected exactly {n_failures} decision=fallback log record(s), "
        f"got {len(fallback_records)}. "
        f"Records: {[r.getMessage() for r in fallback_records]!r} "
        f"(modes={modes!r}, n_failures={n_failures})"
    )


# ===========================================================================
# Properties 6 and 7: Session Lifecycle
#
# Feature: ring-adapter-live-media
# **Validates: Requirements 2.3, 2.4, 3.2, 3.3, 13.2**
# ===========================================================================

# ---------------------------------------------------------------------------
# Session-aware FakeAdapters
#
# The real adapters (partner, unofficial, mock) call session_map.bind() inside
# create_stream_session and session_map.remove() inside delete_stream_session.
# The base FakeAdapter does neither, so we need session-aware variants for
# these lifecycle properties.
# ---------------------------------------------------------------------------


def _make_session_for_mode(
    mode: str,
    session_id: str,
    device_id: str,
) -> BaseStreamSession:
    """Create the correct session type for the given adapter mode."""
    now = _time.time()
    if mode == "partner":
        return PartnerStreamSession(
            session_id=session_id,
            device_id=device_id,
            created_at=now,
        )
    elif mode == "unofficial":
        return UnofficialStreamSession(
            session_id=session_id,
            device_id=device_id,
            created_at=now,
        )
    else:
        return MockStreamSession(
            session_id=session_id,
            device_id=device_id,
            created_at=now,
        )


class _SessionBindingFakeAdapter(FakeAdapter):
    """FakeAdapter that binds a session to the map on create_stream_session.

    Mirrors the behaviour of the real adapters (partner, unofficial, mock):
    create_stream_session calls session_map.bind() before returning.
    Each call generates a unique session_id via uuid4 so multiple creates
    don't collide.
    """

    def __init__(self, _mode: str, session_map: StreamSessionMap, **kwargs) -> None:
        super().__init__(_mode=_mode, **kwargs)
        self._session_map = session_map

    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        # Generate a unique session_id for each call (avoids duplicate-bind errors)
        session_id = str(_uuid.uuid4())
        # Honour should_succeed / non_fallback_error from base class
        if self.non_fallback_error is not None:
            raise self.non_fallback_error
        if not self.should_succeed:
            raise UpstreamUnavailableError(f"{self._mode} unavailable")
        # Bind the correct session type for this adapter's mode
        session = _make_session_for_mode(self._mode, session_id, device_id)
        await self._session_map.bind(session)
        return StreamSessionResult(
            sdp_answer="v=0\r\n",
            location=f"/mock/session/{session_id}",
            session_id=session_id,
        )


class _SessionCleanupFakeAdapter(_SessionBindingFakeAdapter):
    """FakeAdapter that removes a session from the map on delete_stream_session.

    Mirrors the real adapters' finally-block removal: the session is removed
    from the map regardless of whether the upstream DELETE succeeds or fails.

    Attributes:
        delete_should_fail: If True, delete_stream_session raises
            UpstreamUnavailableError *after* removing from the map (simulating
            a failed upstream teardown that still cleans up locally).
    """

    def __init__(
        self,
        _mode: str,
        session_map: StreamSessionMap,
        delete_should_fail: bool = False,
        **kwargs,
    ) -> None:
        super().__init__(_mode=_mode, session_map=session_map, **kwargs)
        self.delete_should_fail = delete_should_fail
        self._cleanup_session_map = session_map  # explicit reference for delete

    async def delete_stream_session(self, session_id: str) -> None:
        try:
            if self.delete_should_fail:
                raise UpstreamUnavailableError(f"{self._mode} delete failed upstream")
        finally:
            # Always remove from map — mirrors real adapter finally-block behaviour
            await self._cleanup_session_map.remove(session_id)


# ---------------------------------------------------------------------------
# Strategies for Properties 6 and 7
# ---------------------------------------------------------------------------

# Device IDs: short non-empty alphanumeric strings
_session_device_id_st = st.text(
    alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd"), whitelist_characters="-_"),
    min_size=1,
    max_size=32,
)

# SDP offers: short printable strings (content doesn't matter for routing)
_sdp_offer_st = st.text(
    alphabet=st.characters(whitelist_categories=("Lu", "Ll", "Nd"), whitelist_characters=" =\r\n"),
    min_size=0,
    max_size=64,
)


def _make_router_with_session_map(
    adapters: list[RingAdapter],
    session_map: StreamSessionMap,
) -> SourceRouter:
    """Build a SourceRouter wired to a caller-supplied StreamSessionMap."""
    return SourceRouter(
        routing_profile=adapters,
        health_manager=HealthManager(quarantine_threshold=100, quarantine_seconds=3600),
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,
            ttl_stale_serve_seconds=0,
        ),
        session_map=session_map,
    )


# ===========================================================================
# Property 6: Session Binding Invariant
#
# After create_stream_session succeeds, the StreamSessionMap must contain
# exactly one entry with the correct source_mode and device_id.
#
# **Validates: Requirements 2.3, 3.2, 13.2**
# ===========================================================================


@settings(max_examples=200)
@given(
    device_id=_session_device_id_st,
    sdp_offer=_sdp_offer_st,
    mode=st.sampled_from(VALID_MODES),
)
def test_p6_create_binds_exactly_one_entry(
    device_id: str,
    sdp_offer: str,
    mode: str,
) -> None:
    """**Validates: Requirements 2.3, 3.2, 13.2**

    Property 6: Session Binding Invariant

    After create_stream_session succeeds, the StreamSessionMap must contain
    exactly one entry. That entry must have:
    - source_mode matching the adapter's mode()
    - device_id matching the requested device_id
    """
    session_map = StreamSessionMap()
    adapter = _SessionBindingFakeAdapter(_mode=mode, session_map=session_map, should_succeed=True)
    router = _make_router_with_session_map([adapter], session_map)

    result = asyncio.run(router.create_stream_session(device_id, sdp_offer))

    # 1. Exactly one entry in the map after creation
    count = asyncio.run(session_map.count())
    assert count == 1, (
        f"Expected exactly 1 session in map after create_stream_session, "
        f"got {count} (mode={mode!r}, device_id={device_id!r})"
    )

    # 2. The entry has the correct source_mode
    assert result.source_mode == mode, (
        f"Expected source_mode={mode!r}, got {result.source_mode!r}"
    )

    # 3. The entry has the correct device_id
    sessions = asyncio.run(session_map.snapshot())
    assert len(sessions) == 1
    bound_session = sessions[0]
    assert bound_session.device_id == device_id, (
        f"Expected bound session device_id={device_id!r}, "
        f"got {bound_session.device_id!r}"
    )
    assert bound_session.source_mode == mode, (
        f"Expected bound session source_mode={mode!r}, "
        f"got {bound_session.source_mode!r}"
    )


@settings(max_examples=200)
@given(
    device_id=_session_device_id_st,
    sdp_offer=_sdp_offer_st,
    mode=st.sampled_from(VALID_MODES),
    n_creates=st.integers(min_value=2, max_value=5),
)
def test_p6_each_create_binds_exactly_one_new_entry(
    device_id: str,
    sdp_offer: str,
    mode: str,
    n_creates: int,
) -> None:
    """**Validates: Requirements 2.3, 3.2, 13.2**

    Property 6b: Each create_stream_session call binds exactly one new entry.

    After N successful create_stream_session calls, the map must contain
    exactly N entries (one per call, no duplicates, no missing entries).
    """
    session_map = StreamSessionMap()
    adapter = _SessionBindingFakeAdapter(_mode=mode, session_map=session_map, should_succeed=True)
    router = _make_router_with_session_map([adapter], session_map)

    async def _run_creates() -> None:
        for _ in range(n_creates):
            await router.create_stream_session(device_id, sdp_offer)

    asyncio.run(_run_creates())

    count = asyncio.run(session_map.count())
    assert count == n_creates, (
        f"Expected {n_creates} sessions in map after {n_creates} creates, "
        f"got {count} (mode={mode!r})"
    )


# ===========================================================================
# Property 7: Session Cleanup Invariant
#
# After delete_stream_session, the StreamSessionMap must have 0 entries,
# regardless of whether the upstream DELETE succeeded or failed.
#
# **Validates: Requirements 2.4, 3.3**
# ===========================================================================


@settings(max_examples=200)
@given(
    device_id=_session_device_id_st,
    sdp_offer=_sdp_offer_st,
    mode=st.sampled_from(VALID_MODES),
)
def test_p7_delete_removes_entry_on_upstream_success(
    device_id: str,
    sdp_offer: str,
    mode: str,
) -> None:
    """**Validates: Requirements 2.4, 3.3**

    Property 7a: Session Cleanup Invariant (upstream success)

    After delete_stream_session completes successfully, the StreamSessionMap
    must contain 0 entries.
    """
    session_map = StreamSessionMap()
    adapter = _SessionCleanupFakeAdapter(
        _mode=mode,
        session_map=session_map,
        should_succeed=True,
        delete_should_fail=False,
    )
    router = _make_router_with_session_map([adapter], session_map)

    async def _run() -> None:
        result = await router.create_stream_session(device_id, sdp_offer)
        session_id = result.payload.session_id  # type: ignore[union-attr]
        await router.delete_stream_session(session_id)

    asyncio.run(_run())

    count = asyncio.run(session_map.count())
    assert count == 0, (
        f"Expected 0 sessions in map after delete_stream_session (upstream success), "
        f"got {count} (mode={mode!r}, device_id={device_id!r})"
    )


@settings(max_examples=200)
@given(
    device_id=_session_device_id_st,
    sdp_offer=_sdp_offer_st,
    mode=st.sampled_from(VALID_MODES),
)
def test_p7_delete_removes_entry_on_upstream_failure(
    device_id: str,
    sdp_offer: str,
    mode: str,
) -> None:
    """**Validates: Requirements 2.4, 3.3**

    Property 7b: Session Cleanup Invariant (upstream failure)

    Even when the upstream DELETE fails (raises UpstreamUnavailableError),
    the session must be removed from the StreamSessionMap. The map must
    contain 0 entries after the call.

    This mirrors the real adapters' finally-block removal pattern.
    """
    session_map = StreamSessionMap()
    adapter = _SessionCleanupFakeAdapter(
        _mode=mode,
        session_map=session_map,
        should_succeed=True,
        delete_should_fail=True,  # upstream DELETE fails
    )
    router = _make_router_with_session_map([adapter], session_map)

    async def _run() -> None:
        result = await router.create_stream_session(device_id, sdp_offer)
        session_id = result.payload.session_id  # type: ignore[union-attr]
        # delete_stream_session propagates the upstream error — that's expected.
        # The important invariant is that the map is empty afterwards.
        with suppress(UpstreamUnavailableError):
            await router.delete_stream_session(session_id)

    asyncio.run(_run())

    count = asyncio.run(session_map.count())
    assert count == 0, (
        f"Expected 0 sessions in map after delete_stream_session (upstream failure), "
        f"got {count} (mode={mode!r}, device_id={device_id!r})"
    )
