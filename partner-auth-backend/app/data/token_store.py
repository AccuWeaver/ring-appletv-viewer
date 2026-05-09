"""SQLite-backed token and event storage with Fernet encryption at rest."""

import json
from datetime import UTC, datetime

import aiosqlite

from app.data.encryptor import FernetEncryptor

_SCHEMA_SQL = """
CREATE TABLE IF NOT EXISTS users (
    user_id       TEXT PRIMARY KEY,
    account_id    TEXT,
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS tokens (
    user_id        TEXT PRIMARY KEY REFERENCES users(user_id),
    access_token   TEXT NOT NULL,
    refresh_token  TEXT NOT NULL,
    expires_at     TEXT NOT NULL,
    token_type     TEXT NOT NULL DEFAULT 'Bearer',
    scope          TEXT,
    is_valid       INTEGER NOT NULL DEFAULT 1,
    created_at     TEXT NOT NULL,
    updated_at     TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS webhook_events (
    event_id      TEXT PRIMARY KEY,
    event_type    TEXT NOT NULL,
    device_id     TEXT NOT NULL,
    timestamp     TEXT NOT NULL,
    payload       TEXT NOT NULL,
    received_at   TEXT NOT NULL
);
"""


class TokenStore:
    """Async SQLite token store with Fernet encryption for sensitive fields.

    Manages three tables: users, tokens, and webhook_events. Access and refresh
    tokens are encrypted at rest using the provided FernetEncryptor instance.
    """

    def __init__(self, db_path: str, encryptor: FernetEncryptor) -> None:
        """Initialize the token store.

        Args:
            db_path: Path to the SQLite database file.
            encryptor: FernetEncryptor instance for encrypting/decrypting tokens.
        """
        self._db_path = db_path
        self._encryptor = encryptor

    async def initialize(self) -> None:
        """Create database tables if they don't exist."""
        async with aiosqlite.connect(self._db_path) as db:
            await db.executescript(_SCHEMA_SQL)
            await db.commit()

    def _now_iso(self) -> str:
        """Return the current UTC time as an ISO 8601 string."""
        return datetime.now(UTC).isoformat()

    async def create_or_update_user(self, user_id: str, account_id: str | None = None) -> None:
        """Create a new user record or update the existing one.

        Args:
            user_id: Unique user identifier.
            account_id: Ring account ID from account linking (optional).
        """
        now = self._now_iso()
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO users (user_id, account_id, created_at, updated_at)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    account_id = excluded.account_id,
                    updated_at = excluded.updated_at
                """,
                (user_id, account_id, now, now),
            )
            await db.commit()

    async def save_tokens(
        self,
        user_id: str,
        access_token: str,
        refresh_token: str,
        expires_at: str,
        token_type: str = "Bearer",
        scope: str | None = None,
    ) -> None:
        """Store tokens for a user, creating the user record if needed.

        Access and refresh tokens are encrypted before storage.

        Args:
            user_id: User identifier.
            access_token: Plaintext access token to encrypt and store.
            refresh_token: Plaintext refresh token to encrypt and store.
            expires_at: ISO 8601 expiration timestamp.
            token_type: Token type (default: "Bearer").
            scope: OAuth scope string (optional).
        """
        now = self._now_iso()
        encrypted_access = self._encryptor.encrypt(access_token)
        encrypted_refresh = self._encryptor.encrypt(refresh_token)

        async with aiosqlite.connect(self._db_path) as db:
            # Ensure user exists
            await db.execute(
                """
                INSERT INTO users (user_id, account_id, created_at, updated_at)
                VALUES (?, NULL, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET updated_at = excluded.updated_at
                """,
                (user_id, now, now),
            )
            # Insert or replace tokens
            await db.execute(
                """
                INSERT INTO tokens
                    (user_id, access_token, refresh_token, expires_at,
                     token_type, scope, is_valid, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
                ON CONFLICT(user_id) DO UPDATE SET
                    access_token = excluded.access_token,
                    refresh_token = excluded.refresh_token,
                    expires_at = excluded.expires_at,
                    token_type = excluded.token_type,
                    scope = excluded.scope,
                    is_valid = 1,
                    updated_at = excluded.updated_at
                """,
                (
                    user_id,
                    encrypted_access,
                    encrypted_refresh,
                    expires_at,
                    token_type,
                    scope,
                    now,
                    now,
                ),
            )
            await db.commit()

    async def get_tokens(self, user_id: str) -> dict | None:
        """Retrieve and decrypt tokens for a user.

        Args:
            user_id: User identifier.

        Returns:
            A dictionary with decrypted token data, or None if no tokens exist.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                """
                SELECT user_id, access_token, refresh_token, expires_at,
                       token_type, scope, is_valid, created_at, updated_at
                FROM tokens WHERE user_id = ?
                """,
                (user_id,),
            )
            row = await cursor.fetchone()
            if row is None:
                return None

            return {
                "user_id": row["user_id"],
                "access_token": self._encryptor.decrypt(row["access_token"]),
                "refresh_token": self._encryptor.decrypt(row["refresh_token"]),
                "expires_at": row["expires_at"],
                "token_type": row["token_type"],
                "scope": row["scope"],
                "is_valid": bool(row["is_valid"]),
                "created_at": row["created_at"],
                "updated_at": row["updated_at"],
            }

    async def update_tokens(
        self,
        user_id: str,
        access_token: str,
        refresh_token: str,
        expires_at: str,
    ) -> None:
        """Update existing token record with new values.

        Access and refresh tokens are encrypted before storage.

        Args:
            user_id: User identifier.
            access_token: New plaintext access token.
            refresh_token: New plaintext refresh token.
            expires_at: New ISO 8601 expiration timestamp.
        """
        now = self._now_iso()
        encrypted_access = self._encryptor.encrypt(access_token)
        encrypted_refresh = self._encryptor.encrypt(refresh_token)

        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                UPDATE tokens
                SET access_token = ?, refresh_token = ?, expires_at = ?,
                    is_valid = 1, updated_at = ?
                WHERE user_id = ?
                """,
                (encrypted_access, encrypted_refresh, expires_at, now, user_id),
            )
            await db.commit()

    async def invalidate(self, user_id: str) -> None:
        """Mark a user's tokens as invalid.

        Args:
            user_id: User identifier whose tokens should be invalidated.
        """
        now = self._now_iso()
        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                UPDATE tokens SET is_valid = 0, updated_at = ? WHERE user_id = ?
                """,
                (now, user_id),
            )
            await db.commit()

    async def save_event(
        self,
        event_id: str,
        event_type: str,
        device_id: str,
        timestamp: str,
        payload: dict,
    ) -> None:
        """Store a webhook event.

        Args:
            event_id: Unique event identifier.
            event_type: Type of event (e.g., "motion", "ding").
            device_id: Device that generated the event.
            timestamp: ISO 8601 timestamp of the event.
            payload: Raw event payload as a dictionary.
        """
        received_at = self._now_iso()
        payload_json = json.dumps(payload)

        async with aiosqlite.connect(self._db_path) as db:
            await db.execute(
                """
                INSERT INTO webhook_events
                    (event_id, event_type, device_id, timestamp, payload, received_at)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT(event_id) DO NOTHING
                """,
                (event_id, event_type, device_id, timestamp, payload_json, received_at),
            )
            await db.commit()

    async def get_recent_events(self, limit: int = 50) -> list[dict]:
        """Retrieve the most recent webhook events.

        Args:
            limit: Maximum number of events to return (default: 50).

        Returns:
            List of event dictionaries ordered by received_at descending.
        """
        async with aiosqlite.connect(self._db_path) as db:
            db.row_factory = aiosqlite.Row
            cursor = await db.execute(
                """
                SELECT event_id, event_type, device_id, timestamp,
                       payload, received_at
                FROM webhook_events
                ORDER BY received_at DESC
                LIMIT ?
                """,
                (limit,),
            )
            rows = await cursor.fetchall()
            return [
                {
                    "event_id": row["event_id"],
                    "event_type": row["event_type"],
                    "device_id": row["device_id"],
                    "timestamp": row["timestamp"],
                    "payload": json.loads(row["payload"]),
                    "received_at": row["received_at"],
                }
                for row in rows
            ]
