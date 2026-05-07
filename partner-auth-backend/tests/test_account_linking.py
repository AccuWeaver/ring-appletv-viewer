"""Property tests for account linking persistence.

# Feature: partner-auth-backend, Property 3: Account linking persistence
"""

import base64
import hashlib
import hmac
import tempfile

from cryptography.fernet import Fernet
from hypothesis import given, settings
from hypothesis import strategies as st

from app.data.encryptor import FernetEncryptor
from app.data.token_store import TokenStore
from app.services.hmac_verifier import HMACVerifier

# Generate a valid Fernet key for testing
TEST_FERNET_KEY = Fernet.generate_key().decode()

# Strategy: random bytes for the HMAC signing key (16-64 bytes), base64-encoded
hmac_key_strategy = st.binary(min_size=16, max_size=64).map(
    lambda b: base64.b64encode(b).decode()
)

# Strategy: random account_id (non-empty printable strings)
account_id_strategy = st.text(
    alphabet=st.characters(categories=("L", "N")),
    min_size=1,
    max_size=50,
)

# Strategy: random user_id (non-empty printable strings)
user_id_strategy = st.text(
    alphabet=st.characters(categories=("L", "N")),
    min_size=1,
    max_size=50,
)

# Strategy: random nonce prefix (simulating timestamp portion)
nonce_prefix_strategy = st.text(
    alphabet=st.characters(categories=("N",)),
    min_size=1,
    max_size=20,
)


def _compute_hmac_signature(key_b64: str, nonce: str) -> str:
    """Compute HMAC-SHA256 signature for a nonce using a base64-encoded key."""
    key_bytes = base64.b64decode(key_b64)
    return hmac.new(key_bytes, nonce.encode("utf-8"), hashlib.sha256).hexdigest()


@settings(max_examples=100)
@given(
    hmac_key_b64=hmac_key_strategy,
    account_id=account_id_strategy,
    user_id=user_id_strategy,
    nonce_prefix=nonce_prefix_strategy,
)
async def test_account_linking_creates_user_record(
    hmac_key_b64: str,
    account_id: str,
    user_id: str,
    nonce_prefix: str,
) -> None:
    """Property 3: Account linking persistence

    For any valid account linking request with correct HMAC, TokenStore SHALL
    contain the user record with the correct account_id.

    **Validates: Requirements 2.3**
    """
    # Set up a temporary SQLite database
    with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
        db_path = tmp.name

    encryptor = FernetEncryptor(TEST_FERNET_KEY)
    token_store = TokenStore(db_path, encryptor)
    await token_store.initialize()

    # Construct a nonce in the expected format: "<prefix>:<account_id>"
    nonce = f"{nonce_prefix}:{account_id}"

    # Compute the correct HMAC signature
    signature = _compute_hmac_signature(hmac_key_b64, nonce)

    # Verify the HMAC passes (simulating what the endpoint does)
    verifier = HMACVerifier(hmac_key_b64)
    assert verifier.verify(nonce, signature) is True, (
        "HMAC verification should pass for correctly signed nonce"
    )

    # Simulate the account link endpoint logic: create/update user record
    await token_store.create_or_update_user(user_id=user_id, account_id=account_id)

    # Verify the user record exists with the correct account_id
    import aiosqlite

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT user_id, account_id FROM users WHERE user_id = ?",
            (user_id,),
        )
        row = await cursor.fetchone()

    assert row is not None, (
        f"User record should exist after account linking for user_id={user_id!r}"
    )
    assert row["account_id"] == account_id, (
        f"Stored account_id {row['account_id']!r} != expected {account_id!r}"
    )


@settings(max_examples=100)
@given(
    hmac_key_b64=hmac_key_strategy,
    account_id=account_id_strategy,
    user_id=user_id_strategy,
    nonce_prefix=nonce_prefix_strategy,
    updated_account_id=account_id_strategy,
)
async def test_account_relinking_updates_not_duplicates(
    hmac_key_b64: str,
    account_id: str,
    user_id: str,
    nonce_prefix: str,
    updated_account_id: str,
) -> None:
    """Property 3: Account linking persistence

    Re-linking with the same user_id SHALL update the existing record rather
    than creating a duplicate.

    **Validates: Requirements 2.3**
    """
    # Set up a temporary SQLite database
    with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
        db_path = tmp.name

    encryptor = FernetEncryptor(TEST_FERNET_KEY)
    token_store = TokenStore(db_path, encryptor)
    await token_store.initialize()

    # First linking: create user record with initial account_id
    nonce1 = f"{nonce_prefix}:{account_id}"
    signature1 = _compute_hmac_signature(hmac_key_b64, nonce1)

    verifier = HMACVerifier(hmac_key_b64)
    assert verifier.verify(nonce1, signature1) is True

    await token_store.create_or_update_user(user_id=user_id, account_id=account_id)

    # Second linking: re-link with updated account_id
    nonce2 = f"{nonce_prefix}:{updated_account_id}"
    signature2 = _compute_hmac_signature(hmac_key_b64, nonce2)

    assert verifier.verify(nonce2, signature2) is True

    await token_store.create_or_update_user(user_id=user_id, account_id=updated_account_id)

    # Verify: only ONE record exists for this user_id (no duplicates)
    import aiosqlite

    async with aiosqlite.connect(db_path) as db:
        db.row_factory = aiosqlite.Row
        cursor = await db.execute(
            "SELECT COUNT(*) as cnt FROM users WHERE user_id = ?",
            (user_id,),
        )
        count_row = await cursor.fetchone()

        cursor = await db.execute(
            "SELECT user_id, account_id FROM users WHERE user_id = ?",
            (user_id,),
        )
        row = await cursor.fetchone()

    assert count_row["cnt"] == 1, (
        f"Expected exactly 1 user record, found {count_row['cnt']} "
        f"(re-linking should update, not duplicate)"
    )
    assert row["account_id"] == updated_account_id, (
        f"After re-linking, account_id should be updated to "
        f"{updated_account_id!r}, got {row['account_id']!r}"
    )
