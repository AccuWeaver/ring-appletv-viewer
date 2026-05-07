"""Tests for /health and /health/adapter endpoints.

Validates Requirements 11.5 and 11.6.
"""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import AsyncIterator

import pytest
from cryptography.fernet import Fernet
from httpx import ASGITransport, AsyncClient


async def _client_with_mode(mode: str) -> AsyncIterator[tuple[AsyncClient, str]]:
    tmp = tempfile.NamedTemporaryFile(  # noqa: SIM115 - need manual lifecycle
        suffix=".db", delete=False
    )
    tmp.close()
    api_key = f"health-test-key-{mode}"
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
    os.environ["APP_API_KEY"] = api_key
    os.environ["TOKEN_ENCRYPTION_KEY"] = Fernet.generate_key().decode()
    os.environ["RING_ADAPTER"] = mode
    os.environ["DATABASE_PATH"] = tmp.name
    if mode == "unofficial":
        os.environ["RING_REFRESH_TOKEN"] = "health-test-token"
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
async def test_health_reports_adapter_mode(mode: str) -> None:
    """**Validates: Requirement 11.5**"""
    async for client, _api_key in _client_with_mode(mode):
        response = await client.get("/health")
        assert response.status_code == 200
        body = response.json()
        assert body == {"status": "healthy", "adapter_mode": mode}


async def test_health_adapter_requires_api_key() -> None:
    """**Validates: Requirement 11.6 (auth)**"""
    async for client, _api_key in _client_with_mode("mock"):
        response = await client.get("/health/adapter")
        assert response.status_code == 401


@pytest.mark.parametrize("mode", ["mock", "unofficial"])
async def test_health_adapter_body_shape(mode: str) -> None:
    """**Validates: Requirement 11.6**

    Body must contain the four documented fields. Mock mode reports
    ``refresh_token_valid=None`` and ``ring_api_requests_last_minute=0``.
    """
    async for client, api_key in _client_with_mode(mode):
        response = await client.get(
            "/health/adapter",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        assert response.status_code == 200
        body = response.json()
        assert set(body) == {
            "adapter_mode",
            "refresh_token_valid",
            "active_stream_sessions",
            "ring_api_requests_last_minute",
        }
        assert body["adapter_mode"] == mode
        assert body["active_stream_sessions"] == 0
        if mode == "mock":
            assert body["refresh_token_valid"] is None
            assert body["ring_api_requests_last_minute"] == 0
        else:
            assert body["refresh_token_valid"] is True
            assert isinstance(body["ring_api_requests_last_minute"], int)
