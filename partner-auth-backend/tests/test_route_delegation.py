"""Property 8: /mock/* routes are thin delegators.

For random inputs to all six ``/mock/*`` endpoints, a spy adapter records
exactly one call per request with parameters propagated unchanged, and
the route response derives solely from the adapter's return value.

Validates: Requirements 7.4, 12.5, 13.1.
"""

from __future__ import annotations

import asyncio
import uuid

from httpx import ASGITransport, AsyncClient
from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.dependencies import get_ring_adapter
from app.main import app


class SpyAdapter(RingAdapter):
    """Records every call with its kwargs and returns deterministic stubs.

    The stub values are distinctive so we can tell — from the HTTP body
    alone — that the route handler returned what the adapter produced and
    didn't invent data locally.
    """

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict]] = []

    def mode(self) -> str:
        return "mock"

    async def list_devices(self) -> dict:
        self.calls.append(("list_devices", {}))
        return {"data": [{"id": "spy_device", "type": "kind", "attributes": {}}]}

    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        self.calls.append(
            ("list_events", {"device_id": device_id, "limit": limit})
        )
        return [{"id": "spy_event", "device_id": device_id, "limit": limit}]

    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        self.calls.append(("download_snapshot", {"device_id": device_id}))
        return SnapshotPayload(content=b"\x89PNGspy", content_type="image/png")

    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        self.calls.append(
            ("download_video", {"device_id": device_id, "event_id": event_id})
        )
        return {"url": f"https://spy.invalid/{device_id}"}

    async def create_stream_session(
        self, device_id: str, sdp_offer: str
    ) -> StreamSessionResult:
        self.calls.append(
            (
                "create_stream_session",
                {"device_id": device_id, "sdp_offer": sdp_offer},
            )
        )
        sid = str(uuid.uuid4())
        return StreamSessionResult(
            sdp_answer=f"v=0 spy {sdp_offer}",
            location=f"/mock/session/{sid}",
            session_id=sid,
        )

    async def delete_stream_session(self, session_id: str) -> None:
        self.calls.append(("delete_stream_session", {"session_id": session_id}))


# Constrained so the value is safe in URL path components and as a bare
# text body; avoids '/', '?', '#', and control bytes that the input
# sanitizer middleware would reject.
_device_ids = st.text(
    alphabet=st.characters(
        min_codepoint=0x21,
        max_codepoint=0x7E,
        blacklist_characters="/?#%",
    ),
    min_size=1,
    max_size=30,
)
_sdps = st.text(
    alphabet=st.characters(
        min_codepoint=0x20,
        max_codepoint=0x7E,
    ),
    min_size=0,
    max_size=128,
)


def _install_spy() -> SpyAdapter:
    """Install a fresh SpyAdapter on the real app for one request batch."""
    spy = SpyAdapter()
    app.dependency_overrides[get_ring_adapter] = lambda: spy
    return spy


@settings(max_examples=20, deadline=None)
@given(
    device_id=_device_ids,
    limit=st.integers(min_value=0, max_value=50),
)
def test_property8_list_devices_and_events_delegate_unchanged(
    device_id: str, limit: int
) -> None:
    """**Validates: Requirements 7.4, 12.5, 13.1**

    ``GET /mock/devices`` and ``GET /mock/history/devices/{id}/events``
    delegate to the adapter and return its value verbatim.
    """

    async def run() -> None:
        spy = _install_spy()
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            # --- list_devices ---
            r = await client.get("/mock/devices")
            assert r.status_code == 200
            assert r.json() == {
                "data": [{"id": "spy_device", "type": "kind", "attributes": {}}]
            }
            assert [c[0] for c in spy.calls] == ["list_devices"]

            # --- list_events ---
            r = await client.get(
                f"/mock/history/devices/{device_id}/events",
                params={"limit": limit},
            )
            assert r.status_code == 200
            assert r.json() == [
                {"id": "spy_event", "device_id": device_id, "limit": limit}
            ]
            assert len(spy.calls) == 2
            call_name, kwargs = spy.calls[-1]
            assert call_name == "list_events"
            assert kwargs == {"device_id": device_id, "limit": limit}

    asyncio.run(run())


@settings(max_examples=20, deadline=None)
@given(device_id=_device_ids)
def test_property8_snapshot_and_video_delegate_unchanged(device_id: str) -> None:
    """**Validates: Requirements 7.4, 12.5, 13.1**

    Snapshot and clip download endpoints forward ``device_id`` unchanged
    and return the adapter payload verbatim.
    """

    async def run() -> None:
        spy = _install_spy()
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            # --- download_snapshot ---
            r = await client.post(f"/mock/devices/{device_id}/media/image/download")
            assert r.status_code == 200
            assert r.headers.get("content-type", "").startswith("image/png")
            assert r.content == b"\x89PNGspy"
            assert len(spy.calls) == 1
            assert spy.calls[0] == (
                "download_snapshot",
                {"device_id": device_id},
            )

            # --- download_video ---
            r = await client.post(f"/mock/devices/{device_id}/media/video/download")
            assert r.status_code == 200
            assert r.json() == {"url": f"https://spy.invalid/{device_id}"}
            assert len(spy.calls) == 2
            assert spy.calls[1] == (
                "download_video",
                {"device_id": device_id, "event_id": None},
            )

    asyncio.run(run())


@settings(max_examples=20, deadline=None)
@given(device_id=_device_ids, sdp=_sdps)
def test_property8_whep_create_and_delete_delegate_unchanged(
    device_id: str, sdp: str
) -> None:
    """**Validates: Requirements 7.4, 12.5, 13.1**

    WHEP session create and delete forward URL path parameters and the
    raw SDP body to the adapter and return its response verbatim.
    """

    async def run() -> None:
        spy = _install_spy()
        async with AsyncClient(
            transport=ASGITransport(app=app), base_url="http://test"
        ) as client:
            # --- create_stream_session ---
            r = await client.post(
                f"/mock/devices/{device_id}/media/streaming/whep/sessions",
                content=sdp.encode(),
                headers={"Content-Type": "application/sdp"},
            )
            assert r.status_code == 201
            assert r.text == f"v=0 spy {sdp}"
            location = r.headers["location"]
            assert location.startswith("/mock/session/")
            assert len(spy.calls) == 1
            call_name, kwargs = spy.calls[0]
            assert call_name == "create_stream_session"
            assert kwargs == {"device_id": device_id, "sdp_offer": sdp}

            # --- delete_stream_session ---
            session_id = location.removeprefix("/mock/session/")
            r = await client.delete(f"/mock/session/{session_id}")
            assert r.status_code == 200
            assert r.json() == {"status": "deleted"}
            assert len(spy.calls) == 2
            assert spy.calls[1] == (
                "delete_stream_session",
                {"session_id": session_id},
            )

    asyncio.run(run())
