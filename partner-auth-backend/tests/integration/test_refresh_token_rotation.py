"""Refresh-token rotation integration test (task 17.2).

Seeds the store with ``t1``; drives a device request against a fake Ring
API that returns ``t2`` in its OAuth response; asserts the store
decrypts to ``t2`` and the raw ciphertext matches neither plaintext.

Validates: Requirements 3.5, 9.7, 13.6.
"""

from __future__ import annotations

import contextlib
import os
import tempfile

import aiosqlite
import httpx
from cryptography.fernet import Fernet

from app.adapters.rate_limit import RateLimitGovernor
from app.adapters.ring_consumer_client import RingConsumerClient
from app.data.encryptor import FernetEncryptor
from app.data.refresh_token_store import RefreshTokenStore
from tests.fakes.ring_api import build_ring_api_transport


async def test_ring_returns_new_refresh_token_updates_store_encrypted() -> None:
    """Ring's opportunistic rotation is persisted atomically and encrypted."""
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tmp:
        db_path = tmp.name
    try:
        encryptor = FernetEncryptor(Fernet.generate_key().decode())
        store = RefreshTokenStore(db_path, encryptor)
        await store.initialize()
        await store.save("t1")
        assert await store.load() == "t1"

        transport, request_log = build_ring_api_transport(
            rotate_refresh_token="t2"
        )
        ring_http = httpx.AsyncClient(transport=transport)
        try:
            governor = RateLimitGovernor(
                max_per_minute=60, queue_wait_seconds=0.0
            )
            client = RingConsumerClient(ring_http, governor, store)

            # Trigger a Ring API call; the client refreshes the access
            # token first, at which point Ring returns t2 and the store
            # rotates.
            await client.get_devices()
        finally:
            await ring_http.aclose()

        # Store now holds t2.
        assert await store.load() == "t2"

        # Raw ciphertext equals neither plaintext.
        async with aiosqlite.connect(db_path) as db:
            cur = await db.execute(
                "SELECT refresh_token FROM ring_refresh_token WHERE id = 1"
            )
            row = await cur.fetchone()
        assert row is not None
        ciphertext = row[0]
        assert "t1" not in ciphertext
        assert "t2" not in ciphertext

        # And the OAuth endpoint was hit at least once (single refresh path).
        oauth_calls = [
            r for r in request_log if "oauth.ring.com" in str(r.url)
        ]
        assert len(oauth_calls) >= 1
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(db_path)
