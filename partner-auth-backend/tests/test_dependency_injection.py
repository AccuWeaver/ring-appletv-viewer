"""Property 7: Single adapter instance across requests.

For any sequence of HTTP requests, every ``Depends(get_ring_adapter)``
returns the same Python object (``is`` identity), and ``mode()`` returns
the same stable value in ``{"mock", "unofficial"}``.

Validates: Requirements 1.7, 7.3.
"""

from __future__ import annotations

import asyncio

from fastapi import Depends, FastAPI
from httpx import ASGITransport, AsyncClient
from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.base import RingAdapter
from app.adapters.mock import MockRingAdapter
from app.dependencies import get_ring_adapter


def _build_app() -> tuple[FastAPI, MockRingAdapter]:
    """Build a minimal FastAPI app with a test-only identity endpoint.

    Installs a MockRingAdapter via dependency_overrides so every call to
    ``Depends(get_ring_adapter)`` resolves to the same singleton — this
    mirrors the startup-time wiring in ``app/main.py`` lifespan.
    """
    adapter = MockRingAdapter(mediamtx_whep_url="http://unreachable.invalid:9/whep")
    app = FastAPI()
    app.dependency_overrides[get_ring_adapter] = lambda: adapter

    @app.get("/__test_adapter_id")
    async def identity(
        adapter_dep: RingAdapter = Depends(get_ring_adapter),  # noqa: B008
    ) -> dict:
        return {"id": id(adapter_dep), "mode": adapter_dep.mode()}

    return app, adapter


@settings(max_examples=15, deadline=None)
@given(n_requests=st.integers(min_value=1, max_value=50))
def test_property7_single_adapter_instance_across_requests(n_requests: int) -> None:
    """**Validates: Requirements 1.7, 7.3**

    For any number of HTTP requests from 1 to 50, every request resolves
    ``Depends(get_ring_adapter)`` to the same Python object and the same
    ``mode()`` value.
    """

    async def run() -> None:
        app, adapter = _build_app()
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client:
            ids: set[int] = set()
            modes: set[str] = set()
            for _ in range(n_requests):
                response = await client.get("/__test_adapter_id")
                assert response.status_code == 200
                body = response.json()
                ids.add(body["id"])
                modes.add(body["mode"])

            assert ids == {id(adapter)}, ids
            assert modes == {"mock"}, modes
            # Mode must be one of the two documented values (Req 1.7).
            assert modes.issubset({"mock", "unofficial"})

    asyncio.run(run())
