"""Snapshot Refresh Job — periodic background task that refreshes snapshot cache entries.

Implements:
- Periodic loop with configurable interval
- Skip-if-running via asyncio.Lock.locked() check
- Device list retrieval via SourceRouter
- Per-device snapshot refresh with 10-second timeout
- Structured cycle-completion logging

Requirements: 6.4, 6.5, 6.6, 6.7, 10.7
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from typing import TYPE_CHECKING

from app.adapters.errors import RateLimitedError, RingAdapterError, SnapshotUnavailableError

if TYPE_CHECKING:
    from app.routing.source_router import SourceRouter

logger = logging.getLogger(__name__)

_DEVICE_TIMEOUT_SECONDS = 10


class SnapshotRefreshJob:
    """Periodic background task that refreshes snapshot cache entries.

    Uses an asyncio.Lock to implement skip-if-running: if a cycle is
    still executing when the next tick fires, the tick is a no-op.

    Requirements: 6.4, 6.5, 6.6, 6.7, 10.7
    """

    def __init__(
        self,
        source_router: SourceRouter,
        interval_seconds: int = 45,
    ) -> None:
        self._router = source_router
        self._interval = interval_seconds
        self._lock = asyncio.Lock()
        self._task: asyncio.Task[None] | None = None
        self._running = False

    async def start(self) -> None:
        """Start the periodic refresh loop as a background task.

        Requirements: 6.4
        """
        if self._task is not None and not self._task.done():
            return
        self._running = True
        self._task = asyncio.create_task(self._run_loop(), name="snapshot_refresh_job")

    async def stop(self) -> None:
        """Stop the periodic refresh loop.

        Requirements: 6.4
        """
        self._running = False
        if self._task is not None and not self._task.done():
            self._task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await self._task
        self._task = None

    async def _run_loop(self) -> None:
        """Periodic loop: tick every interval_seconds.

        If a cycle is still running when the next tick fires, the tick
        is skipped (no-op). This prevents overlapping cycles.

        Requirements: 6.4
        """
        while self._running:
            try:
                await asyncio.sleep(self._interval)
            except asyncio.CancelledError:
                break

            if not self._running:
                break

            # Skip-if-running: if the lock is held, a cycle is still executing.
            # Requirements: 6.4
            if self._lock.locked():
                logger.info("snapshot_refresh_skip reason=cycle_still_running")
                continue

            # Fire-and-forget the cycle; errors are caught inside _execute_cycle.
            asyncio.create_task(self._execute_cycle(), name="snapshot_refresh_cycle")

    async def _execute_cycle(self) -> None:
        """One refresh cycle: list devices, refresh each snapshot.

        Acquires the lock for the duration of the cycle so that
        concurrent ticks can detect a running cycle via lock.locked().

        Requirements: 6.5, 6.6, 6.7
        """
        async with self._lock:
            cycle_start = time.monotonic()
            devices_attempted = 0
            devices_refreshed = 0
            devices_failed = 0

            # Obtain device list via SourceRouter (participates in quarantine).
            # Requirements: 6.5
            try:
                list_result = await self._router.list_devices()
            except Exception:
                logger.exception("snapshot_refresh_cycle_list_devices_error")
                return

            if list_result.payload is None:
                logger.warning(
                    "snapshot_refresh_cycle_list_devices_failed source=%s",
                    list_result.source_mode,
                )
                return

            # Extract device IDs from the payload.
            # The payload shape mirrors the Ring_Adapter list_devices return value.
            devices = _extract_device_ids(list_result.payload)

            for device_id in devices:
                devices_attempted += 1
                try:
                    result = await asyncio.wait_for(
                        self._router.download_snapshot(device_id),
                        timeout=_DEVICE_TIMEOUT_SECONDS,
                    )
                    if result.payload is not None:
                        devices_refreshed += 1
                    else:
                        # SourceResult with no payload means all sources failed.
                        # Check the error to decide whether to count as failed.
                        if result.error is not None:
                            _err = result.error
                            if isinstance(_err, (SnapshotUnavailableError, RateLimitedError)):
                                # Skip device for this cycle per Req 6.7.
                                logger.debug(
                                    "snapshot_refresh_device_skip device_id=%s reason=%s",
                                    device_id,
                                    _err.failure_class,
                                )
                            else:
                                devices_failed += 1
                        else:
                            devices_failed += 1

                except TimeoutError:
                    devices_failed += 1
                    logger.warning(
                        "snapshot_refresh_device_timeout device_id=%s",
                        device_id,
                    )
                except (SnapshotUnavailableError, RateLimitedError) as exc:
                    # Skip device for this cycle per Req 6.7.
                    logger.debug(
                        "snapshot_refresh_device_skip device_id=%s reason=%s",
                        device_id,
                        exc.failure_class,
                    )
                except RingAdapterError as exc:
                    devices_failed += 1
                    logger.warning(
                        "snapshot_refresh_device_error device_id=%s class=%s",
                        device_id,
                        exc.failure_class,
                    )
                except Exception:
                    devices_failed += 1
                    logger.exception(
                        "snapshot_refresh_device_unexpected_error device_id=%s",
                        device_id,
                    )

            elapsed_ms = int((time.monotonic() - cycle_start) * 1000)

            # Structured cycle-completion log per Req 10.7.
            logger.info(
                "event=snapshot_refresh_cycle_complete "
                "devices_attempted=%d devices_refreshed=%d "
                "devices_failed=%d elapsed_ms=%d",
                devices_attempted,
                devices_refreshed,
                devices_failed,
                elapsed_ms,
            )


def _extract_device_ids(payload: object) -> list[str]:
    """Extract device IDs from a list_devices payload.

    Handles both the JSON:API shape returned by the Partner adapter
    (``{"data": [{"id": "..."}]}``) and the flat list shape returned
    by the Unofficial/Mock adapters (``[{"device_id": "..."}]``).

    Returns an empty list if the payload shape is unrecognised.
    """
    if isinstance(payload, dict):
        # JSON:API shape: {"data": [{"id": "..."}, ...]}
        data = payload.get("data")
        if isinstance(data, list):
            ids: list[str] = []
            for item in data:
                if isinstance(item, dict):
                    device_id = item.get("id") or item.get("device_id")
                    if device_id and isinstance(device_id, str):
                        ids.append(device_id)
            return ids

    if isinstance(payload, list):
        # Flat list shape: [{"device_id": "..."}, ...]
        ids = []
        for item in payload:
            if isinstance(item, dict):
                device_id = item.get("device_id") or item.get("id")
                if device_id and isinstance(device_id, str):
                    ids.append(device_id)
        return ids

    return []
