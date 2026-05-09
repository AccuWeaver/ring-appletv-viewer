"""Wrapper type returned by Source_Router to route handlers.

Carries the adapter's response payload alongside routing metadata
(which source produced it, cache staleness, and any terminal error).
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from app.adapters.errors import RingAdapterError


@dataclass(frozen=True, slots=True)
class SourceResult:
    """Result returned by Source_Router to route handlers.

    Attributes:
        payload: The adapter's return value (dict, SnapshotPayload, etc.),
            or None when all sources failed.
        source_mode: Adapter_Mode that produced this response.
        cache_age_seconds: Set when served from Snapshot_Cache (stale).
            None for fresh cache hits or direct adapter responses.
        error: Set when routing fails (all sources exhausted or
            non-fallback failure encountered). None on success.
    """

    payload: Any
    source_mode: str
    cache_age_seconds: int | None = None
    error: RingAdapterError | None = None
