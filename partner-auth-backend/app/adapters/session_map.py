"""In-memory map of live WHEP stream sessions.

Backed by an ``asyncio.Lock``-protected dict keyed by the backend-generated
``session_id`` (UUID v4 exposed to tvOS via the WHEP ``Location`` header).
The capacity check is exposed separately from ``bind`` so the adapter can
validate capacity **before** contacting the sidecar — per design.md §9,
the check must happen client-side to avoid wasted SIP negotiations.
"""

from __future__ import annotations

import asyncio
from collections.abc import Iterable

from app.adapters.errors import (
    StreamCapacityExceededError,
    StreamSessionNotFoundError,
)
from app.adapters.types import StreamSession


class StreamSessionMap:
    """Live-session registry guarded by an asyncio lock."""

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._sessions: dict[str, StreamSession] = {}

    async def bind(self, session: StreamSession) -> None:
        """Register a freshly created session.

        Raises:
            ValueError: if ``session.session_id`` already exists (indicates
                a UUID collision or duplicate bind, either of which is a
                bug worth surfacing).
        """
        async with self._lock:
            if session.session_id in self._sessions:
                raise ValueError(
                    f"duplicate session_id in map: {session.session_id!r}"
                )
            self._sessions[session.session_id] = session

    async def lookup(self, session_id: str) -> StreamSession:
        """Return the session for ``session_id`` or raise.

        Raises:
            StreamSessionNotFoundError: if the session has been removed or
                never existed.
        """
        async with self._lock:
            session = self._sessions.get(session_id)
        if session is None:
            raise StreamSessionNotFoundError(
                f"no active stream session with id {session_id!r}"
            )
        return session

    async def remove(self, session_id: str) -> StreamSession | None:
        """Remove and return the session for ``session_id``, or ``None``.

        Idempotent: returning ``None`` for an unknown id is not an error
        because ``delete_stream_session`` may run during cleanup after
        Ring has already terminated the SIP session.
        """
        async with self._lock:
            return self._sessions.pop(session_id, None)

    async def count(self) -> int:
        """Return the number of active sessions."""
        async with self._lock:
            return len(self._sessions)

    async def check_capacity(self, max_concurrent: int) -> None:
        """Raise :class:`StreamCapacityExceededError` if the registry is full.

        Called by the adapter before contacting the sidecar so we never
        initiate a SIP negotiation that will be rejected anyway. The check
        is not atomic with the subsequent ``bind`` — two concurrent
        callers may both pass this check and both succeed at ``bind``. The
        resulting overshoot is bounded by the number of concurrent
        callers at the moment of the check, which in practice is tiny;
        design.md explicitly accepts this trade-off.
        """
        async with self._lock:
            if len(self._sessions) >= max_concurrent:
                raise StreamCapacityExceededError(
                    f"stream capacity {max_concurrent} exceeded "
                    f"(active={len(self._sessions)})"
                )

    async def snapshot(self) -> tuple[StreamSession, ...]:
        """Return an immutable snapshot of the current sessions."""
        async with self._lock:
            return tuple(self._sessions.values())

    async def clear(self) -> Iterable[StreamSession]:
        """Remove and return all sessions. Used during adapter ``aclose``.

        Returns a list rather than a tuple to emphasise the caller may
        iterate and dispatch per-session cleanup tasks.
        """
        async with self._lock:
            sessions = list(self._sessions.values())
            self._sessions.clear()
        return sessions
