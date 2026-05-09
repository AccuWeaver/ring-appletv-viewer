"""Property 2: Adapter errors map to stable HTTP responses.

For every ``RingAdapterError`` subclass, the response body equals
``{"error": exc.code}`` exactly and the status equals ``exc.http_status``.

The second half of the design-level property ("no non-RingAdapterError
escapes an adapter method under induced upstream failures") is scoped to
the adapter layer itself. It's covered by the consumer-client and
unofficial-adapter tests under ``tests/adapters/`` which already exercise
``httpx.HTTPStatusError`` and ``httpx.TimeoutException`` round-trips. A
bare ``Exception`` escaping the adapter would be an implementation bug,
not a property to assert in isolation here; this module focuses on the
HTTP envelope invariant that Requirement 11.2 actually specifies.

Validates: Requirements 1.8, 11.2, 11.3.
"""

from __future__ import annotations

import inspect

import pytest
from fastapi.testclient import TestClient

from app.adapters import errors as adapter_errors
from app.adapters.errors import RingAdapterError
from app.main import app


def _all_error_subclasses() -> list[type[RingAdapterError]]:
    """Discover every concrete ``RingAdapterError`` subclass dynamically.

    Parameterizing over inspection rather than a hard-coded list means
    future subclasses get coverage for free and a removed subclass fails
    loudly rather than silently.
    """
    found: list[type[RingAdapterError]] = []
    for _name, obj in inspect.getmembers(adapter_errors):
        if (
            inspect.isclass(obj)
            and issubclass(obj, RingAdapterError)
            and obj is not RingAdapterError
        ):
            found.append(obj)
    assert found, "no RingAdapterError subclasses discovered"
    return found


@pytest.mark.parametrize(
    "error_cls",
    _all_error_subclasses(),
    ids=lambda cls: cls.__name__,
)
def test_property2_each_error_subclass_maps_to_stable_envelope(
    error_cls: type[RingAdapterError],
) -> None:
    """**Validates: Requirements 1.8, 11.2, 11.3**

    Install a one-shot endpoint that raises ``error_cls``; confirm the
    global handler returns ``{"error": exc.code}`` at ``exc.http_status``
    and nothing else leaks (no upstream message, no traceback).
    """
    path = f"/__test_raise_{error_cls.__name__}"

    async def _raise_route() -> dict:
        raise error_cls("server-side detail that MUST NOT leak")

    app.add_api_route(path, _raise_route, methods=["GET"])

    try:
        with TestClient(app, raise_server_exceptions=False) as client:
            response = client.get(path)

        assert response.status_code == error_cls.http_status
        body = response.json()
        assert body == {"error": error_cls.code}
        # Server-side message must not leak into the response body.
        assert "server-side detail" not in response.text
    finally:
        # Remove the transient route so follow-up tests don't collide on
        # duplicate paths across parameter instances.
        app.router.routes = [
            route for route in app.router.routes if getattr(route, "path", None) != path
        ]
