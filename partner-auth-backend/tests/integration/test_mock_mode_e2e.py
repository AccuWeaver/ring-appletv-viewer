"""Mock-mode end-to-end regression (task 2.5).

Drives the real FastAPI app's lifespan with ``RING_ADAPTER=mock`` and
exercises every ``/mock/*`` endpoint. Asserts the response shapes match
the pre-refactor behavior (Requirement 2.8) and proves no route-layer
regression (Requirement 13.4).
"""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import AsyncIterator

import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient

_HLS_STREAM_URL = (
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
    "bipbop_16x9/bipbop_16x9_variant.m3u8"
)


@pytest.fixture
async def mock_client() -> AsyncIterator[AsyncClient]:
    """Construct the app with a fresh temp DB under ``RING_ADAPTER=mock``."""
    tmp_db = tempfile.NamedTemporaryFile(  # noqa: SIM115 - need manual lifecycle
        suffix=".db", delete=False
    )
    tmp_db.close()
    saved_env = {
        k: os.environ.get(k)
        for k in (
            "RING_CLIENT_ID",
            "RING_CLIENT_SECRET",
            "RING_HMAC_KEY",
            "APP_API_KEY",
            "TOKEN_ENCRYPTION_KEY",
            "RING_ADAPTER",
            "DATABASE_PATH",
            "RING_REFRESH_TOKEN",
        )
    }
    os.environ["RING_CLIENT_ID"] = "test"
    os.environ["RING_CLIENT_SECRET"] = "test"
    os.environ["RING_HMAC_KEY"] = "dGVzdGhtYWNrZXkxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMw=="
    os.environ["APP_API_KEY"] = "test-api-key"
    os.environ["TOKEN_ENCRYPTION_KEY"] = Fernet.generate_key().decode()
    os.environ["RING_ADAPTER"] = "mock"
    os.environ["DATABASE_PATH"] = tmp_db.name

    # Import after env is set so Settings() picks up our values.
    from app.dependencies import get_ring_adapter
    from app.main import app

    # Remove any override installed by conftest so we get the real mock
    # adapter created by the lifespan (with our configured WHEP URL).
    saved_override = app.dependency_overrides.pop(get_ring_adapter, None)

    try:
        async with (
            app.router.lifespan_context(app),
            AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ) as client,
        ):
            yield client
    finally:
        # Restore conftest override so other tests keep working.
        if saved_override is not None:
            app.dependency_overrides[get_ring_adapter] = saved_override
        # Restore env.
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value

        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp_db.name)


async def test_get_devices_returns_four_hardcoded_devices(
    mock_client: AsyncClient,
) -> None:
    response = await mock_client.get("/mock/devices")
    assert response.status_code == 200
    data = response.json()
    assert list(data) == ["data"]
    assert [d["id"] for d in data["data"]] == [
        "device_front_door",
        "device_backyard",
        "device_garage",
        "device_indoor",
    ]


async def test_get_events_honors_limit(mock_client: AsyncClient) -> None:
    response = await mock_client.get(
        "/mock/history/devices/device_front_door/events", params={"limit": 5}
    )
    assert response.status_code == 200
    events = response.json()
    assert len(events) == 5
    for e in events:
        assert e["device_id"] == "device_front_door"
        assert e["type"] in {"motion", "ding"}


async def test_download_snapshot_returns_blue_pixel_png(
    mock_client: AsyncClient,
) -> None:
    response = await mock_client.post(
        "/mock/devices/device_front_door/media/image/download"
    )
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("image/png")
    # 1x1 PNG is 67 bytes in the canonical blue-pixel encoding.
    assert len(response.content) == 67


async def test_download_video_returns_hls_test_url(mock_client: AsyncClient) -> None:
    response = await mock_client.post(
        "/mock/devices/device_front_door/media/video/download"
    )
    assert response.status_code == 200
    assert response.json() == {"url": _HLS_STREAM_URL}


async def test_create_whep_session_returns_sdp_with_location_header(
    mock_client: AsyncClient,
) -> None:
    sdp_offer = "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\n"
    response = await mock_client.post(
        "/mock/devices/device_front_door/media/streaming/whep/sessions",
        content=sdp_offer.encode(),
        headers={"Content-Type": "application/sdp"},
    )
    assert response.status_code == 201
    # Stub SDP on fallback branch (mediamtx unreachable in this env).
    assert response.headers["content-type"].startswith("application/sdp")
    assert response.headers["location"].startswith("/mock/session/")
    assert response.text.startswith("v=0")


async def test_delete_session_acknowledges(mock_client: AsyncClient) -> None:
    response = await mock_client.delete("/mock/session/some-session-id")
    assert response.status_code == 200
    assert response.json() == {"status": "deleted"}
