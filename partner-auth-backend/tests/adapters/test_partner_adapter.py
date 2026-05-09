"""Unit tests for ``PartnerRingAdapter`` failure classification and session lifecycle.

Covers:
  - WHEP status code mapping: 201, 401, 402, 403, 404, 429, 5xx, timeout
  - Snapshot status code mapping: 200, 204, 404, 401, 500
  - Session deletion: success and upstream failure both remove from map

Validates: Requirements 2.1–2.10, 4.1–4.7
"""

from __future__ import annotations

import httpx
import pytest

from app.adapters.errors import (
    AuthenticationRequiredError,
    DeviceNotFoundError,
    RateLimitedError,
    SnapshotUnavailableError,
    SubscriptionRequiredError,
    UpstreamTimeoutError,
    UpstreamUnavailableError,
)
from app.adapters.partner import PartnerRingAdapter
from app.adapters.session_map import StreamSessionMap
from app.adapters.types import PartnerStreamSession

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

DEVICE_ID = "device_abc"
SDP_OFFER = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n"
SDP_ANSWER = "v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\nm=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
PARTNER_SESSION_URL = "https://api.amazonvision.com/v1/sessions/sess_001"


async def _token_provider() -> str:
    return "test-token"


def _make_adapter(
    transport: httpx.MockTransport,
    session_map: StreamSessionMap | None = None,
) -> PartnerRingAdapter:
    """Build a ``PartnerRingAdapter`` with a mock HTTP transport."""
    http = httpx.AsyncClient(transport=transport)
    return PartnerRingAdapter(
        http=http,
        token_provider=_token_provider,
        session_map=session_map or StreamSessionMap(),
    )


def _whep_transport(
    status: int, body: bytes = b"", headers: dict | None = None
) -> httpx.MockTransport:
    """Return a transport that responds to any WHEP POST with the given status."""
    _headers = headers or {}

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(status, content=body, headers=_headers)

    return httpx.MockTransport(handler)


def _snapshot_transport(
    status: int, body: bytes = b"", content_type: str = "image/jpeg"
) -> httpx.MockTransport:
    """Return a transport that responds to any snapshot POST with the given status."""

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            status,
            content=body,
            headers={"content-type": content_type} if status == 200 else {},
        )

    return httpx.MockTransport(handler)


def _timeout_transport() -> httpx.MockTransport:
    """Return a transport that always raises ``httpx.ReadTimeout``."""

    def handler(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("timed out", request=request)

    return httpx.MockTransport(handler)


# ---------------------------------------------------------------------------
# WHEP session creation — success
# ---------------------------------------------------------------------------


async def test_whep_201_returns_sdp_answer_and_binds_session() -> None:
    """WHEP 201 → success: SDP answer returned, session bound in map.

    Validates: Requirements 2.1, 2.2, 2.3
    """
    session_map = StreamSessionMap()
    transport = _whep_transport(
        201,
        body=SDP_ANSWER.encode(),
        headers={"location": PARTNER_SESSION_URL, "content-type": "application/sdp"},
    )
    adapter = _make_adapter(transport, session_map)

    result = await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)

    # SDP answer is passed through verbatim
    assert result.sdp_answer == SDP_ANSWER
    # Location header maps to our internal session path
    assert result.location == f"/mock/session/{result.session_id}"
    # Session is bound in the map
    session = await session_map.lookup(result.session_id)
    assert isinstance(session, PartnerStreamSession)
    assert session.device_id == DEVICE_ID
    assert session.partner_session_url == PARTNER_SESSION_URL
    assert session.source_mode == "partner"


# ---------------------------------------------------------------------------
# WHEP session creation — failure classification
# ---------------------------------------------------------------------------


