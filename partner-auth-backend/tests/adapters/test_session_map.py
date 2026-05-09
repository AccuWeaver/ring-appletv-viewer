"""Tests for StreamSessionMap and tagged union session types.

Covers requirements 2.3, 3.2, and 13.2:
- Session_Map stores typed sessions with source_mode field
- bind/lookup/remove work with all session types
- lookup returns the typed session so callers can read source_mode
"""

from __future__ import annotations

import time

import pytest

from app.adapters.errors import StreamSessionNotFoundError
from app.adapters.session_map import StreamSessionMap
from app.adapters.types import (
    BaseStreamSession,
    MockStreamSession,
    PartnerStreamSession,
    UnofficialStreamSession,
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _partner_session(
    session_id: str = "sess-partner-1", device_id: str = "dev-1"
) -> PartnerStreamSession:
    return PartnerStreamSession(
        session_id=session_id,
        device_id=device_id,
        created_at=time.time(),
        partner_session_url="https://api.amazonvision.com/v1/devices/dev-1/media/streaming/whep/sessions/abc",
    )


def _unofficial_session(
    session_id: str = "sess-unofficial-1", device_id: str = "dev-2"
) -> UnofficialStreamSession:
    return UnofficialStreamSession(
        session_id=session_id,
        device_id=device_id,
        created_at=time.time(),
        bridge_session_id="bridge-42",
        mediamtx_path="ring/dev-2",
    )


def _mock_session(session_id: str = "sess-mock-1", device_id: str = "dev-3") -> MockStreamSession:
    return MockStreamSession(
        session_id=session_id,
        device_id=device_id,
        created_at=time.time(),
    )


# ---------------------------------------------------------------------------
# Tagged union dataclass tests
# ---------------------------------------------------------------------------


class TestSessionTypeFields:
    """Verify each session type carries the correct source_mode and fields."""

    def test_partner_session_source_mode(self) -> None:
        s = _partner_session()
        assert s.source_mode == "partner"

    def test_unofficial_session_source_mode(self) -> None:
        s = _unofficial_session()
        assert s.source_mode == "unofficial"

    def test_mock_session_source_mode(self) -> None:
        s = _mock_session()
        assert s.source_mode == "mock"

    def test_partner_session_has_partner_session_url(self) -> None:
        url = "https://api.amazonvision.com/v1/devices/dev-1/media/streaming/whep/sessions/xyz"
        s = PartnerStreamSession(
            session_id="s1",
            device_id="d1",
            created_at=1.0,
            partner_session_url=url,
        )
        assert s.partner_session_url == url

    def test_unofficial_session_has_bridge_and_mediamtx_fields(self) -> None:
        s = UnofficialStreamSession(
            session_id="s2",
            device_id="d2",
            created_at=1.0,
            bridge_session_id="bridge-99",
            mediamtx_path="ring/d2",
        )
        assert s.bridge_session_id == "bridge-99"
        assert s.mediamtx_path == "ring/d2"

    def test_all_types_are_base_stream_session_instances(self) -> None:
        assert isinstance(_partner_session(), BaseStreamSession)
        assert isinstance(_unofficial_session(), BaseStreamSession)
        assert isinstance(_mock_session(), BaseStreamSession)

    def test_default_state_is_active(self) -> None:
        for session in (_partner_session(), _unofficial_session(), _mock_session()):
            assert session.state == "active"

    def test_state_is_mutable(self) -> None:
        """BaseStreamSession.state must be mutable (not frozen) for lifecycle transitions."""
        s = _partner_session()
        s.state = "terminated"
        assert s.state == "terminated"


# ---------------------------------------------------------------------------
# StreamSessionMap — bind / lookup / remove
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestStreamSessionMapBind:
    async def test_bind_partner_session(self) -> None:
        m = StreamSessionMap()
        s = _partner_session()
        await m.bind(s)
        assert await m.count() == 1

    async def test_bind_unofficial_session(self) -> None:
        m = StreamSessionMap()
        s = _unofficial_session()
        await m.bind(s)
        assert await m.count() == 1

    async def test_bind_mock_session(self) -> None:
        m = StreamSessionMap()
        s = _mock_session()
        await m.bind(s)
        assert await m.count() == 1

    async def test_bind_duplicate_raises(self) -> None:
        m = StreamSessionMap()
        s = _partner_session(session_id="dup")
        await m.bind(s)
        with pytest.raises(ValueError, match="duplicate session_id"):
            await m.bind(_mock_session(session_id="dup"))

    async def test_bind_multiple_different_types(self) -> None:
        m = StreamSessionMap()
        await m.bind(_partner_session(session_id="p1"))
        await m.bind(_unofficial_session(session_id="u1"))
        await m.bind(_mock_session(session_id="m1"))
        assert await m.count() == 3


@pytest.mark.asyncio
class TestStreamSessionMapLookup:
    async def test_lookup_returns_partner_session_with_source_mode(self) -> None:
        m = StreamSessionMap()
        s = _partner_session(session_id="p1")
        await m.bind(s)
        result = await m.lookup("p1")
        assert result.source_mode == "partner"
        assert isinstance(result, PartnerStreamSession)

    async def test_lookup_returns_unofficial_session_with_source_mode(self) -> None:
        m = StreamSessionMap()
        s = _unofficial_session(session_id="u1")
        await m.bind(s)
        result = await m.lookup("u1")
        assert result.source_mode == "unofficial"
        assert isinstance(result, UnofficialStreamSession)

    async def test_lookup_returns_mock_session_with_source_mode(self) -> None:
        m = StreamSessionMap()
        s = _mock_session(session_id="m1")
        await m.bind(s)
        result = await m.lookup("m1")
        assert result.source_mode == "mock"
        assert isinstance(result, MockStreamSession)

    async def test_lookup_missing_raises_stream_session_not_found(self) -> None:
        m = StreamSessionMap()
        with pytest.raises(StreamSessionNotFoundError):
            await m.lookup("nonexistent")

    async def test_lookup_preserves_typed_fields(self) -> None:
        """Callers can access type-specific fields after lookup."""
        m = StreamSessionMap()
        url = "https://api.amazonvision.com/v1/devices/d1/media/streaming/whep/sessions/abc"
        s = PartnerStreamSession(
            session_id="p2",
            device_id="d1",
            created_at=1.0,
            partner_session_url=url,
        )
        await m.bind(s)
        result = await m.lookup("p2")
        assert isinstance(result, PartnerStreamSession)
        assert result.partner_session_url == url

    async def test_lookup_after_remove_raises(self) -> None:
        m = StreamSessionMap()
        s = _partner_session(session_id="p3")
        await m.bind(s)
        await m.remove("p3")
        with pytest.raises(StreamSessionNotFoundError):
            await m.lookup("p3")


@pytest.mark.asyncio
class TestStreamSessionMapRemove:
    async def test_remove_returns_session(self) -> None:
        m = StreamSessionMap()
        s = _unofficial_session(session_id="u2")
        await m.bind(s)
        removed = await m.remove("u2")
        assert removed is s

    async def test_remove_unknown_returns_none(self) -> None:
        m = StreamSessionMap()
        result = await m.remove("does-not-exist")
        assert result is None

    async def test_remove_decrements_count(self) -> None:
        m = StreamSessionMap()
        await m.bind(_partner_session(session_id="p4"))
        await m.bind(_mock_session(session_id="m4"))
        await m.remove("p4")
        assert await m.count() == 1

    async def test_remove_is_idempotent(self) -> None:
        """Removing the same id twice should not raise."""
        m = StreamSessionMap()
        await m.bind(_mock_session(session_id="m5"))
        await m.remove("m5")
        result = await m.remove("m5")
        assert result is None


# ---------------------------------------------------------------------------
# StreamSessionMap — capacity check
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestStreamSessionMapCapacity:
    async def test_check_capacity_passes_when_under_limit(self) -> None:
        m = StreamSessionMap()
        await m.bind(_partner_session(session_id="p5"))
        # Should not raise with max=2
        await m.check_capacity(max_concurrent=2)

    async def test_check_capacity_raises_when_at_limit(self) -> None:
        from app.adapters.errors import StreamCapacityExceededError

        m = StreamSessionMap()
        await m.bind(_unofficial_session(session_id="u3"))
        await m.bind(_unofficial_session(session_id="u4"))
        with pytest.raises(StreamCapacityExceededError):
            await m.check_capacity(max_concurrent=2)


# ---------------------------------------------------------------------------
# StreamSessionMap — snapshot
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestStreamSessionMapSnapshot:
    async def test_snapshot_returns_all_sessions(self) -> None:
        m = StreamSessionMap()
        p = _partner_session(session_id="p6")
        u = _unofficial_session(session_id="u5")
        await m.bind(p)
        await m.bind(u)
        snap = await m.snapshot()
        assert len(snap) == 2
        ids = {s.session_id for s in snap}
        assert ids == {"p6", "u5"}

    async def test_snapshot_is_immutable_tuple(self) -> None:
        m = StreamSessionMap()
        await m.bind(_mock_session(session_id="m6"))
        snap = await m.snapshot()
        assert isinstance(snap, tuple)


# ---------------------------------------------------------------------------
# StreamSessionMap — clear
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
class TestStreamSessionMapClear:
    async def test_clear_removes_all_sessions(self) -> None:
        m = StreamSessionMap()
        await m.bind(_partner_session(session_id="p7"))
        await m.bind(_unofficial_session(session_id="u6"))
        sessions = await m.clear()
        assert await m.count() == 0
        assert len(list(sessions)) == 2

    async def test_clear_empty_map_returns_empty(self) -> None:
        m = StreamSessionMap()
        sessions = await m.clear()
        assert list(sessions) == []
