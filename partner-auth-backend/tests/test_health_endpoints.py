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
            AsyncClient(transport=ASGITransport(app=app), base_url="http://test") as client,
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
        # Original fields preserved (Req 11.6)
        assert "adapter_mode" in body
        assert "refresh_token_valid" in body
        assert "active_stream_sessions" in body
        assert "ring_api_requests_last_minute" in body
        # New fields (Req 10.1–10.4)
        assert "sources" in body
        assert "snapshot_cache" in body
        assert "active_streams" in body
        assert "routing_profile" in body

        assert body["adapter_mode"] == mode
        assert body["active_stream_sessions"] == 0
        if mode == "mock":
            assert body["refresh_token_valid"] is None
            assert body["ring_api_requests_last_minute"] == 0
        else:
            assert body["refresh_token_valid"] is True
            assert isinstance(body["ring_api_requests_last_minute"], int)

        # snapshot_cache shape
        cache = body["snapshot_cache"]
        assert "entry_count" in cache
        assert "total_bytes" in cache
        assert "oldest_entry_age_seconds" in cache
        assert "newest_entry_age_seconds" in cache

        # routing_profile is a list of mode strings
        assert isinstance(body["routing_profile"], list)
        assert all(isinstance(m, str) for m in body["routing_profile"])

        # active_streams is a dict of mode → int
        assert isinstance(body["active_streams"], dict)


@pytest.mark.parametrize("mode", ["mock", "unofficial"])
async def test_health_adapter_snapshot_cache_types(mode: str) -> None:
    """snapshot_cache values must be int or None.

    **Validates: Requirements 10.2**

    entry_count and total_bytes are always int (0 when empty).
    oldest_entry_age_seconds and newest_entry_age_seconds are int when the
    cache has entries, or None when the cache is empty.
    """
    async for client, api_key in _client_with_mode(mode):
        response = await client.get(
            "/health/adapter",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        assert response.status_code == 200
        cache = response.json()["snapshot_cache"]

        assert isinstance(cache["entry_count"], int)
        assert isinstance(cache["total_bytes"], int)
        assert cache["entry_count"] >= 0
        assert cache["total_bytes"] >= 0

        # Age fields are int when cache is non-empty, None when empty.
        oldest = cache["oldest_entry_age_seconds"]
        newest = cache["newest_entry_age_seconds"]
        if cache["entry_count"] == 0:
            assert oldest is None, f"expected None for oldest when cache empty, got {oldest!r}"
            assert newest is None, f"expected None for newest when cache empty, got {newest!r}"
        else:
            assert isinstance(oldest, int), f"expected int for oldest, got {type(oldest)}"
            assert isinstance(newest, int), f"expected int for newest, got {type(newest)}"
            assert oldest >= 0
            assert newest >= 0


@pytest.mark.parametrize("mode", ["mock", "unofficial"])
async def test_health_adapter_active_streams_values_are_ints(mode: str) -> None:
    """active_streams dict values must all be non-negative ints.

    **Validates: Requirements 10.3**
    """
    async for client, api_key in _client_with_mode(mode):
        response = await client.get(
            "/health/adapter",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        assert response.status_code == 200
        active_streams = response.json()["active_streams"]

        assert isinstance(active_streams, dict)
        for src_mode, count in active_streams.items():
            assert isinstance(src_mode, str), f"key {src_mode!r} is not a str"
            assert isinstance(count, int), f"count for {src_mode!r} is not an int: {count!r}"
            assert count >= 0, f"count for {src_mode!r} is negative: {count}"


@pytest.mark.parametrize("mode", ["mock", "unofficial"])
async def test_health_adapter_routing_profile_contains_adapter_mode(mode: str) -> None:
    """routing_profile must contain the configured adapter mode.

    **Validates: Requirements 10.1, 10.4**

    When the backend is started with RING_ADAPTER=<mode>, the routing
    profile is derived from that single value, so the mode string must
    appear in the list.
    """
    async for client, api_key in _client_with_mode(mode):
        response = await client.get(
            "/health/adapter",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        assert response.status_code == 200
        routing_profile = response.json()["routing_profile"]

        assert isinstance(routing_profile, list)
        assert len(routing_profile) >= 1, "routing_profile must not be empty"
        assert mode in routing_profile, (
            f"expected adapter mode {mode!r} in routing_profile, got {routing_profile!r}"
        )
        # Every entry must be a valid mode string
        valid_modes = {"mock", "unofficial", "partner"}
        for entry in routing_profile:
            assert entry in valid_modes, f"unexpected mode {entry!r} in routing_profile"


async def test_health_adapter_api_key_required_returns_401() -> None:
    """GET /health/adapter without an API key must return 401.

    **Validates: Requirements 10.4, 11.6**

    Verifies that the API_Key_Check is enforced on the extended endpoint
    (i.e. the new fields do not bypass authentication).
    """
    async for client, _api_key in _client_with_mode("mock"):
        # No Authorization header
        response = await client.get("/health/adapter")
        assert response.status_code == 401

        # Wrong key
        response = await client.get(
            "/health/adapter",
            headers={"Authorization": "Bearer wrong-key"},
        )
        assert response.status_code == 401


async def test_health_adapter_sources_shape(mode: str = "mock") -> None:
    """sources must be a dict of source_mode → dict of operation → health fields.

    **Validates: Requirements 10.1**

    Each operation entry must contain state, consecutive_failures, and
    last_success_at with the correct types.
    """
    async for client, api_key in _client_with_mode(mode):
        response = await client.get(
            "/health/adapter",
            headers={"Authorization": f"Bearer {api_key}"},
        )
        assert response.status_code == 200
        sources = response.json()["sources"]

        assert isinstance(sources, dict)
        for src_mode, ops in sources.items():
            assert isinstance(src_mode, str)
            assert isinstance(ops, dict)
            for op_name, health in ops.items():
                assert isinstance(op_name, str)
                assert "state" in health, f"missing 'state' for {src_mode}/{op_name}"
                assert "consecutive_failures" in health, (
                    f"missing 'consecutive_failures' for {src_mode}/{op_name}"
                )
                assert "last_success_at" in health, (
                    f"missing 'last_success_at' for {src_mode}/{op_name}"
                )
                assert health["state"] in ("up", "down"), (
                    f"unexpected state {health['state']!r} for {src_mode}/{op_name}"
                )
                assert isinstance(health["consecutive_failures"], int)
                assert health["consecutive_failures"] >= 0
                # last_success_at is a float timestamp or None
                lsa = health["last_success_at"]
                assert lsa is None or isinstance(lsa, (int, float)), (
                    f"last_success_at must be numeric or None, got {type(lsa)}"
                )
