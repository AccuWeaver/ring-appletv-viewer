"""Unofficial-mode end-to-end test (task 17.1).

Composes the real adapter stack against fake Ring API, fake SIP bridge,
and a fake mediamtx WHEP transport. Calls each of the six adapter
methods and asserts the response shape matches the tvOS contract
(Requirements 13.2, 13.3, 13.5).
"""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import AsyncIterator

import httpx
import pytest
from cryptography.fernet import Fernet

from app.adapters.rate_limit import RateLimitGovernor
from app.adapters.ring_consumer_client import RingConsumerClient
from app.adapters.session_map import StreamSessionMap
from app.adapters.sip_bridge_client import SipBridgeClient
from app.adapters.unofficial import UnofficialRingAdapter
from app.data.encryptor import FernetEncryptor
from app.data.refresh_token_store import RefreshTokenStore
from tests.fakes.ring_api import build_ring_api_transport
from tests.fakes.sip_bridge import build_sip_bridge_transport


def _whep_transport() -> httpx.MockTransport:
    """Return a transport that returns an SDP answer including audio."""

    def handler(_request: httpx.Request) -> httpx.Response:
        body = (
            b"v=0\r\n"
            b"o=- 0 0 IN IP4 127.0.0.1\r\n"
            b"s=-\r\n"
            b"m=video 9 UDP/TLS/RTP/SAVPF 96\r\n"
            b"m=audio 9 UDP/TLS/RTP/SAVPF 111\r\n"
        )
        return httpx.Response(201, content=body, headers={"content-type": "application/sdp"})

    return httpx.MockTransport(handler)


@pytest.fixture
async def adapter() -> AsyncIterator[UnofficialRingAdapter]:
    """Compose the real adapter stack over fake transports."""
    tmp = tempfile.NamedTemporaryFile(  # noqa: SIM115 - need manual cleanup
        suffix=".db", delete=False
    )
    tmp.close()

    # Refresh-token store pre-seeded so the adapter starts in a live state.
    encryptor = FernetEncryptor(Fernet.generate_key().decode())
    store = RefreshTokenStore(tmp.name, encryptor)
    await store.initialize()
    await store.save("seed-refresh-token")

    ring_transport, _log = build_ring_api_transport()
    sip_transport = build_sip_bridge_transport()
    whep_transport = _whep_transport()

    ring_http = httpx.AsyncClient(transport=ring_transport)
    sip_http = httpx.AsyncClient(transport=sip_transport)
    whep_http = httpx.AsyncClient(transport=whep_transport)

    governor = RateLimitGovernor(max_per_minute=300, queue_wait_seconds=0.0)
    consumer = RingConsumerClient(ring_http, governor, store)
    sip = SipBridgeClient(
        base_url="http://sip-bridge.test",
        refresh_token_provider=store.load,
        http=sip_http,
    )

    a = UnofficialRingAdapter(
        client=consumer,
        sip=sip,
        sessions=StreamSessionMap(),
        max_concurrent=2,
        mediamtx_whep_base="http://mediamtx.test:8889",
        http=whep_http,
    )

    try:
        yield a
    finally:
        await a.aclose()
        await ring_http.aclose()
        await sip_http.aclose()
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp.name)


async def test_list_devices_returns_mapped_json_api_shape(
    adapter: UnofficialRingAdapter,
) -> None:
    """Validates Requirements 13.2, 13.5 — device list shape."""
    result = await adapter.list_devices()
    assert set(result) == {"data"}
    devs = result["data"]
    assert isinstance(devs, list) and len(devs) == 1
    d = devs[0]
    assert d["id"] == "123"
    assert d["type"] == "doorbell_pro"
    attrs = d["attributes"]
    assert attrs["name"] == "Front Door"
    assert attrs["power_source"] in {"hardwired", "battery"}
    assert attrs["status"] == "online"


async def test_list_events_returns_motion_or_ding_events(
    adapter: UnofficialRingAdapter,
) -> None:
    """Validates Requirements 13.2, 13.5 — event list shape."""
    events = await adapter.list_events("123", limit=10)
    assert events
    for e in events:
        assert e["device_id"] == "123"
        assert e["type"] in {"motion", "ding"}
        assert isinstance(e["duration"], int)


async def test_download_snapshot_returns_bytes_and_content_type(
    adapter: UnofficialRingAdapter,
) -> None:
    """Validates Requirements 13.2, 13.5 — snapshot payload shape."""
    payload = await adapter.download_snapshot("123")
    assert payload.content == b"\x89PNGfake"
    assert payload.content_type.startswith("image/")


async def test_download_video_returns_clip_url(
    adapter: UnofficialRingAdapter,
) -> None:
    """Validates Requirements 13.2, 13.5 — clip URL shape."""
    result = await adapter.download_video("123", event_id="evt1")
    assert result == {"url": "https://cdn.ring.invalid/clip-123.mp4"}


async def test_create_and_delete_stream_session_roundtrip(
    adapter: UnofficialRingAdapter,
) -> None:
    """Validates Requirements 13.2, 13.3 — stream session lifecycle."""
    result = await adapter.create_stream_session("123", sdp_offer="v=0")
    assert result.sdp_answer.startswith("v=0")
    assert result.location == f"/mock/session/{result.session_id}"

    # Session is tracked.
    assert await adapter._sessions.count() == 1

    await adapter.delete_stream_session(result.session_id)
    assert await adapter._sessions.count() == 0
