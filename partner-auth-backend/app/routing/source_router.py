"""Source Router — routes Ring_Adapter operations through the configured Routing_Profile.

Implements:
- Core routing loop: iterate profile in order, skip quarantined, attempt each source
- Fallback-eligible vs non-fallback failure classification
- "Always show real data" guard: skip mock for live media when a real source is up
- Structured logging for routing decisions

Requirements: 1.4, 1.5, 1.6, 1.7, 1.9, 1.11, 7.1, 7.2, 7.3
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable
from typing import Any

from app.adapters.base import RingAdapter
from app.adapters.errors import RingAdapterError, UpstreamUnavailableError
from app.adapters.failure_class import (
    FALLBACK_ELIGIBLE,
    SNAPSHOT_FALLBACK_ELIGIBLE,
)
from app.adapters.session_map import StreamSessionMap
from app.routing.health_manager import HealthManager
from app.routing.snapshot_cache import SnapshotCache
from app.routing.source_result import SourceResult

logger = logging.getLogger(__name__)

_UNKNOWN_REQUEST_ID = "unknown"


class SourceRouter:
    """Routes Ring_Adapter operations through the configured Routing_Profile.

    The router holds an ordered list of adapters (the Routing_Profile) and
    attempts each in order, applying quarantine checks and fallback-eligibility
    classification to decide whether to continue to the next source or return
    immediately.

    Requirements: 1.4, 1.5, 1.6, 1.7, 1.9, 1.11
    """

    def __init__(
        self,
        routing_profile: list[RingAdapter],
        health_manager: HealthManager,
        snapshot_cache: SnapshotCache,
        session_map: StreamSessionMap,
    ) -> None:
        self._profile = routing_profile
        self._health = health_manager
        self._cache = snapshot_cache
        self._session_map = session_map

    # ------------------------------------------------------------------
    # Public operations (mirror RingAdapter interface, return SourceResult)
    # ------------------------------------------------------------------

    async def list_devices(self, *, request_id: str | None = None) -> SourceResult:
        """Route list_devices through the profile."""
        return await self._route_operation(
            "list_devices",
            lambda adapter: adapter.list_devices(),
            is_live_media=False,
            is_snapshot=False,
            request_id=request_id or _UNKNOWN_REQUEST_ID,
        )

    async def list_events(
        self, device_id: str, limit: int, *, request_id: str | None = None
    ) -> SourceResult:
        """Route list_events through the profile."""
        return await self._route_operation(
            "list_events",
            lambda adapter: adapter.list_events(device_id, limit),
            is_live_media=False,
            is_snapshot=False,
            request_id=request_id or _UNKNOWN_REQUEST_ID,
        )

    async def download_video(
        self, device_id: str, event_id: str | None, *, request_id: str | None = None
    ) -> SourceResult:
        """Route download_video through the profile."""
        return await self._route_operation(
            "download_video",
            lambda adapter: adapter.download_video(device_id, event_id),
            is_live_media=False,
            is_snapshot=False,
            request_id=request_id or _UNKNOWN_REQUEST_ID,
        )

    async def create_stream_session(
        self, device_id: str, sdp_offer: str, *, request_id: str | None = None
    ) -> SourceResult:
        """Route stream session creation through the profile (live media path).

        Requirements: 7.1, 7.2
        """
        return await self._route_operation(
            "create_stream_session",
            lambda adapter: adapter.create_stream_session(device_id, sdp_offer),
            is_live_media=True,
            is_snapshot=False,
            request_id=request_id or _UNKNOWN_REQUEST_ID,
        )

    async def delete_stream_session(
        self, session_id: str, *, request_id: str | None = None
    ) -> SourceResult:
        """Route session deletion to the adapter that owns the session.

        Looks up the session in the Session_Map to find the owning adapter,
        then dispatches directly to that adapter (no fallback routing).

        Requirements: 2.4, 3.3
        """
        session = await self._session_map.lookup(session_id)
        adapter = self._adapter_for_mode(session.source_mode)
        await adapter.delete_stream_session(session_id)
        return SourceResult(payload=None, source_mode=session.source_mode)

    async def download_snapshot(
        self, device_id: str, *, request_id: str | None = None
    ) -> SourceResult:
        """Cache-first snapshot path.

        1. Check fresh cache → return without invoking any adapter.
        2. On cache miss, route through profile → write to cache on success.
        3. On all-fail, attempt stale-serve.
        4. On no stale entry, return the error result.

        Requirements: 6.2, 6.3, 6.8, 6.9, 6.10, 7.4
        """
        from app.adapters.base import SnapshotPayload

        rid = request_id or _UNKNOWN_REQUEST_ID

        # 1. Fresh cache hit
        entry = self._cache.get(device_id)
        if entry is not None:
            logger.info(
                "cache_hit device_id=%s source=%s age_seconds=%d",
                device_id,
                entry.source_mode,
                entry.age_seconds(),
            )
            return SourceResult(
                payload=SnapshotPayload(entry.content, entry.content_type),
                source_mode=entry.source_mode,
                cache_age_seconds=None,  # fresh → no age header
            )

        # 2. Route through profile
        result = await self._route_operation(
            "download_snapshot",
            lambda adapter: adapter.download_snapshot(device_id),
            is_live_media=True,
            is_snapshot=True,
            request_id=rid,
        )

        if result.payload is not None:
            # Write to cache on success
            payload: SnapshotPayload = result.payload
            self._cache.put(device_id, payload.content, payload.content_type, result.source_mode)
            return result

        # 3. Stale-serve fallback
        stale = self._cache.get_stale(device_id)
        if stale is not None:
            age = stale.age_seconds()
            logger.info(
                "decision=stale_cache_serve request_id=%s operation=download_snapshot"
                " served_from=%s age_seconds=%d",
                rid,
                stale.source_mode,
                age,
            )
            return SourceResult(
                payload=SnapshotPayload(stale.content, stale.content_type),
                source_mode=stale.source_mode,
                cache_age_seconds=age,
            )

        # 4. All failed, no cache entry
        return result

    # ------------------------------------------------------------------
    # Core routing algorithm
    # ------------------------------------------------------------------

    async def _route_operation(
        self,
        operation: str,
        call: Callable[[RingAdapter], Awaitable[Any]],
        *,
        is_live_media: bool,
        is_snapshot: bool,
        request_id: str = _UNKNOWN_REQUEST_ID,
    ) -> SourceResult:
        """Core routing loop.

        Iterates the Routing_Profile in order, applying:
        - "Always show real data" guard for live media operations
        - Quarantine skip for sources marked down
        - Fallback-eligible vs non-fallback failure classification

        Emits structured log records per Req 10.5 (source invocation outcome)
        and Req 10.6 (routing decisions: fallback, quarantine_skip).

        Requirements: 1.4, 1.5, 1.6, 1.7, 1.9, 1.11
        """
        fallback_eligible = SNAPSHOT_FALLBACK_ELIGIBLE if is_snapshot else FALLBACK_ELIGIBLE
        last_error: RingAdapterError | None = None
        last_mode: str = ""

        for adapter in self._profile:
            mode = adapter.mode()

            # "Always show real data" guard: skip mock for live media
            # unless it's the only source or all real sources are exhausted.
            # Requirements: 1.7, 7.1, 7.2
            if is_live_media and mode == "mock" and self._has_real_source_up(operation):
                logger.info(
                    "real_data_guard_skip source=%s op=%s reason=real_source_up",
                    mode,
                    operation,
                )
                continue

            # Quarantine check — skip sources that are currently down.
            # Requirements: 8.3, 8.4
            if self._health.is_down(mode, operation):
                # Determine the next non-quarantined source for the log record.
                next_source = self._next_eligible_source(mode, operation)
                logger.info(
                    "decision=quarantine_skip request_id=%s operation=%s"
                    " from_source=%s to_source=%s",
                    request_id,
                    operation,
                    mode,
                    next_source,
                )
                continue

            try:
                result = await call(adapter)
                self._health.record_success(mode, operation)
                # Req 10.5: source invocation outcome=ok
                logger.info(
                    "source_invocation request_id=%s operation=%s source_mode=%s outcome=ok",
                    request_id,
                    operation,
                    mode,
                )

                # Req 7.3: WARNING when mock serves live media with real sources configured.
                if is_live_media and mode == "mock" and self._has_real_source_configured():
                    logger.warning(
                        "event=live_media_fallback_to_mock request_id=%s"
                        " operation=%s source_mode=%s",
                        request_id,
                        operation,
                        mode,
                    )

                return SourceResult(payload=result, source_mode=mode)

            except RingAdapterError as exc:
                last_error = exc
                last_mode = mode
                fc = exc.failure_class

                if fc in fallback_eligible:
                    # Fallback-eligible: record failure (may quarantine), try next source.
                    # Requirements: 1.5, 8.1, 8.2
                    self._health.record_failure(mode, operation, fc)
                    # Req 10.5: source invocation outcome=fallback_eligible
                    logger.info(
                        "source_invocation request_id=%s operation=%s source_mode=%s"
                        " outcome=fallback_eligible failure_class=%s",
                        request_id,
                        operation,
                        mode,
                        fc,
                    )
                    # Req 10.6: routing decision=fallback
                    next_source = self._next_eligible_source(mode, operation)
                    logger.info(
                        "decision=fallback request_id=%s operation=%s"
                        " from_source=%s to_source=%s failure_class=%s",
                        request_id,
                        operation,
                        mode,
                        next_source,
                        fc,
                    )
                    continue  # try next source
                else:
                    # Non-fallback: return immediately, do NOT affect health state.
                    # Requirements: 1.6
                    # Req 10.5: source invocation outcome=non_fallback
                    logger.info(
                        "source_invocation request_id=%s operation=%s source_mode=%s"
                        " outcome=non_fallback failure_class=%s",
                        request_id,
                        operation,
                        mode,
                        fc,
                    )
                    return SourceResult(payload=None, source_mode=mode, error=exc)

        # All sources exhausted with fallback-eligible failures.
        # Requirements: 1.11
        if last_error:
            logger.info(
                "all_sources_exhausted request_id=%s operation=%s"
                " last_source=%s last_class=%s",
                request_id,
                operation,
                last_mode,
                last_error.failure_class,
            )
            return SourceResult(payload=None, source_mode=last_mode, error=last_error)

        # No sources were attempted (all quarantined or all skipped by real-data guard).
        # Requirements: 1.11
        logger.warning(
            "all_sources_quarantined request_id=%s operation=%s profile_size=%d",
            request_id,
            operation,
            len(self._profile),
        )
        raise UpstreamUnavailableError("all sources quarantined")

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _has_real_source_up(self, operation: str) -> bool:
        """Return True if any non-mock adapter in the profile is healthy for operation.

        Used by the "always show real data" guard to decide whether to skip
        the mock adapter for live media operations.

        Requirements: 1.7
        """
        for adapter in self._profile:
            mode = adapter.mode()
            if mode != "mock" and not self._health.is_down(mode, operation):
                return True
        return False

    def _has_real_source_configured(self) -> bool:
        """Return True if any non-mock adapter is present in the routing profile.

        Used to decide whether to emit the live_media_fallback_to_mock WARNING.
        Checks configuration (presence in profile), not current health state.

        Requirements: 7.3
        """
        return any(adapter.mode() != "mock" for adapter in self._profile)

    def _next_eligible_source(self, current_mode: str, operation: str) -> str:
        """Return the mode of the next non-quarantined source after *current_mode*.

        Used to populate the ``to_source`` field in routing decision log records
        (Req 10.6). Returns ``"none"`` when no further eligible source exists.
        """
        found_current = False
        for adapter in self._profile:
            mode = adapter.mode()
            if not found_current:
                if mode == current_mode:
                    found_current = True
                continue
            if not self._health.is_down(mode, operation):
                return mode
        return "none"

    def _adapter_for_mode(self, mode: str) -> RingAdapter:
        """Return the adapter in the profile whose mode() matches *mode*.

        Raises:
            ValueError: if no adapter with the given mode is found in the profile.
        """
        for adapter in self._profile:
            if adapter.mode() == mode:
                return adapter
        raise ValueError(
            f"no adapter with mode={mode!r} found in routing profile "
            f"(profile modes: {[a.mode() for a in self._profile]})"
        )
