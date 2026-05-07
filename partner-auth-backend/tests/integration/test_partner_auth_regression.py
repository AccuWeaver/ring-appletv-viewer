"""Partner-auth route preservation regression (task 2.6).

Confirms that the partner-auth routes continue to respond as they do
today under both ``RING_ADAPTER=mock`` and ``RING_ADAPTER=unofficial``.
The test is deliberately narrow: it validates route registration and
shape — not upstream-mocked happy paths (that lives in
``tests/test_endpoints.py``).

Validates: Requirements 12.1, 12.2, 12.3.
"""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import AsyncIterator

import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient

_ENV_KEYS = (
    "RING_CLIENT_ID",
    "RING_CLIENT_SECRET",
    "RING_HMAC_KEY",
    "APP_API_KEY",
    "TOKEN_ENCRYPTION_KEY",
    "RING_ADAPTER",
    "DATABASE_PATH",
    "RING_REFRESH_TOKEN",
)


async def _client_with_mode(
    mode: str,
) -> AsyncIterator[tuple[AsyncClient, str]]:
    """Build a client driving the real app lifespan under the given mode.

    Yields ``(client, api_key)``. Saves and restores ``os.environ`` and
    the conftest dependency override so sibling tests keep working.
    """
    tmp = tempfile.NamedTemporaryFile(  # noqa: SIM115 - need manual lifecycle
        suffix=".db", delete=False
    )
    tmp.close()
    api_key = "partner-auth-regression-key"
    saved_env = {k: os.environ.get(k) for k in _ENV_KEYS}

    os.environ["RING_CLIENT_ID"] = "test"
    os.environ["RING_CLIENT_SECRET"] = "test"
    os.environ["RING_HMAC_KEY"] = "dGVzdGhtYWNrZXkxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMw=="
    os.environ["APP_API_KEY"] = api_key
    os.environ["TOKEN_ENCRYPTION_KEY"] = Fernet.generate_key().decode()
    os.environ["RING_ADAPTER"] = mode
    os.environ["DATABASE_PATH"] = tmp.name
    if mode == "unofficial":
        os.environ["RING_REFRESH_TOKEN"] = "regression-test-token"
    else:
        os.environ.pop("RING_REFRESH_TOKEN", None)

    from app.dependencies import get_ring_adapter
    from app.main import app

    saved_override = app.dependency_overrides.pop(get_ring_adapter, None)

    try:
        async with (
            app.router.lifespan_context(app),
            AsyncClient(
                transport=ASGITransport(app=app), base_url="http://test"
            ) as client,
        ):
            yield client, api_key
    finally:
        if saved_override is not None:
            app.dependency_overrides[get_ring_adapter] = saved_override
        for key, value in saved_env.items():
            if value is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = value
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp.name)


@pytest.mark.parametrize("mode", ["mock", "unofficial"])
async def test_partner_auth_routes_preserved(mode: str) -> None:
    """All partner-auth routes still respond; the adapter does not shadow them.

    Validates Requirements 12.1, 12.2, 12.3.
    """
    async for client, api_key in _client_with_mode(mode):
        # /health — confirms startup succeeded under this mode.
        r = await client.get("/health")
        assert r.status_code == 200
        assert r.json()["adapter_mode"] == mode

        # /ring/app-homepage — returns HTML.
        r = await client.get("/ring/app-homepage")
        assert r.status_code == 200
        assert "text/html" in r.headers["content-type"]

        # /ring/token-exchange — route exists; with no body, 422 (validation).
        r = await client.post("/ring/token-exchange")
        assert r.status_code in (400, 422), (
            f"unexpected {r.status_code} from /ring/token-exchange "
            f"(route should be registered)"
        )

        # /ring/webhook — route exists; with a minimal unrecognized event
        # it returns 200.
        r = await client.post(
            "/ring/webhook",
            json={
                "event_type": "unknown",
                "device_id": "x",
                "timestamp": "2025-01-01T00:00:00Z",
                "event_id": "e1",
            },
        )
        assert r.status_code == 200

        # /ring/account-link — route exists; invalid signature returns 403.
        r = await client.post(
            "/ring/account-link",
            json={"nonce": "n", "signature": "bad", "account_id": "x"},
        )
        assert r.status_code in (400, 401, 403, 422)

        # /api/token — route exists; no auth → 401.
        r = await client.get("/api/token")
        assert r.status_code == 401

        # /api/token with API key — route returns a response whose body
        # shape is the app's (``{"detail": {"error": ...}}``), proving
        # the route layer is reached (vs. starlette's default
        # ``{"detail": "Not Found"}`` for unregistered routes).
        r = await client.get(
            "/api/token",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        body = r.json()
        assert body != {"detail": "Not Found"}
