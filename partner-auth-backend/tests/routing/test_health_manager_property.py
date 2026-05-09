"""Property-based tests for HealthManager quarantine lifecycle.

**Validates: Requirements 8.3, 8.4**

Property 12: Quarantine Lifecycle
- Quarantined sources are skipped (is_down() returns True) during the window.
- After the quarantine window elapses, is_down() returns False and state is restored to "up".
"""

from __future__ import annotations

from unittest.mock import patch

from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.failure_class import FailureClass
from app.routing.health_manager import HealthManager

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_FALLBACK_FC = FailureClass.UPSTREAM_UNAVAILABLE


def _quarantine(hm: HealthManager, source: str, op: str) -> None:
    """Drive the HealthManager to quarantine state by recording threshold failures."""
    for _ in range(hm._threshold):
        hm.record_failure(source, op, _FALLBACK_FC)


# ---------------------------------------------------------------------------
# Property 12a: Quarantined source is skipped during the window
#
# For any quarantine_seconds in [1, 300] and any time_elapsed in
# [0, quarantine_seconds - 1], is_down() must return True while the
# quarantine window has not yet elapsed.
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    quarantine_seconds=st.integers(min_value=1, max_value=300),
    time_elapsed=st.integers(min_value=0).flatmap(
        lambda _: st.integers(min_value=0, max_value=299)
    ),
)
def test_quarantine_window_source_is_down(quarantine_seconds: int, time_elapsed: int) -> None:
    """**Validates: Requirements 8.3**

    While time_elapsed < quarantine_seconds, is_down() must return True.
    """
    # Constrain time_elapsed to be strictly less than quarantine_seconds
    # (re-draw via assume would work too, but flatmap keeps shrinking clean)
    if time_elapsed >= quarantine_seconds:
        time_elapsed = quarantine_seconds - 1

    hm = HealthManager(quarantine_threshold=3, quarantine_seconds=quarantine_seconds)
    source, op = "unofficial", "download_snapshot"

    base_time = 1_000_000.0  # arbitrary epoch offset

    with patch("app.routing.health_manager.time.time") as mock_time:
        # Record failures at base_time to trigger quarantine
        mock_time.return_value = base_time
        _quarantine(hm, source, op)

        # Advance time to within the quarantine window
        mock_time.return_value = base_time + time_elapsed

        assert hm.is_down(source, op) is True, (
            f"Expected source to be quarantined at elapsed={time_elapsed}s "
            f"(window={quarantine_seconds}s)"
        )


# ---------------------------------------------------------------------------
# Property 12b: Quarantine expires and state is restored to "up"
#
# For any quarantine_seconds in [1, 300], after advancing time by
# quarantine_seconds or more, is_down() must return False and the
# internal state must be "up".
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    quarantine_seconds=st.integers(min_value=1, max_value=300),
    extra_seconds=st.integers(min_value=0, max_value=300),
)
def test_quarantine_expiry_restores_state(quarantine_seconds: int, extra_seconds: int) -> None:
    """**Validates: Requirements 8.4**

    After quarantine_seconds (or more) have elapsed, is_down() must return
    False and the HealthState must be restored to "up" with counter reset.
    """
    hm = HealthManager(quarantine_threshold=3, quarantine_seconds=quarantine_seconds)
    source, op = "unofficial", "download_snapshot"

    base_time = 1_000_000.0

    with patch("app.routing.health_manager.time.time") as mock_time:
        # Trigger quarantine at base_time
        mock_time.return_value = base_time
        _quarantine(hm, source, op)

        # Advance time to exactly quarantine_seconds + extra_seconds
        elapsed = quarantine_seconds + extra_seconds
        mock_time.return_value = base_time + elapsed

        result = hm.is_down(source, op)

        assert result is False, (
            f"Expected source to be restored after elapsed={elapsed}s "
            f"(window={quarantine_seconds}s)"
        )

        # Verify internal state was actually reset
        hs = hm._states.get((source, op))
        assert hs is not None
        assert hs.state == "up", f"Expected state='up', got state='{hs.state}'"
        assert hs.consecutive_failures == 0, (
            f"Expected consecutive_failures=0, got {hs.consecutive_failures}"
        )
        assert hs.quarantine_start is None, (
            f"Expected quarantine_start=None, got {hs.quarantine_start}"
        )
