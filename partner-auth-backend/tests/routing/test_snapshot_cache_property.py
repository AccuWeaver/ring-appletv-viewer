"""Property-based tests for SnapshotCache.

**Validates: Requirements 6.11, 13.5**

Property 10: Cache Bound Invariant
  For any sequence of put() operations, total_bytes <= max_bytes after each operation.
"""

from hypothesis import given, settings
from hypothesis import strategies as st

from app.routing.snapshot_cache import SnapshotCache

# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

# Keep max_bytes small so tests run fast while still exercising eviction.
max_bytes_st = st.integers(min_value=1, max_value=10_000)

# Device IDs: short non-empty strings to encourage key collisions (updates).
device_id_st = st.text(min_size=1, max_size=10)


def put_sequence_st(max_bytes: int):
    """Generate a list of (device_id, content) pairs.

    Content size is bounded by max_bytes so individual entries can
    potentially fill the cache, exercising the eviction path.
    """
    return st.lists(
        st.tuples(
            device_id_st,
            st.binary(min_size=0, max_size=max_bytes),
        ),
        min_size=0,
        max_size=50,
    )


# ---------------------------------------------------------------------------
# Property 10: Cache Bound Invariant
# ---------------------------------------------------------------------------


@given(
    max_bytes=max_bytes_st,
    operations=st.data(),
)
@settings(max_examples=200)
def test_cache_bound_invariant(max_bytes: int, operations) -> None:
    """**Validates: Requirements 6.11, 13.5**

    Property 10: Cache Bound Invariant

    After every put() call, total_bytes must not exceed max_bytes.
    Also verifies that entry_count is non-negative and that total_bytes
    is consistent with the actual stored entries.
    """
    cache = SnapshotCache(max_bytes=max_bytes)
    puts = operations.draw(put_sequence_st(max_bytes))

    for device_id, content in puts:
        cache.put(
            device_id=device_id,
            content=content,
            content_type="image/jpeg",
            source_mode="mock",
        )

        # Core invariant: byte bound is never exceeded.
        assert cache.total_bytes <= max_bytes, (
            f"total_bytes={cache.total_bytes} exceeded max_bytes={max_bytes} "
            f"after put(device_id={device_id!r}, len={len(content)})"
        )

        # entry_count is always non-negative.
        assert cache.entry_count >= 0, f"entry_count={cache.entry_count} is negative"

        # Consistency: if there are entries, total_bytes must be > 0
        # (unless all stored entries are zero-length).
        # We verify the weaker form: total_bytes >= 0.
        assert cache.total_bytes >= 0, f"total_bytes={cache.total_bytes} is negative"

    # After all operations, the invariant still holds.
    assert cache.total_bytes <= max_bytes
    assert cache.entry_count >= 0


@given(
    max_bytes=max_bytes_st,
    operations=st.data(),
)
@settings(max_examples=100)
def test_total_bytes_consistent_with_entries(max_bytes: int, operations) -> None:
    """**Validates: Requirements 6.11, 13.5**

    total_bytes must equal the sum of len(entry.content) for all stored entries.
    This verifies the internal accounting is correct after any sequence of puts.
    """
    cache = SnapshotCache(max_bytes=max_bytes)
    puts = operations.draw(put_sequence_st(max_bytes))

    for device_id, content in puts:
        cache.put(
            device_id=device_id,
            content=content,
            content_type="image/jpeg",
            source_mode="mock",
        )

    # Access internal state to verify accounting consistency.
    # pylint: disable=protected-access
    with cache._lock:
        actual_bytes = sum(len(e.content) for e in cache._entries.values())
        reported_bytes = cache._total_bytes
        entry_count = len(cache._entries)

    assert reported_bytes == actual_bytes, (
        f"total_bytes accounting mismatch: reported={reported_bytes}, actual sum={actual_bytes}"
    )
    assert cache.entry_count == entry_count
    assert reported_bytes <= max_bytes
