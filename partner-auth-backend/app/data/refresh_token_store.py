"""Refresh token store for the Ring unofficial adapter.

Persists the single Ring refresh token in a dedicated singleton-row table
(`ring_refresh_token`). The table shares the SQLite file used by
`TokenStore` (``/data/tokens.db`` in containerized deployments) so no
second database is introduced.

The row is keyed by ``id = 1`` with a CHECK constraint so there is exactly
one refresh token in the store, unambiguously. All writes happen inside a
single SQLite transaction so a crash mid-rotation cannot leave the row in
a half-updated state (Requirement 9.7).

Encryption at rest uses the shared `FernetEncryptor` (Requirement 9.1);
plaintext values never touch disk.
"""

from datetime import UTC, datetime

import aiosqlite

from app.data.encryptor import FernetEncryptor

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS ring_refresh_token (
    id            INTEGER PRIMARY KEY CHECK (id = 1),
    refresh_token TEXT    NOT NULL,
    is_valid      INTEGER NOT NULL DEFAULT 1,
    created_at    TEXT    NOT NULL,
    updated_at    TEXT    NOT NULL
);
"""


class RefreshTokenStore:
    """Async singleton-row store for the Ring refresh token."""

    def __init__(self, db_path: str, encryptor: FernetEncryptor) -> None:
        """Initialize the refresh token store.

        Args:
            db_path: Path to the SQLite database file (shared with TokenStore).
            encryptor: FernetEncryptor used to encrypt/decrypt the token at rest.
        """
        self._db_path = db_path
        self._encryptor = encryptor

    async def initialize(self) -> None:
        """Create the ring_refresh_token table if it doesn't exist."""
        async with aiosqlite.connect(self._db_path) as db:
            await db.executescript(_SCHEMA_SQL)
            await db.commit()

    @staticmethod
    def _now_iso() -> str:
        """Return the current UTC time as an ISO 8601 string."""
        return datetime.now(UTC).isoformat()

    async def load(self) -> str | None:
        """Return the decrypted refresh token, or None if absent or invalid."""
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                "SELECT refresh_token, is_valid FROM ring_refresh_token WHERE id = 1"
            )
            row = await cursor.fetchone()
        if row is None or not row["is_valid"]:
            return None
        return self._encryptor.decrypt(row["refresh_token"])

    async def save(self, refresh_token: str) -> None:
        """Upsert the singleton row with an encrypted token and is_valid=1."""
        now = self._now_iso()
        encrypted = self._encryptor.encrypt(refresh_token)
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO ring_refresh_token
                    (id, refresh_token, is_valid, created_at, updated_at)
                VALUES (1, ?, 1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    refresh_token = excluded.refresh_token,
                    is_valid      = 1,
                    updated_at    = excluded.updated_at
                """,
                (encrypted, now, now),
            )
            await db.commit()

    async def rotate(self, new_refresh_token: str) -> None:
        """Atomically replace the stored refresh token with a new value.

        Performs a single-transaction UPDATE (Requirement 9.7). If no row
        yet exists, behaves as `save` (upserts).
        """
        now = self._now_iso()
        encrypted = self._encryptor.encrypt(new_refresh_token)
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute("BEGIN")
            try:
                cursor = await db.execute("SELECT 1 FROM ring_refresh_token WHERE id = 1")
                exists = await cursor.fetchone()
                if exists is None:
                    await db.execute(
                        """
                        INSERT INTO ring_refresh_token
                            (id, refresh_token, is_valid, created_at, updated_at)
                        VALUES (1, ?, 1, ?, ?)
                        """,
                        (encrypted, now, now),
                    )
                else:
                    await db.execute(
                        """
                        UPDATE ring_refresh_token
                        SET refresh_token = ?, is_valid = 1, updated_at = ?
                        WHERE id = 1
                        """,
                        (encrypted, now),
                    )
                await db.commit()
            except Exception:
                await db.rollback()
                raise

    async def mark_invalid(self) -> None:
        """Mark the stored refresh token as invalid (``is_valid = 0``)."""
        now = self._now_iso()
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                "UPDATE ring_refresh_token SET is_valid = 0, updated_at = ? WHERE id = 1",
                (now,),
            )
            await db.commit()

    async def is_valid(self) -> bool:
        """Return True iff a row exists and ``is_valid = 1``."""
        async with aiosqlite.connect(self._db_path) as db:
            cursor = await db.execute("SELECT is_valid FROM ring_refresh_token WHERE id = 1")
            row = await cursor.fetchone()
        return row is not None and bool(row[0])
