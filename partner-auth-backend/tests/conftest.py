"""Shared pytest fixtures for the partner-auth-backend test suite.

The FastAPI app is built with an `@asynccontextmanager` lifespan that
installs the `RingAdapter` dependency override. `httpx.ASGITransport`
does not drive lifespan events, so tests that use it against the raw app
(the existing pattern in `test_endpoints.py`, `test_input_validation.py`,
and `test_logging.py`) would see the placeholder `RuntimeError` from
`get_ring_adapter()`.

The `_install_mock_adapter` autouse fixture below installs a
`MockRingAdapter` into `app.dependency_overrides` for the whole test
session so those legacy tests keep working without having to wrap every
client in `app.router.lifespan_context(app)`. Tests that want to drive
the lifespan explicitly (integration / regression tests added by the
ring-adapter-backend spec) still can — a dependency override just wins
over the placeholder.

A `SourceRouter` wrapping the same `MockRingAdapter` is also installed
so that the refactored `/mock/*` route handlers (task 13.1) work without
a running lifespan.
"""

from __future__ import annotations

import pytest

from app.adapters.mock import MockRingAdapter
from app.dependencies import get_ring_adapter, get_source_router
from app.main import app
from app.routing.health_manager import HealthManager
from app.routing.snapshot_cache import SnapshotCache
from app.routing.source_router import SourceRouter


@pytest.fixture(autouse=True, scope="session")
def _install_mock_adapter() -> None:
    """Install a MockRingAdapter and SourceRouter singleton for the whole test session."""
    adapter = MockRingAdapter(mediamtx_whep_url="http://unreachable.invalid:9/whep")
    app.dependency_overrides[get_ring_adapter] = lambda: adapter

    # Build a SourceRouter wrapping the mock adapter so that the refactored
    # /mock/* route handlers (task 13.1) work without a running lifespan.
    # Use the adapter's own session map so create→delete flows work correctly.
    source_router = SourceRouter(
        routing_profile=[adapter],
        health_manager=HealthManager(),
        snapshot_cache=SnapshotCache(),
        session_map=adapter._sessions,
    )
    app.dependency_overrides[get_source_router] = lambda: source_router

    # Also stash on app.state for the /health/adapter endpoint to read.
    app.state.adapter = adapter
    app.state.refresh_store = None
    app.state.governor = None
    app.state.session_map = None
    app.state.source_router = source_router
    app.state.health_manager = source_router._health
    app.state.snapshot_cache = source_router._cache
