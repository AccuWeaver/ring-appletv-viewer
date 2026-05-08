"""Property 1: Mock adapter behavior is unchanged from current routes.

For any valid request input, `MockRingAdapter` method output SHALL equal the
pre-refactor route output byte-for-byte (modulo the UUID in the Location
header, which is matched by the UUID regex since both the legacy route and
the adapter generate the value with ``uuid.uuid4()``).

Validates: Requirements 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 13.4.
"""

import re
from datetime import timedelta

from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.mock import (
    _BLUE_PIXEL_PNG,
    MOCK_DEVICES,
    MockRingAdapter,
    _generate_mock_events,
)

_LOCATION_RE = re.compile(r"^/mock/session/[0-9a-f-]{36}$")

# Inlined here (rather than imported) so any divergence in the adapter's
# stream URL is caught by this regression fence.
_HLS_TEST_STREAM_URL = (
    "https://devstreaming-cdn.apple.com/videos/streaming/examples/"
    "bipbop_16x9/bipbop_16x9_variant.m3u8"
)


# Helper — not a pytest fixture so hypothesis composes cleanly.
def _adapter() -> MockRingAdapter:
    return MockRingAdapter(mediamtx_whep_url="http://unreachable.invalid:9/whep")


# --- list_devices -----------------------------------------------------------


async def test_list_devices_matches_legacy_hardcoded_shape() -> None:
    result = await _adapter().list_devices()
    assert result == {"data": MOCK_DEVICES}
    assert len(result["data"]) == 4
    assert [d["id"] for d in result["data"]] == [
        "device_front_door",
        "device_backyard",
        "device_garage",
        "device_indoor",
    ]


# --- list_events ------------------------------------------------------------


# The legacy route accepts ``limit: int = 10`` then takes ``min(limit, 50)``.
# Hypothesis varies device_id and limit to exercise that boundary.
@given(
    device_id=st.text(
        alphabet=st.characters(
            min_codepoint=0x20, max_codepoint=0x7E, blacklist_characters="/"
        ),
        min_size=1,
        max_size=40,
    ),
    limit=st.integers(min_value=0, max_value=200),
)
async def test_list_events_matches_generator_capped_at_50(
    device_id: str, limit: int
) -> None:
    """Byte-for-byte equivalence modulo ``created_at``.

    ``_generate_mock_events`` calls ``datetime.now(UTC)`` internally, so two
    back-to-back invocations produce timestamps that differ by microseconds.
    Every *other* field must match the generator output exactly, and the
    clock drift between the two calls must be small (< 1 s in practice).
    """
    from datetime import datetime

    adapter = _adapter()
    result = await adapter.list_events(device_id, limit)
    expected = _generate_mock_events(device_id, count=min(limit, 50))

    # Cardinality first (Requirement 2.2).
    assert len(result) == min(max(limit, 0), 50) == len(expected)

    # Field-by-field equivalence, allowing only the wall-clock field to drift.
    for got, want in zip(result, expected, strict=True):
        assert got.keys() == want.keys()
        for k in got:
            if k == "created_at":
                dt_got = datetime.fromisoformat(got[k])
                dt_want = datetime.fromisoformat(want[k])
                assert abs((dt_got - dt_want).total_seconds()) < 1.0
            else:
                assert got[k] == want[k]

    # Spec-level invariants (Requirement 2.2).
    for ev in result:
        assert ev["device_id"] == device_id
        assert ev["type"] in {"motion", "ding"}


# --- download_snapshot ------------------------------------------------------


@given(device_id=st.text(min_size=1, max_size=40))
async def test_download_snapshot_returns_blue_pixel_png(device_id: str) -> None:
    payload = await _adapter().download_snapshot(device_id)
    assert payload.content == _BLUE_PIXEL_PNG
    assert payload.content_type == "image/png"


# --- download_video --------------------------------------------------------


@given(
    device_id=st.text(min_size=1, max_size=40),
    event_id=st.one_of(st.none(), st.text(min_size=1, max_size=40)),
)
async def test_download_video_returns_apple_hls_test_stream(
    device_id: str, event_id: str | None
) -> None:
    result = await _adapter().download_video(device_id, event_id)
    assert result == {"url": _HLS_TEST_STREAM_URL}


# --- create_stream_session (mediamtx-unreachable path) ---------------------


# The adapter is constructed with an unreachable WHEP URL so the fallback
# branch is always exercised. ``httpx.ConnectError`` / timeout → stub SDP.
# A relaxed hypothesis deadline guards against slow DNS resolvers for ``.invalid``.
@settings(deadline=timedelta(seconds=5), max_examples=25)
@given(
    device_id=st.text(min_size=1, max_size=40),
    sdp_offer=st.text(min_size=0, max_size=256),
)
async def test_create_stream_session_falls_back_to_stub_when_mediamtx_down(
    device_id: str, sdp_offer: str
) -> None:
    from app.adapters.mock import _STUB_SDP_ANSWER

    result = await _adapter().create_stream_session(device_id, sdp_offer)
    # Location: byte-for-byte shape modulo UUID (per task brief).
    assert _LOCATION_RE.match(result.location), result.location
    # session_id identical to the UUID portion of the Location.
    assert result.location == f"/mock/session/{result.session_id}"
    # Stub SDP: present and identical to the ported constant.
    assert result.sdp_answer == _STUB_SDP_ANSWER


# --- delete_stream_session -------------------------------------------------


@given(session_id=st.text(min_size=1, max_size=40))
async def test_delete_stream_session_is_a_noop(session_id: str) -> None:
    # Must not raise and must return None (legacy behavior: acknowledge only).
    assert await _adapter().delete_stream_session(session_id) is None


# --- mode -------------------------------------------------------------------


async def test_mode_is_mock() -> None:
    assert _adapter().mode() == "mock"
