"""Rolling-window outbound rate limiter for Ring consumer API calls.

`RateLimitGovernor` enforces a ceiling of at most ``max_per_minute``
successful `acquire()` calls per rolling 60-second window, as required by
Requirement 8.1. Contention beyond the ceiling queues callers up to
``queue_wait_seconds`` before raising `RateLimitedError` (Requirement 8.2).

This class is deliberately internal to the `UnofficialRingAdapter`: it
shapes **outbound** HTTP traffic to ``api.ring.com`` and is independent of
the existing ``slowapi`` inbound limiter.
"""

from __future__ import annotations

import asyncio
import time
from collections import deque
from typing import Final

from app.adapters.errors import RateLimitedError


class RateLimitGovernor:
    """Monotonic rolling-window limiter with bounded queue wait.

    The governor tracks the monotonic timestamps of the most recent
    successful `acquire()` calls and only admits a new caller if fewer
    than ``max_per_minute`` events sit inside the current 60-second
    window. If the window is full, callers are queued (via
    ``asyncio.sleep``) until either a slot frees up or the configured
    ``queue_wait_seconds`` budget elapses, at which point
    `RateLimitedError` is raised.

    The limiter reserves its slot only after the capacity check succeeds
    inside the lock, so a cancelled `acquire()` never leaks a reserved
    slot.
    """

    WINDOW_SECONDS: Final[float] = 60.0

    def __init__(self, max_per_minute: int, queue_wait_seconds: float) -> None:
        if max_per_minute < 1:
            raise ValueError(f"max_per_minute must be >= 1, got {max_per_minute}")
        if queue_wait_seconds < 0:
            raise ValueError(f"queue_wait_seconds must be >= 0, got {queue_wait_seconds}")
        self._max = max_per_minute
        self._wait = queue_wait_seconds
        self._events: deque[float] = deque()
        self._lock = asyncio.Lock()

    async def acquire(self) -> None:
        """Reserve a slot in the current window or raise ``RateLimitedError``.

        Blocks for up to ``queue_wait_seconds`` waiting for capacity. If the
        deadline passes without a slot becoming available, raises
        ``RateLimitedError`` (Requirement 8.2).
        """
        deadline = time.monotonic() + self._wait
        while True:
            async with self._lock:
                now = time.monotonic()
                self._trim_locked(now)
                if len(self._events) < self._max:
                    self._events.append(now)
                    return
                oldest = self._events[0]
            # Lock released. Sleep until the oldest event exits the window
            # — or until our queue deadline — whichever comes first. We do
            # not raise pre-emptively: Requirement 8.2 commits us to
            # queueing for the full ``queue_wait_seconds`` budget before
            # surfacing a rate-limit error.
            sleep_until_free = oldest + self.WINDOW_SECONDS
            now = time.monotonic()
            if now >= deadline:
                raise RateLimitedError(f"rate limit exceeded; waited {self._wait:.1f}s")
            sleep_for = max(0.0, min(sleep_until_free, deadline) - now)
            await asyncio.sleep(sleep_for)

    async def current_rate(self) -> int:
        """Return the number of events observed in the last 60 seconds."""
        async with self._lock:
            self._trim_locked(time.monotonic())
            return len(self._events)

    def _trim_locked(self, now: float) -> None:
        """Drop events older than the rolling window. Caller must hold the lock."""
        cutoff = now - self.WINDOW_SECONDS
        while self._events and self._events[0] <= cutoff:
            self._events.popleft()
