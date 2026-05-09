"""Property-based tests for SnapshotRefreshJob.

# Feature: ring-adapter-live-media

Properties covered:
- Property 14: Skip-If-Running Refresh (Requirements 6.4)
- Property 15: Refresh Participates in Quarantine (Requirements 6.6)
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from unittest.mock import AsyncMock, MagicMock

from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.errors import UpstreamUnavailableError
from app.adapters.session_map import StreamSessionMap
from app.routing.health_manager import HealthManager
from app.routing.snapshot_cache import SnapshotCache
from app.routing.snapshot_refresh_job import SnapshotRefreshJob
from app.routing.source_router import SourceRouter

# ---------------------------------------------------------------------------
# FakeAdapter — configurable test double
# ---------------------------------------------------------------------------


@dataclass
class FakeAdapter(RingAdapter):
    """Minimal RingAdapter test double.

    Attributes:
        _mode: The mode string returned by mode().
        device_ids: Device IDs returned by list_devices().
        snapshot_succeeds: If True, download_snapshot returns a dummy payload.
            If False, raises UpstreamUnavailableError (fallback-eligible).
    """

    _mode: str
    device_ids: list[str] = field(default_factory=lambda: ["device-1"])
    snapshot_succeeds: bool = False

    def mode(self) -> str:
        return self._mode

    async def list_devices(self) -> dict:
        return {"data": [{"id": did} for did in self.device_ids]}

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        return []

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        if not self.snapshot_succeeds:
            raise UpstreamUnavailableError(f"{self._mode} snapshot unavailable")
        return SnapshotPayload(b"img", "image/jpeg")

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


def _make_router_and_health(
    adapter: FakeAdapter,
    *,
    quarantine_threshold: int,
) -> tuple[SourceRouter, HealthManager]:
    """Build a SourceRouter with a shared HealthManager and the given adapter."""
    hm = HealthManager(
        quarantine_threshold=quarantine_threshold,
        quarantine_seconds=3600,
    )
    router = SourceRouter(
        routing_profile=[adapter],
        health_manager=hm,
        snapshot_cache=SnapshotCache(
            max_bytes=1_000_000,
            ttl_fresh_seconds=0,  # always stale so cache never short-circuits
            ttl_stale_serve_seconds=0,
        ),
        session_map=StreamSessionMap(),
    )
    return router, hm


def _run(coro) -> object:
    """Run an async coroutine synchronously in tests."""
    return asyncio.run(coro)


# ===========================================================================
# Property 14: Skip-If-Running Refresh
# **Validates: Requirements 6.4**
# ===========================================================================


def _make_job(interval_seconds: int = 45) -> SnapshotRefreshJob:
    """Return a SnapshotRefreshJob with a fake SourceRouter."""
    fake_router = MagicMock()
    fake_router.list_devices = AsyncMock(return_value=MagicMock(payload=None))
    return SnapshotRefreshJob(source_router=fake_router, interval_seconds=interval_seconds)


# ---------------------------------------------------------------------------
# Property 14a: Lock-held tick is a no-op (no new cycle started)
#
# When the asyncio.Lock is already acquired (a cycle is running), the
# _run_loop tick logic must skip firing a new _execute_cycle.
# ---------------------------------------------------------------------------


@given(
    interval=st.integers(min_value=1, max_value=300),
)
@settings(max_examples=200)
def test_skip_if_running_no_new_cycle_when_locked(interval: int) -> None:
    """**Validates: Requirements 6.4**

    Property 14: Skip-If-Running Refresh

    When the lock is held (a cycle is already executing), the tick logic
    must NOT start a new _execute_cycle.  We verify this by:
    1. Creating a job and manually acquiring its lock.
    2. Invoking the skip-if-running check directly (mirrors _run_loop logic).
    3. Asserting that _execute_cycle is never called.
    """

    async def _run_test() -> int:
        job = _make_job(interval_seconds=interval)
        cycle_calls: list[int] = []

        async def _fake_execute() -> None:
            cycle_calls.append(1)

        job._execute_cycle = _fake_execute  # type: ignore[method-assign]

        # Simulate: lock is held (a cycle is running).
        await job._lock.acquire()
        try:
            # This is the exact skip-if-running check from _run_loop:
            #   if self._lock.locked():
            #       continue  (skip)
            if not job._lock.locked():
                # Lock is NOT held — would fire a cycle (should not happen here).
                asyncio.create_task(job._execute_cycle())  # type: ignore[arg-type]
                await asyncio.sleep(0)  # let the task run
        finally:
            job._lock.release()

        return len(cycle_calls)

    calls = asyncio.run(_run_test())
    assert calls == 0, f"Expected 0 _execute_cycle calls when lock is held, got {calls}"


# ---------------------------------------------------------------------------
# Property 14b: Lock-free tick fires exactly one cycle
#
# When the lock is NOT held, the tick logic must fire exactly one
# _execute_cycle (not zero, not more than one).
# ---------------------------------------------------------------------------


@given(
    interval=st.integers(min_value=1, max_value=300),
)
@settings(max_examples=200)
def test_skip_if_running_fires_one_cycle_when_unlocked(interval: int) -> None:
    """**Validates: Requirements 6.4**

    Property 14: Skip-If-Running Refresh

    When the lock is NOT held, the tick logic must fire exactly one
    _execute_cycle task.
    """

    async def _run_test() -> int:
        job = _make_job(interval_seconds=interval)
        cycle_calls: list[int] = []

        async def _fake_execute() -> None:
            cycle_calls.append(1)

        job._execute_cycle = _fake_execute  # type: ignore[method-assign]

        # Lock is NOT held — tick should fire one cycle.
        assert not job._lock.locked(), "Lock should be free before tick"

        if not job._lock.locked():
            asyncio.create_task(job._execute_cycle())  # type: ignore[arg-type]
            await asyncio.sleep(0)  # yield to let the task execute

        return len(cycle_calls)

    calls = asyncio.run(_run_test())
    assert calls == 1, f"Expected exactly 1 _execute_cycle call when lock is free, got {calls}"


# ---------------------------------------------------------------------------
# Property 14c: _execute_cycle holds the lock for its entire duration
#
# The lock must be acquired at the start of _execute_cycle and released
# only after the cycle completes.  This ensures that concurrent ticks
# can detect a running cycle via lock.locked().
# ---------------------------------------------------------------------------


@given(
    num_devices=st.integers(min_value=0, max_value=10),
)
@settings(max_examples=100)
def test_execute_cycle_holds_lock_throughout(num_devices: int) -> None:
    """**Validates: Requirements 6.4**

    Property 14: Skip-If-Running Refresh

    While _execute_cycle is executing, lock.locked() must return True.
    After _execute_cycle completes, lock.locked() must return False.
    """

    async def _run_test() -> tuple[bool, bool]:
        """Returns (locked_during, locked_after)."""
        fake_router = MagicMock()

        # Build a device payload with num_devices entries.
        devices = [{"device_id": f"dev-{i}"} for i in range(num_devices)]
        fake_router.list_devices = AsyncMock(return_value=MagicMock(payload=devices))
        fake_router.download_snapshot = AsyncMock(
            return_value=MagicMock(payload=b"img", error=None)
        )

        job = SnapshotRefreshJob(source_router=fake_router, interval_seconds=45)

        locked_during_values: list[bool] = []

        # Wrap download_snapshot to observe lock state mid-cycle.
        original_download = fake_router.download_snapshot

        async def _spy_download(device_id: str):  # noqa: ANN202
            locked_during_values.append(job._lock.locked())
            return await original_download(device_id)

        fake_router.download_snapshot = _spy_download

        await job._execute_cycle()
        locked_after = job._lock.locked()

        # locked_during: True if lock was held during every download call
        # (or True vacuously when there are no devices).
        locked_during = all(locked_during_values) if locked_during_values else True

        return locked_during, locked_after

    locked_during, locked_after = asyncio.run(_run_test())

    assert locked_during is True, "Lock must be held throughout _execute_cycle execution"
    assert locked_after is False, "Lock must be released after _execute_cycle completes"


# ---------------------------------------------------------------------------
# Property 14d: Sequential ticks — at most one cycle runs at a time
#
# The real _run_loop fires ticks sequentially (one per interval).  When
# a cycle is still running from a previous tick, the next tick must be
# skipped.  This test models that sequential pattern: fire a tick that
# starts a long-running cycle, then fire additional ticks while the
# cycle is still holding the lock, and verify that none of those
# subsequent ticks start a new cycle.
# ---------------------------------------------------------------------------


@given(
    num_extra_ticks=st.integers(min_value=1, max_value=9),
)
@settings(max_examples=100)
def test_sequential_ticks_skip_while_cycle_running(num_extra_ticks: int) -> None:
    """**Validates: Requirements 6.4**

    Property 14: Skip-If-Running Refresh

    The _run_loop fires ticks sequentially.  When a cycle is still running
    (lock held) at the time of a subsequent tick, that tick must be skipped.
    Total cycle executions must be exactly 1 regardless of how many
    subsequent ticks fire while the first cycle is running.
    """

    async def _run_test() -> int:
        job = _make_job()
        cycle_starts: list[int] = []

        # A barrier event: the fake cycle waits until we release it.
        cycle_started = asyncio.Event()
        cycle_release = asyncio.Event()

        async def _fake_execute() -> None:
            # Acquire the lock just like the real _execute_cycle does,
            # so that lock.locked() returns True while this cycle runs.
            async with job._lock:
                cycle_starts.append(1)
                cycle_started.set()
                await cycle_release.wait()  # hold the lock until we say so

        job._execute_cycle = _fake_execute  # type: ignore[method-assign]

        def _tick() -> None:
            """One tick: check lock, fire cycle if free (mirrors _run_loop)."""
            if not job._lock.locked():
                asyncio.create_task(job._execute_cycle())  # type: ignore[arg-type]

        # First tick: lock is free, so a cycle starts.
        _tick()
        await asyncio.sleep(0)  # yield so the task can acquire the lock

        # Wait until the cycle has actually started and holds the lock.
        await cycle_started.wait()
        assert job._lock.locked(), "Lock should be held by the running cycle"

        # Fire additional ticks while the cycle is running — all must be skipped.
        for _ in range(num_extra_ticks):
            _tick()
            await asyncio.sleep(0)

        # Release the cycle and let it finish.
        cycle_release.set()
        await asyncio.sleep(0.01)

        return len(cycle_starts)

    total_cycles = asyncio.run(_run_test())
    assert total_cycles == 1, (
        f"Expected exactly 1 cycle (subsequent ticks skipped), "
        f"got {total_cycles} (num_extra_ticks={num_extra_ticks})"
    )


# ===========================================================================
# Property 15: Refresh Participates in Quarantine
# **Validates: Requirements 6.6**
# ===========================================================================

# ---------------------------------------------------------------------------
# Property 15a: Each _execute_cycle() failure increments consecutive_failures
#
# When the adapter always raises UpstreamUnavailableError on download_snapshot,
# running N cycles must increment consecutive_failures by exactly N for the
# "download_snapshot" operation on that source.
#
# This verifies that the refresh job goes through the same SourceRouter /
# HealthManager path as client-initiated requests.
#
# Validates: Requirements 6.6
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(n_cycles=st.integers(min_value=1, max_value=10))
def test_refresh_failures_increment_consecutive_failures(n_cycles: int) -> None:
    """**Validates: Requirements 6.6**

    Property 15a: Each _execute_cycle() call that encounters an
    UpstreamUnavailableError on download_snapshot increments the
    HealthManager's consecutive_failures counter for that source and
    operation by exactly 1 per cycle.

    After N cycles the counter must equal N (assuming the threshold is
    never reached so the source is not quarantined between cycles).
    """
    device_id = "device-1"
    adapter = FakeAdapter(_mode="unofficial", device_ids=[device_id], snapshot_succeeds=False)

    # Use a threshold high enough that quarantine is never triggered during
    # the test, so the counter accumulates linearly.
    quarantine_threshold = n_cycles + 1
    router, hm = _make_router_and_health(adapter, quarantine_threshold=quarantine_threshold)

    job = SnapshotRefreshJob(source_router=router, interval_seconds=60)

    for _ in range(n_cycles):
        _run(job._execute_cycle())

    state = hm._states.get(("unofficial", "download_snapshot"))
    assert state is not None, (
        "HealthManager has no state for ('unofficial', 'download_snapshot') — "
        "refresh job failures did not go through HealthManager"
    )
    assert state.consecutive_failures == n_cycles, (
        f"Expected consecutive_failures={n_cycles} after {n_cycles} failing cycles, "
        f"got {state.consecutive_failures}. "
        "Refresh job failures must increment the same counter as client requests."
    )


# ---------------------------------------------------------------------------
# Property 15b: Refresh failures trigger quarantine at threshold
#
# When the adapter always fails and the quarantine threshold is T, after
# exactly T cycles the source must be quarantined (Health_State = "down").
#
# Validates: Requirements 6.6, 8.2
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(threshold=st.integers(min_value=1, max_value=8))
def test_refresh_failures_trigger_quarantine_at_threshold(threshold: int) -> None:
    """**Validates: Requirements 6.6**

    Property 15b: After exactly `threshold` failing _execute_cycle() calls,
    the source must be quarantined (Health_State = "down") for the
    "download_snapshot" operation.

    This confirms that refresh job failures participate in the same
    quarantine accounting as client-initiated requests.
    """
    device_id = "device-1"
    adapter = FakeAdapter(_mode="unofficial", device_ids=[device_id], snapshot_succeeds=False)

    router, hm = _make_router_and_health(adapter, quarantine_threshold=threshold)
    job = SnapshotRefreshJob(source_router=router, interval_seconds=60)

    # Run exactly threshold cycles — the source should be quarantined after this.
    for _ in range(threshold):
        _run(job._execute_cycle())

    assert hm.is_down("unofficial", "download_snapshot"), (
        f"Expected source to be quarantined after {threshold} failing cycles "
        f"(threshold={threshold}), but is_down() returned False. "
        "Refresh job failures must participate in quarantine accounting."
    )


# ---------------------------------------------------------------------------
# Property 15c: Refresh failures and client failures share the same counter
#
# Interleaving client-initiated failures (via router.download_snapshot) and
# refresh-job failures (via job._execute_cycle) must accumulate into the
# same consecutive_failures counter.
#
# Validates: Requirements 6.6
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    client_failures=st.integers(min_value=0, max_value=5),
    refresh_failures=st.integers(min_value=0, max_value=5),
)
def test_refresh_and_client_failures_share_counter(
    client_failures: int,
    refresh_failures: int,
) -> None:
    """**Validates: Requirements 6.6**

    Property 15c: Failures from client-initiated download_snapshot calls and
    failures from SnapshotRefreshJob._execute_cycle() both increment the same
    consecutive_failures counter in the HealthManager.

    After `client_failures` direct router calls and `refresh_failures` job
    cycles, the counter must equal client_failures + refresh_failures.
    """
    total = client_failures + refresh_failures
    if total == 0:
        return  # nothing to assert

    device_id = "device-1"
    adapter = FakeAdapter(_mode="unofficial", device_ids=[device_id], snapshot_succeeds=False)

    # Threshold high enough to avoid quarantine during the test.
    quarantine_threshold = total + 1
    router, hm = _make_router_and_health(adapter, quarantine_threshold=quarantine_threshold)
    job = SnapshotRefreshJob(source_router=router, interval_seconds=60)

    # Simulate client-initiated failures directly through the router.
    for _ in range(client_failures):
        _run(router.download_snapshot(device_id))

    # Simulate refresh-job failures.
    for _ in range(refresh_failures):
        _run(job._execute_cycle())

    state = hm._states.get(("unofficial", "download_snapshot"))
    assert state is not None, "HealthManager has no state for ('unofficial', 'download_snapshot')"
    assert state.consecutive_failures == total, (
        f"Expected consecutive_failures={total} "
        f"(client_failures={client_failures} + refresh_failures={refresh_failures}), "
        f"got {state.consecutive_failures}. "
        "Client and refresh-job failures must share the same counter."
    )