async def test_whep_401_raises_authentication_required() -> None:
    """WHEP 401 → ``AuthenticationRequiredError``.

    Validates: Requirements 2.5, 4.2
    """
    adapter = _make_adapter(_whep_transport(401))
    with pytest.raises(AuthenticationRequiredError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 401


async def test_whep_402_raises_subscription_required() -> None:
    """WHEP 402 → ``SubscriptionRequiredError``.

    Validates: Requirements 2.6, 4.3
    """
    adapter = _make_adapter(_whep_transport(402))
    with pytest.raises(SubscriptionRequiredError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 402


async def test_whep_403_raises_device_not_found() -> None:
    """WHEP 403 → ``DeviceNotFoundError``.

    Validates: Requirements 2.7, 4.4
    """
    adapter = _make_adapter(_whep_transport(403))
    with pytest.raises(DeviceNotFoundError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 404


async def test_whep_404_raises_device_not_found() -> None:
    """WHEP 404 → ``DeviceNotFoundError``.

    Validates: Requirements 2.7, 4.4
    """
    adapter = _make_adapter(_whep_transport(404))
    with pytest.raises(DeviceNotFoundError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 404


async def test_whep_429_raises_rate_limited() -> None:
    """WHEP 429 → ``RateLimitedError``.

    Validates: Requirements 2.8, 4.5
    """
    adapter = _make_adapter(_whep_transport(429))
    with pytest.raises(RateLimitedError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 429


async def test_whep_500_raises_upstream_unavailable() -> None:
    """WHEP 500 → ``UpstreamUnavailableError``.

    Validates: Requirements 2.9, 4.6
    """
    adapter = _make_adapter(_whep_transport(500))
    with pytest.raises(UpstreamUnavailableError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 502


async def test_whep_503_raises_upstream_unavailable() -> None:
    """WHEP 503 → ``UpstreamUnavailableError`` (generic 5xx path).

    Validates: Requirements 2.9, 4.6
    """
    adapter = _make_adapter(_whep_transport(503))
    with pytest.raises(UpstreamUnavailableError):
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)


async def test_whep_timeout_raises_upstream_timeout() -> None:
    """WHEP network timeout → ``UpstreamTimeoutError``.

    Validates: Requirements 2.10, 4.7
    """
    adapter = _make_adapter(_timeout_transport())
    with pytest.raises(UpstreamTimeoutError) as exc_info:
        await adapter.create_stream_session(DEVICE_ID, SDP_OFFER)
    assert exc_info.value.http_status == 504


# ---------------------------------------------------------------------------
# Snapshot download — success and failure classification
# ---------------------------------------------------------------------------


async def test_snapshot_200_returns_bytes() -> None:
    """Snapshot 200 → success, bytes returned.

    Validates: Requirements 4.1
    """
    image_bytes = b"\xff\xd8\xff\xe0" + b"\x00" * 100  # minimal JPEG header
    adapter = _make_adapter(_snapshot_transport(200, body=image_bytes))
    result = await adapter.download_snapshot(DEVICE_ID)
    assert result.content == image_bytes
    assert "image" in result.content_type


async def test_snapshot_204_raises_snapshot_unavailable() -> None:
    """Snapshot 204 → ``SnapshotUnavailableError``.

    Validates: Requirements 4.2
    """
    adapter = _make_adapter(_snapshot_transport(204))
    with pytest.raises(SnapshotUnavailableError) as exc_info:
        await adapter.download_snapshot(DEVICE_ID)
    assert exc_info.value.http_status == 503


async def test_snapshot_404_raises_snapshot_unavailable() -> None:
    """Snapshot 404 → ``SnapshotUnavailableError``.

    Validates: Requirements 4.2
    """
    adapter = _make_adapter(_snapshot_transport(404))
    with pytest.raises(SnapshotUnavailableError) as exc_info:
        await adapter.download_snapshot(DEVICE_ID)
    assert exc_info.value.http_status == 503


async def test_snapshot_401_raises_authentication_required() -> None:
    """Snapshot 401 → ``AuthenticationRequiredError``.

    Validates: Requirements 4.3
    """
    adapter = _make_adapter(_snapshot_transport(401))
    with pytest.raises(AuthenticationRequiredError) as exc_info:
        await adapter.download_snapshot(DEVICE_ID)
    assert exc_info.value.http_status == 401


async def test_snapshot_500_raises_upstream_unavailable() -> None:
    """Snapshot 500 → ``UpstreamUnavailableError``.

    Validates: Requirements 4.4
    """
    adapter = _make_adapter(_snapshot_transport(500))
    with pytest.raises(UpstreamUnavailableError) as exc_info:
        await adapter.download_snapshot(DEVICE_ID)
    assert exc_info.value.http_status == 502


# ---------------------------------------------------------------------------
# Session deletion
# ---------------------------------------------------------------------------


async def _bind_partner_session(session_map: StreamSessionMap, session_id: str) -> None:
    """Helper: pre-populate the session map with a PartnerStreamSession."""
    import time

    await session_map.bind(
        PartnerStreamSession(
            session_id=session_id,
            partner_session_url=PARTNER_SESSION_URL,
            device_id=DEVICE_ID,
            created_at=time.time(),
            state="active",
        )
    )


async def test_session_deletion_success_removes_from_map() -> None:
    """DELETE success → session removed from map.

    Validates: Requirements 2.4, 4.5
    """
    from app.adapters.errors import StreamSessionNotFoundError

    session_map = StreamSessionMap()
    session_id = "sess-delete-ok"
    await _bind_partner_session(session_map, session_id)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(204)

    adapter = _make_adapter(httpx.MockTransport(handler), session_map)
    await adapter.delete_stream_session(session_id)

    # Session must be gone from the map
    with pytest.raises(StreamSessionNotFoundError):
        await session_map.lookup(session_id)


async def test_session_deletion_upstream_failure_still_removes_from_map() -> None:
    """DELETE upstream failure → session still removed from map (finally block).

    Validates: Requirements 2.4, 4.6
    """
    from app.adapters.errors import StreamSessionNotFoundError

    session_map = StreamSessionMap()
    session_id = "sess-delete-fail"
    await _bind_partner_session(session_map, session_id)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(500)

    adapter = _make_adapter(httpx.MockTransport(handler), session_map)

    # The upstream 500 on DELETE does NOT raise — the finally block removes
    # the session regardless. The adapter swallows the upstream error on delete.
    await adapter.delete_stream_session(session_id)

    # Session must still be gone from the map
    with pytest.raises(StreamSessionNotFoundError):
        await session_map.lookup(session_id)
