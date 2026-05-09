"""Health state machine for per-(source_mode, operation) quarantine tracking.

Implements binary up/down health state with lazy quarantine expiry.
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from typing import Literal

from app.adapters.failure_class import FailureClass


@dataclass
class HealthState:
    """Per-(source, operation) health tracking."""

    state: Literal["up", "down"] = "up"
    consecutive_failures: int = 0
    quarantine_start: float | None = None
    last_success_at: float | None = None


class HealthManager:
    """Tracks binary health state per (source_mode, operation_name).

    State transitions:
    - ``up`` → ``down``: when consecutive_failures reaches the quarantine threshold.
    - ``down`` → ``up``: lazily, when is_down() is called and the quarantine window
      has elapsed, or immediately when record_success() is called.

    Non-fallback failures (e.g. authentication, not_found) do NOT affect health
    state — the caller (Source_Router) is responsible for only calling
    record_failure() for fallback-eligible failures.
    """

    def __init__(
        self,
        quarantine_threshold: int = 3,
        quarantine_seconds: int = 60,
    ) -> None:
        self._threshold = quarantine_threshold
        self._quarantine_seconds = quarantine_seconds
        self._states: dict[tuple[str, str], HealthState] = {}

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def is_down(self, source_mode: str, operation: str) -> bool:
        """Return True if the source is currently quarantined for this operation.

        Lazily checks whether the quarantine window has elapsed and restores
        the source to ``up`` if so.
        """
        hs = self._states.get((source_mode, operation))
        if hs is None or hs.state == "up":
            return False

        # Quarantine is active — check if it has expired
        if (
            hs.quarantine_start is not None
            and (time.time() - hs.quarantine_start) >= self._quarantine_seconds
        ):
            # Quarantine expired → restore to up
            hs.state = "up"
            hs.consecutive_failures = 0
            hs.quarantine_start = None
            return False

        return True

    def record_success(self, source_mode: str, operation: str) -> None:
        """Reset failure counter, mark source up, and record success timestamp."""
        hs = self._get_or_create(source_mode, operation)
        hs.consecutive_failures = 0
        hs.state = "up"
        hs.quarantine_start = None
        hs.last_success_at = time.time()

    def record_failure(self, source_mode: str, operation: str, fc: FailureClass) -> None:
        """Increment consecutive failure counter; quarantine when threshold reached.

        Should only be called for fallback-eligible failures
        (upstream_unavailable, upstream_timeout, snapshot_unavailable for
        snapshot ops). Non-fallback failures must NOT call this method —
        that invariant is enforced by the Source_Router, not here.
        """
        hs = self._get_or_create(source_mode, operation)
        hs.consecutive_failures += 1
        if hs.consecutive_failures >= self._threshold:
            hs.state = "down"
            if hs.quarantine_start is None:
                # Only set quarantine_start on the first transition to down
                hs.quarantine_start = time.time()

    def snapshot(self) -> dict[tuple[str, str], HealthState]:
        """Return a shallow copy of the current health state for all tracked keys.

        Used by the /health/adapter endpoint.
        """
        return dict(self._states)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _get_or_create(self, source_mode: str, operation: str) -> HealthState:
        key = (source_mode, operation)
        if key not in self._states:
            self._states[key] = HealthState()
        return self._states[key]
