"""Property and unit tests for ``app.data.refresh_token_store.RefreshTokenStore``.

Property 3: Refresh token store round-trip and rotation
-------------------------------------------------------
After any ``save(t1); rotate(t2); …; rotate(tn)`` sequence, ``load()`` returns
``tn``; raw ciphertext never equals (or contains) any plaintext ``ti``; when
both an env bootstrap value and a stored value exist, the stored value wins.

Validates: Requirements 3.1, 3.2, 3.5, 9.1, 9.7, 13.6.
Also covers: Requirement 3.7 (``mark_invalid`` behavior).
"""

from __future__ import annotations

import asyncio
import os
import tempfile
from pathlib import Path

import aiosqlite
from cryptography.fernet import Fernet
from hypothesis import given, settings
from hypothesis import strategies as st

from app.data.encryptor import FernetEncryptor
from app.data.refresh_token_store import RefreshTokenStore


def _make_encryptor() -> FernetEncryptor:
    return FernetEncryptor(Fernet.generate_key().decode())


async def _fresh_store() -> tuple[RefreshTokenStore, Path]:
    """Create an initialized store backed by a unique temp SQLite file."""
    fd, name = tempfile.mkstemp(suffix=".db")
    os.close(fd)
    path = Path(name)
    store = RefreshTokenStore(str(path), _make_encryptor())
    await store.initialize()
    return store, path


# ---------------------------------------------------------------------------
# Property 3: round-trip + rotation + plaintext-at-rest guarantee.
# ---------------------------------------------------------------------------

# Plaintext strategy.
#
# Real Ring refresh tokens are ~40+ printable-ASCII characters. We mirror
# that shape here with ``min_size=8`` for two reasons:
#   1. It matches the realistic input space (no real refresh token is 1-2
#      characters).
#   2. Fernet ciphertext is URL-safe-base64 (alphabet: ``A-Za-z0-9-_=``),
#      so a 1- or 2-character plaintext drawn from that same alphabet would
#      appear as a substring of the ciphertext purely by coincidence,
#      causing the plaintext-at-rest substring check below to flap without
#      indicating a real leak. At length 8+ with printable ASCII the odds of
#      an accidental substring match in ~140 bytes of ciphertext are
#      astronomically small (<1e-10).
_token_strategy = st.text(
    alphabet=st.characters(min_codepoint=0x20, max_codepoint=0x7E),
    min_size=8,
    max_size=100,
)


@settings(max_examples=40, deadline=None)
@given(sequence=st.lists(_token_strategy, min_size=1, max_size=10, unique=True))
def test_property3_rotation_round_trip_and_ciphertext_at_rest(
    sequence: list[str],
) -> None:
    """After save + n rotations, load returns the last token and no plaintext
    appears in the raw stored ciphertext.

    **Validates: Requirements 3.1, 3.5, 9.1, 9.7, 13.6**
    """

    async def run() -> None:
        store, path = await _fresh_store()
        try:
            await store.save(sequence[0])
            for t in sequence[1:]:
                await store.rotate(t)

            # Round-trip: the last token written wins.
            last = sequence[-1]
            assert await store.load() == last

            # Plaintext-at-rest: the raw stored ciphertext must not equal
            # or contain any plaintext from the sequence. (Req 9.1, 13.6.)
            async with aiosqlite.connect(str(path)) as db:
                cursor = await db.execute(
                    "SELECT refresh_token FROM ring_refresh_token WHERE id = 1"
                )
                row = await cursor.fetchone()
            assert row is not None
            raw: str = row[0]
            for t in sequence:
                assert raw != t, f"ciphertext equals plaintext {t!r}"
                assert t not in raw, f"plaintext leak: {t!r} appears in ciphertext"
        finally:
            path.unlink(missing_ok=True)

    asyncio.run(run())


# ---------------------------------------------------------------------------
# Property 3 (preference sub-clause): stored value wins over env bootstrap.
# ---------------------------------------------------------------------------


async def test_stored_value_is_preserved_when_save_is_skipped() -> None:
    """Requirement 3.2: when a stored refresh token exists, a bootstrap must
    not overwrite it.

    The factory is responsible for the bootstrap decision (a factory-level
    test lives in task 9.5). This test locks the store-level invariant the
    factory depends on: if ``save`` is not called again, ``load`` keeps
    returning the previously stored value — so a factory that checks
    ``load() is not None`` before seeding from the environment will never
    clobber a rotated token.
    """
    store, path = await _fresh_store()
    try:
        await store.save("stored-value")
        # Factory would check ``load() is not None`` and skip bootstrap here.
        assert await store.load() == "stored-value"
        # And a second read is stable.
        assert await store.load() == "stored-value"
    finally:
        path.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Task 4.4: ``mark_invalid()`` unit test (Requirement 3.7).
# ---------------------------------------------------------------------------


async def test_mark_invalid_hides_stored_token_but_preserves_row() -> None:
    """After ``mark_invalid()``, ``load()`` returns ``None`` but the row still
    exists with ``is_valid = 0``.
    """
    store, path = await _fresh_store()
    try:
        await store.save("real-token")
        assert await store.load() == "real-token"
        assert await store.is_valid()

        await store.mark_invalid()

        # Requirement 3.7: after mark_invalid, load acts as if no token exists.
        assert await store.load() is None
        assert not await store.is_valid()

        # But the row is still there with is_valid = 0.
        async with aiosqlite.connect(str(path)) as db:
            cursor = await db.execute(
                "SELECT refresh_token, is_valid FROM ring_refresh_token WHERE id = 1"
            )
            row = await cursor.fetchone()
        assert row is not None, "row should still exist after mark_invalid"
        assert row[1] == 0, "is_valid should be 0"
        # And the ciphertext is non-empty (data is still there, just hidden).
        assert isinstance(row[0], str) and row[0]
    finally:
        path.unlink(missing_ok=True)
