"""Property tests for the HealthManager state machine.

# Feature: ring-adapter-live-media, Property 11: Health State Machine Correctness

Tests that:
- consecutive_failures equals count since last success
- State transitions to "down" iff threshold reached
- Single success resets counter and marks state "up"
- record_failure() behaves identically for all FailureClass values
  (the HealthManager doesn't filter by class — that's the router's job)
"""

from __future__ import annotations

from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.failure_class import FailureClass
from app.routing.health_manager import HealthManager

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SOURCE_MODE = "unofficial"
OPERATION = "download_snapshot"

# All FailureClass values — used to verify that record_failure() behaves the
# same regardless of which class is passed.
ALL_FAILURE_CLASSES = list(FailureClass)


def _apply_events(
    hm: HealthManager,
    events: list[bool],
    fc: FailureClass = FailureClass.UPSTREAM_UNAVAILABLE,
) -> None:
    """Apply a sequence of events to the HealthManager.

    True  → record_success()
    False → record_failure()
    """
    for is_success in events:
        if is_success:
            hm.record_success(SOURCE_MODE, OPERATION)
        else:
            hm.record_failure(SOURCE_MODE, OPERATION, fc)


def _consecutive_failures_since_last_success(events: list[bool]) -> int:
    """Compute the expected consecutive_failures count from an event sequence.

    Scans from the end of the list backwards to count failures before the
    most recent success (or from the beginning if there was no success).
    """
    count = 0
    for is_success in reversed(events):
        if is_success:
            break
        count += 1
    return count


# ---------------------------------------------------------------------------
# Property 11a: consecutive_failures equals count since last success
#
# After any sequence of record_success() / record_failure() calls,
# consecutive_failures must equal the number of failures that occurred
# after the most recent success (or since the start if no success occurred).
#
# Validates: Requirements 8.1, 8.5
# ---------------------------------------------------------------------------


@settings(max_examples=500)
@given(events=st.lists(st.booleans(), max_size=20))
def test_consecutive_failures_equals_count_since_last_success(
    events: list[bool],
) -> None:
    """Property 11a: consecutive_failures equals count since last success.

    **Validates: Requirements 8.1, 8.5**
    """
    # Use a threshold high enough that we never hit quarantine during this test
    hm = HealthManager(quarantine_threshold=100, quarantine_seconds=60)
    _apply_events(hm, events)

    expected = _consecutive_failures_since_last_success(events)
    state = hm._states.get((SOURCE_MODE, OPERATION))

    if not events:
        # No events → no state entry created yet
        assert state is None or state.consecutive_failures == 0
    else:
        assert state is not None
        assert state.consecutive_failures == expected, (
            f"Expected consecutive_failures={expected} for events={events}, "
            f"got {state.consecutive_failures}"
        )


# ---------------------------------------------------------------------------
# Property 11b: state is "down" iff consecutive_failures >= threshold
#
# The state machine must transition to "down" exactly when the failure
# counter reaches the quarantine threshold, and remain "up" otherwise.
#
# Validates: Requirements 8.1, 8.2
# ---------------------------------------------------------------------------


@settings(max_examples=500)
@given(
    events=st.lists(st.booleans(), max_size=20),
    threshold=st.integers(min_value=1, max_value=10),
)
def test_state_is_down_iff_threshold_reached(
    events: list[bool],
    threshold: int,
) -> None:
    """Property 11b: state is "down" iff consecutive_failures >= threshold.

    **Validates: Requirements 8.1, 8.2**
    """
    hm = HealthManager(quarantine_threshold=threshold, quarantine_seconds=3600)
    _apply_events(hm, events)

    state = hm._states.get((SOURCE_MODE, OPERATION))
    consecutive = _consecutive_failures_since_last_success(events)

    if state is None:
        # No events applied — implicitly "up"
        assert consecutive == 0
        return

    if consecutive >= threshold:
        assert state.state == "down", (
            f"Expected state='down' when consecutive_failures={consecutive} >= "
            f"threshold={threshold}, got state={state.state!r} for events={events}"
        )
    else:
        assert state.state == "up", (
            f"Expected state='up' when consecutive_failures={consecutive} < "
            f"threshold={threshold}, got state={state.state!r} for events={events}"
        )


