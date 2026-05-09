"""Snapshot cache — LRU byte-bounded in-memory cache for device snapshots.

Thread-safe via threading.Lock (not asyncio.Lock) because all operations
are O(1) memory operations with no awaits.
"""

import threading
import time
from collections import OrderedDict
from dataclasses import dataclass


@dataclass(slots=True)
class SnapshotCacheEntry:
    """Single cached snapshot."""

    content: bytes
    content_type: str
    fetched_at: float
    source_mode: str  # Adapter_Mode that produced this snapshot

    def age_seconds(self) -> int:
        """Return the age of this entry in whole seconds."""
        return int(time.time() - self.fetched_at)

    def is_fresh(self, ttl_fresh: int) -> bool:
        """Return True if the entry age is less than ttl_fresh seconds."""
        return self.age_seconds() < ttl_fresh

    def is_stale_servable(self, ttl_stale: int) -> bool:
        """Return True if the entry age is less than ttl_stale seconds."""
        return self.age_seconds() < ttl_stale


class SnapshotCache:
    """LRU byte-bounded in-memory snapshot cache.

    Stores the most recent snapshot per device_id.  Entries are evicted in
    least-recently-used order when the total byte footprint would exceed
    ``max_bytes``.

    Thread-safe via a ``threading.Lock``; all operations are O(1) with no
    awaits so a plain (non-async) lock is appropriate.

    Requirements: 6.1, 6.2, 6.8, 6.11, 6.12
    """

    def __init__(
        self,
        max_bytes: int = 67_108_864,  # 64 MiB
        ttl_fresh_seconds: int = 60,
        ttl_stale_serve_seconds: int = 600,
    ) -> None:
        self._max_bytes = max_bytes
        self._ttl_fresh = ttl_fresh_seconds
        self._ttl_stale = ttl_stale_serve_seconds
        self._entries: OrderedDict[str, SnapshotCacheEntry] = OrderedDict()
        self._total_bytes: int = 0
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Read operations
    # ------------------------------------------------------------------

    def get(self, device_id: str) -> SnapshotCacheEntry | None:
        """Return a fresh cache entry for *device_id*, or ``None``.

        A fresh entry has age < ``ttl_fresh_seconds``.  On a hit the entry
        is promoted to most-recently-used position.
        """
        with self._lock:
            entry = self._entries.get(device_id)
            if entry is not None and entry.is_fresh(self._ttl_fresh):
                self._entries.move_to_end(device_id)
                return entry
            return None

    def get_stale(self, device_id: str) -> SnapshotCacheEntry | None:
        """Return a stale-but-servable entry for *device_id*, or ``None``.

        A stale-servable entry has age < ``ttl_stale_serve_seconds``.
        Does NOT promote the entry (stale reads do not affect LRU order).
        """
        with self._lock:
            entry = self._entries.get(device_id)
            if entry is not None and entry.is_stale_servable(self._ttl_stale):
                return entry
            return None

    # ------------------------------------------------------------------
    # Write operation
    # ------------------------------------------------------------------

    def put(
        self,
        device_id: str,
        content: bytes,
        content_type: str,
        source_mode: str,
    ) -> None:
        """Insert or update the cache entry for *device_id*.

        Algorithm:
        1. Remove the existing entry for *device_id* (if any) and subtract
           its byte count.
        2. Evict LRU entries until ``total_bytes + len(content) <= max_bytes``
           or the cache is empty.
        3. Insert the new entry and move it to the MRU position.
        """
        entry = SnapshotCacheEntry(
            content=content,
            content_type=content_type,
            fetched_at=time.time(),
            source_mode=source_mode,
        )
        entry_size = len(content)
        with self._lock:
            # Step 1: remove old entry if present
            if device_id in self._entries:
                old = self._entries.pop(device_id)
                self._total_bytes -= len(old.content)

            # Step 2: evict LRU entries until there is room
            while self._total_bytes + entry_size > self._max_bytes and self._entries:
                _, evicted = self._entries.popitem(last=False)  # LRU = first
                self._total_bytes -= len(evicted.content)

            # Step 3: insert new entry at MRU position
            self._entries[device_id] = entry
            self._total_bytes += entry_size
            self._entries.move_to_end(device_id)

    # ------------------------------------------------------------------
    # Reporting properties
    # ------------------------------------------------------------------

    @property
    def total_bytes(self) -> int:
        """Total bytes currently held in the cache."""
        with self._lock:
            return self._total_bytes

    @property
    def entry_count(self) -> int:
        """Number of entries currently in the cache."""
        with self._lock:
            return len(self._entries)

    def oldest_age(self) -> int | None:
        """Age in seconds of the LRU (oldest) entry, or ``None`` if empty."""
        with self._lock:
            if not self._entries:
                return None
            first = next(iter(self._entries.values()))
            return first.age_seconds()

    def newest_age(self) -> int | None:
        """Age in seconds of the MRU (newest) entry, or ``None`` if empty."""
        with self._lock:
            if not self._entries:
                return None
            last = next(reversed(self._entries.values()))
            return last.age_seconds()
