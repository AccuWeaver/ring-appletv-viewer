"""Integration test for Partner WHEP session lifecycle (task 18.3).

Composes a real ``PartnerRingAdapter`` against a mock ``httpx.AsyncClient``
(via ``httpx.MockTransport``) and exercises the full SDP offer→answer
round-trip, Location header mapping, and DELETE teardown.

Requirements: 2.1–2.4, 12.4
"""

from __future__ import annotations

import re

import httpx
import pytest

from app.adapters.partner import PartnerRingAdapter
from app.adapters.session_map import StreamSessionMap
from app.adapters.types import PartnerStreamSession

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_DEVICE_ID = "device_front_door"
_SDP_OFFER = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\n"
_SDP_ANSWER = "v=0\r\no=- 1 1 IN IP4 192.0.2.1\r\ns=-\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
_PARTNER_SESSION_URL = (
    "https://api.amazonvision.com/v1/devices/device_front_door"
    "/media/streaming/whep/sessions/partner-session-abc123"
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


async def _fake_token() -> str:
    return "test-bearer-token"


def _build_transport(delete_status: int = 200) -> httpx.MockTransport:
    """Return a MockTransport that handles WHEP POST and DELETE.

    POST  …/whep/sessions  → 201 with SDP answer + Location header
    DELETE <partner_session_url> → ``delete_status``
    """

    def handler(request: httpx.Request) -> httpx.Response:
        if request.method == "POST" and "whep/sessions" in str(request.url):
            return httpx.Response(
                201,
                content=_SDP_ANSWER.encode(),
                headers={
                    "content-type": "application/sdp",
                    "location": _PARTNER_SESSION_URL,
                },
            )
        if request.method == "DELETE":
            return httpx.Response(delete_status)
        # Unexpected request — surface it clearly.
        raise AssertionError(f"Unexpected request: {request.method} {request.url}")

    return httpx.MockTransport(handler)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
async def session_map() -> StreamSessionMap:
    return StreamSessionMap()


@pytest.fixture
async def adapter(session_map: StreamSessionMap) -> PartnerRingAdapter:
    transport = _build_transport()
    http = httpx.AsyncClient(transport=transport)
    return PartnerRingAdapter(
        http=http,
        token_provider=_fake_token,
        session_map=session_map,
    )


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------


async def test_create_stream_session_returns_sdp_answer(
    adapter: PartnerRingAdapter,
) -> None:
    """Requirement 2.1 — SDP offer→answer round-trip.

    The adapter must return the SDP answer body from the Partner API response.
    """
    result = await adapter.create_stream_session(_DEVICE_ID, _SDP_OFFER)

    assert result.sdp_answer == _SDP_ANSWER


async def test_create_stream_session_location_maps_to_mock_path(
    adapter: PartnerRingAdapter,
) -> None:
    """Requirement 2.2 — Location header maps to /mock/session/{id}.

    The adapter must expose a backend-local location, not the raw Partner URL.
    """
    result = await adapter.create_stream_session(_DEVICE_ID, _SDP_OFFER)

    assert re.fullmatch(r"/mock/session/[0-9a-f-]{36}", result.location), (
        f"Expected /mock/session/<uuid>, got {result.location!r}"
    )
    assert result.location == f"/mock/session/{result.session_id}"


async def test_create_stream_session_binds_partner_session_in_map(
    adapter: PartnerRingAdapter,
    session_map: StreamSessionMap,
) -> None:
    """Requirement 2.3 — session is bound in StreamSessionMap with source_mode='partner'.

    After create_stream_session the map must contain exactly one entry whose
    source_mode is 'partner' and whose partner_session_url matches the
    Location header returned by the Partner API.
    """
    result = await adapter.create_stream_session(_DEVICE_ID, _SDP_OFFER)

    assert await session_map.count() == 1

    session = await session_map.lookup(result.session_id)
    assert isinstance(session, PartnerStreamSession)
    assert session.source_mode == "partner"
    assert session.device_id == _DEVICE_ID
    assert session.partner_session_url == _PARTNER_SESSION_URL


async def test_delete_stream_session_removes_session_from_map(
    adapter: PartnerRingAdapter,
    session_map: StreamSessionMap,
) -> None:
    """Requirement 2.4 — DELETE removes session from the map.

    After delete_stream_session the map must be empty.
    """
    result = await adapter.create_stream_session(_DEVICE_ID, _SDP_OFFER)
    assert await session_map.count() == 1

    await adapter.delete_stream_session(result.session_id)

    assert await session_map.count() == 0


async def test_delete_stream_session_removes_session_even_on_upstream_error(
    session_map: StreamSessionMap,
) -> None:
    """Requirement 12.4 — session is removed from map even if DELETE upstream fails.

    The adapter's finally-block must call session_map.remove regardless of
    whether the Partner API DELETE returns an error status.
    """
    transport = _build_transport(delete_status=500)
    http = httpx.AsyncClient(transport=transport)
    adapter = PartnerRingAdapter(
        http=http,
        token_provider=_fake_token,
        session_map=session_map,
    )

    result = await adapter.create_stream_session(_DEVICE_ID, _SDP_OFFER)
    assert await session_map.count() == 1

    # The adapter does not raise on non-2xx DELETE; it just removes from map.
    await adapter.delete_stream_session(result.session_id)

    assert await session_map.count() == 0