# ---------------------------------------------------------------------------
# Property 11c: single success resets counter and marks state "up"
#
# After any sequence of failures, a single record_success() call must reset
# consecutive_failures to 0 and set state to "up".
#
# Validates: Requirements 8.5
# ---------------------------------------------------------------------------


@settings(max_examples=500)
@given(
    failures_before=st.integers(min_value=0, max_value=15),
    threshold=st.integers(min_value=1, max_value=10),
)
def test_single_success_resets_counter_and_marks_up(
    failures_before: int,
    threshold: int,
) -> None:
    """Property 11c: single success resets counter and marks state "up".

    **Validates: Requirements 8.5**
    """
    hm = HealthManager(quarantine_threshold=threshold, quarantine_seconds=3600)

    # Apply some failures first (may or may not trigger quarantine)
    for _ in range(failures_before):
        hm.record_failure(SOURCE_MODE, OPERATION, FailureClass.UPSTREAM_UNAVAILABLE)

    # Now record a success
    hm.record_success(SOURCE_MODE, OPERATION)

    state = hm._states.get((SOURCE_MODE, OPERATION))
    assert state is not None
    assert state.consecutive_failures == 0, (
        f"Expected consecutive_failures=0 after success, got {state.consecutive_failures}"
    )
    assert state.state == "up", f"Expected state='up' after success, got {state.state!r}"
    assert state.last_success_at is not None, (
        "Expected last_success_at to be set after record_success()"
    )


# ---------------------------------------------------------------------------
# Property 11d: all FailureClass values behave identically in record_failure()
#
# The HealthManager does not filter by FailureClass — it increments the
# counter for every call to record_failure(), regardless of the class passed.
# The router is responsible for only calling record_failure() for
# fallback-eligible failures.
#
# Validates: Requirements 8.1, 8.6
# ---------------------------------------------------------------------------


@settings(max_examples=300)
@given(
    n_failures=st.integers(min_value=1, max_value=10),
    fc=st.sampled_from(ALL_FAILURE_CLASSES),
)
def test_all_failure_classes_increment_counter_identically(
    n_failures: int,
    fc: FailureClass,
) -> None:
    """Property 11d: all FailureClass values behave identically in record_failure().

    The HealthManager increments consecutive_failures for every call to
    record_failure(), regardless of the FailureClass passed.

    **Validates: Requirements 8.1, 8.6**
    """
    # Use a threshold high enough to avoid quarantine
    hm = HealthManager(quarantine_threshold=100, quarantine_seconds=60)

    for _ in range(n_failures):
        hm.record_failure(SOURCE_MODE, OPERATION, fc)

    state = hm._states.get((SOURCE_MODE, OPERATION))
    assert state is not None
    assert state.consecutive_failures == n_failures, (
        f"Expected consecutive_failures={n_failures} after {n_failures} calls to "
        f"record_failure(fc={fc!r}), got {state.consecutive_failures}"
    )


# ---------------------------------------------------------------------------
# Property 11e: is_down() reflects state correctly (no quarantine expiry)
#
# is_down() must return True iff the state is "down" and the quarantine
# window has not elapsed. With a very long quarantine window, is_down()
# must agree with the internal state field.
#
# Validates: Requirements 8.2, 8.3
# ---------------------------------------------------------------------------


@settings(max_examples=500)
@given(
    events=st.lists(st.booleans(), max_size=20),
    threshold=st.integers(min_value=1, max_value=10),
)
def test_is_down_reflects_state_within_quarantine_window(
    events: list[bool],
    threshold: int,
) -> None:
    """Property 11e: is_down() reflects state correctly within quarantine window.

    With a very long quarantine window, is_down() must return True iff the
    internal state is "down".

    **Validates: Requirements 8.2, 8.3**
    """
    # Use a very long quarantine window so it never expires during the test
    hm = HealthManager(quarantine_threshold=threshold, quarantine_seconds=3600)
    _apply_events(hm, events)

    state = hm._states.get((SOURCE_MODE, OPERATION))
    expected_down = state is not None and state.state == "down"

    internal_state = state.state if state else "None"
    assert hm.is_down(SOURCE_MODE, OPERATION) == expected_down, (
        f"is_down() returned {hm.is_down(SOURCE_MODE, OPERATION)!r} but "
        f"internal state is {internal_state!r} for events={events}, "
        f"threshold={threshold}"
    )
