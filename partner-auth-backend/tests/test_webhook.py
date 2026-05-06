"""Property tests for webhook event storage round-trip.

# Feature: partner-auth-backend, Property 5: Webhook event storage round-trip
"""

import tempfile

from cryptography.fernet import Fernet
from hypothesis import given, settings
from hypothesis import strategies as st

from app.data.encryptor import FernetEncryptor
from app.data.token_store import TokenStore

# Generate a valid Fernet key for testing
TEST_FERNET_KEY = Fernet.generate_key().decode()

# Strategy: random event_id (non-empty alphanumeric strings, unique per test)
event_id_strategy = st.text(
    alphabet=st.characters(categories=("L", "N")),
    min_size=1,
    max_size=50,
)

# Strategy: random event_type (e.g., "motion", "ding", or arbitrary strings)
event_type_strategy = st.text(
    alphabet=st.characters(categories=("L", "N", "P")),
    min_size=1,
    max_size=30,
)

# Strategy: random device_id
device_id_strategy = st.text(
    alphabet=st.characters(categories=("L", "N")),
    min_size=1,
    max_size=50,
)

# Strategy: random ISO 8601-like timestamp string
timestamp_strategy = st.from_regex(
    r"20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z",
    fullmatch=True,
)

# Strategy: random nested payload dict (JSON-serializable values)
json_primitives = st.one_of(
    st.text(min_size=0, max_size=30),
    st.integers(min_value=-1000000, max_value=1000000),
    st.floats(allow_nan=False, allow_infinity=False),
    st.booleans(),
    st.none(),
)

payload_strategy = st.dictionaries(
    keys=st.text(
        alphabet=st.characters(categories=("L", "N")),
        min_size=1,
        max_size=20,
    ),
    values=st.one_of(
        json_primitives,
        st.lists(json_primitives, max_size=5),
        st.dictionaries(
            keys=st.text(
                alphabet=st.characters(categories=("L", "N")),
                min_size=1,
                max_size=10,
            ),
            values=json_primitives,
            max_size=5,
        ),
    ),
    min_size=0,
    max_size=10,
)


@settings(max_examples=100)
@given(
    event_id=event_id_strategy,
    event_type=event_type_strategy,
    device_id=device_id_strategy,
    timestamp=timestamp_strategy,
    payload=payload_strategy,
)
async def test_webhook_event_storage_round_trip(
    event_id: str,
    event_type: str,
    device_id: str,
    timestamp: str,
    payload: dict,
) -> None:
    """Property 5: Webhook event storage round-trip

    For any random webhook event payload, storing and retrieving SHALL preserve
    all original fields.

    **Validates: Requirements 4.2, 4.3**
    """
    # Set up a temporary SQLite database
    with tempfile.NamedTemporaryFile(suffix=".db") as tmp:
        db_path = tmp.name

    encryptor = FernetEncryptor(TEST_FERNET_KEY)
    token_store = TokenStore(db_path, encryptor)
    await token_store.initialize()

    # Store the webhook event
    await token_store.save_event(
        event_id=event_id,
        event_type=event_type,
        device_id=device_id,
        timestamp=timestamp,
        payload=payload,
    )

    # Retrieve recent events
    events = await token_store.get_recent_events(limit=1)

    # Verify the event was stored and retrieved correctly
    assert len(events) == 1, f"Expected 1 event, got {len(events)}"

    stored_event = events[0]

    # Verify all original fields are preserved
    assert stored_event["event_id"] == event_id, (
        f"event_id mismatch: {stored_event['event_id']!r} != {event_id!r}"
    )
    assert stored_event["event_type"] == event_type, (
        f"event_type mismatch: {stored_event['event_type']!r} != {event_type!r}"
    )
    assert stored_event["device_id"] == device_id, (
        f"device_id mismatch: {stored_event['device_id']!r} != {device_id!r}"
    )
    assert stored_event["timestamp"] == timestamp, (
        f"timestamp mismatch: {stored_event['timestamp']!r} != {timestamp!r}"
    )
    assert stored_event["payload"] == payload, (
        f"payload mismatch: {stored_event['payload']!r} != {payload!r}"
    )

    # Verify received_at is present (system-generated field)
    assert "received_at" in stored_event, "received_at field should be present"
    assert stored_event["received_at"] is not None, "received_at should not be None"
