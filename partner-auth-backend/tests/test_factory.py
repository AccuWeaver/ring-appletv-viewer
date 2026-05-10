"""Example unit tests for ``app.adapters.factory.create_adapter``.

Validates the fail-fast boot paths:

- ``RING_ADAPTER=invalid`` → ``ConfigurationError`` at startup.
- ``RING_ADAPTER=unofficial`` + no env + empty store → ``ConfigurationError``.
- ``RING_ADAPTER=unofficial`` + env only → store is seeded encrypted.
- ``RING_ADAPTER=unofficial`` + env + stored → stored value wins.

Validates: Requirements 3.1, 3.2, 3.6, 7.2, 7.6, 10.6.
"""

from __future__ import annotations

import contextlib
import os
import tempfile
from collections.abc import Iterator
from contextlib import contextmanager
from types import SimpleNamespace

import aiosqlite
import pytest
from cryptography.fernet import Fernet

from app.adapters.factory import create_adapter
from app.config import ConfigurationError
from app.data.encryptor import FernetEncryptor
from app.data.refresh_token_store import RefreshTokenStore


def _fake_settings(
    ring_adapter: str = "mock",
    ring_refresh_token: str | None = None,
    database_path: str | None = None,
) -> SimpleNamespace:
    """Build a duck-typed Settings object without running config validation.

    ``Settings()`` rejects ``ring_adapter="invalid"`` in ``__init__``, which
    is the exact case we want ``create_adapter`` to defend against
    independently (belt-and-braces per Requirement 7.2). Returning a
    ``SimpleNamespace`` lets us exercise the factory's own validation
    path.
    """
    if database_path is None:
        # NamedTemporaryFile.name gives a fresh path; delete=False so we
        # can close the handle right away and let aiosqlite open it.
        with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as handle:
            database_path = handle.name
    return SimpleNamespace(
        ring_adapter=ring_adapter,
        ring_refresh_token=ring_refresh_token,
        ring_max_concurrent_streams=2,
        ring_api_rate_limit_per_minute=60,
        mediamtx_rtsp_url="rtsp://mediamtx:8554/ring",
        mediamtx_whep_base="http://mediamtx:8889",
        mediamtx_hls_public_base="http://localhost:8888",
        go2rtc_url="http://go2rtc:1984",
        go2rtc_public_url="http://localhost:1984",
        ring_refresh_token_g2r="",
        go2rtc_ring_ice_servers="",
        go2rtc_ring_ice_transport_policy="",
        mediamtx_whep_url="http://localhost:8889/test/whep",
        ring_sip_bridge_url="http://ring-sip-bridge:3000",
        ring_sip_bridge_public_url="http://localhost:3000",
        token_encryption_key=Fernet.generate_key().decode(),
        database_path=database_path,
    )


@contextmanager
def _cleanup_db(path: str) -> Iterator[None]:
    """Remove a temp SQLite file after the test, even on failure."""
    try:
        yield
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(path)


async def _close_adapter(adapter: object) -> None:
    """Close adapter-owned async resources if they exist."""
    aclose = getattr(adapter, "aclose", None)
    if aclose is not None:
        await aclose()
    ring_http = getattr(adapter, "_ring_http", None)
    if ring_http is not None:
        await ring_http.aclose()


async def test_invalid_ring_adapter_raises_configuration_error() -> None:
    """``RING_ADAPTER=invalid`` must fail fast at the factory boundary."""
    settings = _fake_settings(ring_adapter="invalid")
    with _cleanup_db(settings.database_path), pytest.raises(ConfigurationError):
        await create_adapter(settings)


async def test_unofficial_without_env_or_stored_token_fails_fast() -> None:
    """Unofficial mode with neither env nor stored token raises."""
    settings = _fake_settings(ring_adapter="unofficial", ring_refresh_token=None)
    with _cleanup_db(settings.database_path), pytest.raises(ConfigurationError):
        await create_adapter(settings)


async def test_unofficial_with_env_only_seeds_store_encrypted() -> None:
    """Env-bootstrap populates the store with an encrypted value."""
    settings = _fake_settings(ring_adapter="unofficial", ring_refresh_token="env-bootstrap-token")
    with _cleanup_db(settings.database_path):
        adapter = await create_adapter(settings)
        try:
            assert adapter.mode() == "unofficial"

            # The store must decrypt back to the plaintext we passed in.
            encryptor = FernetEncryptor(settings.token_encryption_key)
            store = RefreshTokenStore(settings.database_path, encryptor)
            assert await store.load() == "env-bootstrap-token"

            # And the raw column must be ciphertext (no plaintext at rest).
            async with aiosqlite.connect(settings.database_path) as db:
                cursor = await db.execute(
                    "SELECT refresh_token FROM ring_refresh_token WHERE id = 1"
                )
                row = await cursor.fetchone()
            assert row is not None
            assert "env-bootstrap-token" not in row[0]
        finally:
            await _close_adapter(adapter)


async def test_unofficial_with_env_plus_stored_keeps_stored_value() -> None:
    """Stored value wins over env bootstrap — bootstrap is a no-op."""
    settings = _fake_settings(ring_adapter="unofficial", ring_refresh_token="env-bootstrap-token")
    with _cleanup_db(settings.database_path):
        # Pre-seed the store with a rotated value.
        encryptor = FernetEncryptor(settings.token_encryption_key)
        store = RefreshTokenStore(settings.database_path, encryptor)
        await store.initialize()
        await store.save("rotated-token")
        assert await store.load() == "rotated-token"

        adapter = await create_adapter(settings)
        try:
            # The factory must not have clobbered the stored token with
            # the env bootstrap value.
            assert await store.load() == "rotated-token"
        finally:
            await _close_adapter(adapter)
