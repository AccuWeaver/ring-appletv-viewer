"""Property 5: Rate limit governor enforces rolling window.

For any ``max_per_minute`` and any ``acquire()`` schedule, the governor allows
at most ``max_per_minute`` successful acquisitions in any rolling 60 s window;
contended requests either drain within ``queue_wait_seconds`` or raise
``RateLimitedError``.

Real 60-second windows are impractical in CI. The tests subclass
``RateLimitGovernor`` with a compressed ``WINDOW_SECONDS`` (0.2 s) so the
rolling-window semantics are exercised end-to-end in sub-second wall time.

Validates: Requirements 8.1, 8.2.
"""

from __future__ import annotations

import asyncio

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from app.adapters.errors import RateLimitedError
from app.adapters.rate_limit import RateLimitGovernor


class _FastGovernor(RateLimitGovernor):
    """Governor with a compressed 200 ms rolling window for tests.

    The production ``WINDOW_SECONDS`` is 60 s; compressing it to 0.2 s lets
    us exercise the rolling-window semantics end-to-end in sub-second wall
    time while keeping the governor code under test completely unchanged.
    """

    WINDOW_SECONDS = 0.2


# ---------------------------------------------------------------------------
# Invariant 1 (Property 5 core): successful acquires never exceed
# ``max_per_minute`` inside a window.
# ---------------------------------------------------------------------------


@settings(
    max_examples=30,
    deadline=None,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(
    max_per_minute=st.integers(min_value=1, max_value=20),
    burst=st.integers(min_value=0, max_value=25),
)
def test_governor_admits_at_most_max_per_minute_per_window(max_per_minute: int, burst: int) -> None:
    """**Validates: Requirements 8.1, 8.2**

    Fire ``burst`` back-to-back ``acquire()`` calls against a governor with
    ``queue_wait_seconds=0``. Every admission increments ``admitted``; every
    over-capacity call raises ``RateLimitedError``. The post-condition is
    the rolling-window ceiling: admitted must not exceed ``max_per_minute``.
    """

    async def run() -> None:
        g = _FastGovernor(
            max_per_minute=max_per_minute,
            queue_wait_seconds=0.0,  # fail-fast once capacity is exhausted
        )
        admitted = 0
        for _ in range(burst):
            try:
                await g.acquire()
                admitted += 1
            except RateLimitedError:
                pass

        # Core invariant of Property 5.
        assert admitted <= max_per_minute
        # The burst finishes inside a single window (no sleeps between
        # acquires), so the governor's internal counter must match the
        # number of admissions exactly.
        assert await g.current_rate() == admitted

    asyncio.run(run())


# ---------------------------------------------------------------------------
# Invariant 2: a drained window refills as old events expire.
# ---------------------------------------------------------------------------


async def test_governor_window_drains_after_expiry() -> None:
    """After the compressed window elapses, ``current_rate`` decays to zero
    and a fresh burst at the configured cap is admitted again.
    """
    g = _FastGovernor(max_per_minute=3, queue_wait_seconds=0.0)
    for _ in range(3):
        await g.acquire()
    with pytest.raises(RateLimitedError):
        await g.acquire()

    # Wait out the compressed window (0.2 s + slack for scheduler jitter).
    await asyncio.sleep(0.3)

    # Current rate has decayed to zero.
    assert await g.current_rate() == 0
    # A fresh burst at the cap is admitted again.
    for _ in range(3):
        await g.acquire()


# ---------------------------------------------------------------------------
# Invariant 3: queue_wait_seconds causes contended callers to wait and
# succeed when capacity frees up within the deadline.
# ---------------------------------------------------------------------------


async def test_governor_queues_and_admits_when_capacity_returns_in_time() -> None:
    """A contended acquire waits until the window rolls forward and then
    succeeds, without consuming the full ``queue_wait_seconds`` budget.
    """
    g = _FastGovernor(max_per_minute=2, queue_wait_seconds=1.0)
    await g.acquire()
    await g.acquire()

    # The third caller must queue. It cannot be admitted until the oldest
    # event exits the 0.2 s compressed window — well within the 1.0 s wait
    # budget.
    loop = asyncio.get_running_loop()
    t_start = loop.time()
    await g.acquire()
    t_waited = loop.time() - t_start

    # Waited at least as long as the compressed window (with a small
    # tolerance for scheduler wakeup jitter).
    assert t_waited >= 0.15, f"expected a real wait, got {t_waited:.3f}s"
    # But did not burn the full budget — capacity genuinely returned.
    assert t_waited <= 0.8, f"expected admission well before budget, got {t_waited:.3f}s"


# ---------------------------------------------------------------------------
# Invariant 4: queue_wait_seconds=0 with full capacity fails immediately.
# ---------------------------------------------------------------------------


async def test_governor_raises_when_full_and_no_wait_budget() -> None:
    """With ``queue_wait_seconds=0`` a contended acquire surfaces
    ``RateLimitedError`` immediately rather than blocking.
    """
    g = _FastGovernor(max_per_minute=1, queue_wait_seconds=0.0)
    await g.acquire()
    with pytest.raises(RateLimitedError):
        await g.acquire()


# ---------------------------------------------------------------------------
# Construction-time validation.
# ---------------------------------------------------------------------------


def test_init_rejects_non_positive_max_per_minute() -> None:
    with pytest.raises(ValueError):
        RateLimitGovernor(max_per_minute=0, queue_wait_seconds=1.0)


def test_init_rejects_negative_queue_wait() -> None:
    with pytest.raises(ValueError):
        RateLimitGovernor(max_per_minute=1, queue_wait_seconds=-1.0)
