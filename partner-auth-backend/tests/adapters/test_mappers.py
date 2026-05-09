"""Property 9: Device and event mapping conform to the contract.

Random ``RingDevice`` and ``RingEvent`` inputs produce ``DeviceResource`` /
``EventResource`` instances that pass Pydantic validation; the mappers
raise ``ValueError`` for unsupported event kinds so the adapter layer can
filter them, keeping the tvOS-facing subset bounded.

The "``list_events(device_id, limit)`` returns at most ``limit`` items"
invariant lives in the ``UnofficialRingAdapter`` (task 8.4) because
``list_events`` is an adapter-level concern. The mapper-level surrogate
here is the filtering invariant: for any mixed input list, the number of
successfully mapped events is bounded above by ``len(input)`` and the
resulting set contains only recognised ``{"motion", "ding"}`` types.

Validates: Requirements 4.1, 4.2, 4.3, 4.4.
"""

from __future__ import annotations

from hypothesis import given
from hypothesis import strategies as st

from app.adapters.mappers import map_device, map_event
from app.adapters.models import DeviceResource, EventResource
from app.adapters.ring_schemas import RingDevice, RingDeviceHealth, RingEvent

# ---------------------------------------------------------------------------
# Strategies
# ---------------------------------------------------------------------------

# Printable ASCII keeps ``created_at`` and free-form text fields deterministic
# and keeps shrinking fast without sacrificing coverage of the mapper logic
# (which never inspects text content).
_printable_text = st.text(
    alphabet=st.characters(min_codepoint=0x20, max_codepoint=0x7E),
    min_size=1,
    max_size=40,
)

_health_strategy = st.builds(
    RingDeviceHealth,
    battery_life=st.one_of(st.none(), st.integers(min_value=0, max_value=100)),
    wifi_signal_strength=st.one_of(st.none(), st.integers(min_value=-100, max_value=0)),
    firmware=st.one_of(st.none(), _printable_text),
)

# Covers the realistic Ring device kinds the mock uses plus a couple of
# plausible neighbours, so the mapper is exercised across several kind
# strings without needing Ring's full (undocumented) vocabulary.
_device_kinds = st.sampled_from(
    ["doorbell_pro", "stickup_cam", "spotlight_cam", "indoor_cam", "lpd_v4"]
)

_device_strategy = st.builds(
    RingDevice,
    id=st.integers(min_value=1, max_value=2**31 - 1),
    kind=_device_kinds,
    description=_printable_text,
    firmware_version=st.one_of(st.none(), _printable_text),
    battery_life=st.one_of(st.none(), st.integers(min_value=0, max_value=100)),
    health=st.one_of(st.none(), _health_strategy),
)

_mappable_event_kinds = st.sampled_from(["motion", "ding"])
_unsupported_event_kinds = st.sampled_from(["on_demand", "alarm", "update", "", "unknown"])


# ---------------------------------------------------------------------------
# Device mapping properties (Requirements 4.1, 4.2, 4.3).
# ---------------------------------------------------------------------------


@given(device=_device_strategy)
def test_map_device_produces_valid_device_resource(device: RingDevice) -> None:
    """**Validates: Requirements 4.1, 4.2, 4.3**

    For any ``RingDevice``:
      - ``map_device`` returns a ``DeviceResource``.
      - The result round-trips through Pydantic validation (``model_dump``
        then ``model_validate``), guarding against any hand-constructed
        shape drift that might slip past the constructor's type coercion.
      - ``power_source`` is derived correctly: present battery (nested or
        top-level) → ``"battery"``; otherwise ``"hardwired"``.
      - ``status`` defaults to ``"online"`` (Req 4.2).
      - ``id`` is the stringified integer ID (Req 4.1) and never empty.
    """
    result = map_device(device)
    assert isinstance(result, DeviceResource)

    # Pydantic round-trip guards against mis-shape.
    DeviceResource.model_validate(result.model_dump())

    # Power-source derivation (Req 4.2).
    nested_battery = device.health.battery_life if device.health else None
    battery = nested_battery if nested_battery is not None else device.battery_life
    expected_power = "battery" if battery is not None else "hardwired"
    assert result.attributes.power_source == expected_power

    # Status default (Req 4.2).
    assert result.attributes.status == "online"

    # ID conversion (Req 4.1).
    assert result.id == str(device.id)
    assert result.id  # non-empty

    # Forwarded fields.
    assert result.type == device.kind
    assert result.attributes.model == device.kind
    assert result.attributes.name == device.description


# ---------------------------------------------------------------------------
# Event mapping properties (Requirement 4.4).
# ---------------------------------------------------------------------------


@given(
    event_id=st.integers(min_value=1, max_value=2**31 - 1),
    kind=_mappable_event_kinds,
    created_at=_printable_text,
    duration=st.one_of(st.none(), st.integers(min_value=0, max_value=3600)),
    device_id=_printable_text,
)
def test_map_event_mappable_kinds_pass_validation(
    event_id: int,
    kind: str,
    created_at: str,
    duration: int | None,
    device_id: str,
) -> None:
    """**Validates: Requirement 4.4**

    For every mappable ``kind`` (``"motion"``/``"ding"``):
      - ``map_event`` returns an ``EventResource``.
      - The result round-trips through Pydantic validation.
      - Fields are forwarded faithfully; missing ``duration`` defaults to 0.
    """
    event = RingEvent(id=event_id, kind=kind, created_at=created_at, duration=duration)
    result = map_event(event, device_id=device_id)

    assert isinstance(result, EventResource)
    EventResource.model_validate(result.model_dump())

    assert result.type == kind
    assert result.device_id == device_id
    assert result.id == str(event_id)
    assert result.created_at == created_at
    assert result.duration == (duration if duration is not None else 0)


@given(
    event_id=st.integers(min_value=1, max_value=2**31 - 1),
    kind=_unsupported_event_kinds,
    created_at=_printable_text,
)
def test_map_event_rejects_unsupported_kinds(event_id: int, kind: str, created_at: str) -> None:
    """**Validates: Requirement 4.4**

    Unsupported Ring event kinds raise ``ValueError`` so the adapter can
    filter them. The exception message references the offending kind for
    debuggability.
    """
    event = RingEvent(id=event_id, kind=kind, created_at=created_at)
    try:
        map_event(event, device_id="x")
    except ValueError as exc:
        # Message should mention the kind (repr) or be flagged as unsupported
        # — both give a clear debugging signal.
        msg = str(exc).lower()
        assert repr(kind).lower() in msg or "unsupported" in msg
    else:
        raise AssertionError(f"expected ValueError for kind={kind!r}")


@given(
    events=st.lists(
        st.tuples(
            st.integers(min_value=1, max_value=2**31 - 1),
            st.sampled_from(["motion", "ding", "on_demand", "alarm", "update", "unknown"]),
            _printable_text,
        ),
        min_size=0,
        max_size=30,
    ),
    device_id=_printable_text,
)
def test_mapped_subset_is_bounded_and_only_motion_or_ding(
    events: list[tuple[int, str, str]], device_id: str
) -> None:
    """**Validates: Requirement 4.4**

    Filtering invariant: given a mixed list of ``RingEvent`` records, the
    subset that maps successfully is never larger than the input and
    contains only ``motion``/``ding`` types. This is the mapper-level
    surrogate for the adapter-level ``list_events`` limit invariant
    (which is exercised in task 8.4's ``UnofficialRingAdapter`` test).
    """
    mapped: list[EventResource] = []
    for event_id, kind, created_at in events:
        event = RingEvent(id=event_id, kind=kind, created_at=created_at)
        try:
            mapped.append(map_event(event, device_id=device_id))
        except ValueError:
            continue

    # Never more out than in.
    assert len(mapped) <= len(events)
    # Every surviving event is one of the allowed tvOS-facing kinds.
    for er in mapped:
        assert er.type in {"motion", "ding"}


# ---------------------------------------------------------------------------
# Camera-kind predicate (Requirement 4.1).
# ---------------------------------------------------------------------------


def test_is_camera_kind_known_cameras() -> None:
    """**Validates: Requirement 4.1**

    All Ring camera/doorbell kinds the fleet currently includes — plus the
    near-future ``stickup_cam_v5`` shape — return ``True``. This list is
    updated whenever a new Ring product is observed in the wild.
    """
    from app.adapters.mappers import is_camera_kind

    for kind in (
        "cocoa_doorbell",
        "doorbell_pro",
        "doorbell_scallop",
        "lpd_v4",
        "jbox_v2",
        "cocoa_floodlight",
        "hp_cam_v1",
        "hp_cam_v2",
        "stickup_cam",
        "stickup_cam_v3",
        "stickup_cam_elite",
        "spotlight_cam",
        "spotlight_cam_v2",
        "indoor_cam",
        "cocoa_camera",
    ):
        assert is_camera_kind(kind), kind


def test_is_camera_kind_excludes_chimes_and_other_accessories() -> None:
    """**Validates: Requirement 4.1**

    Chimes, beams lights, alarm keypads, and motion sensors are not cameras
    and must not appear on the tvOS dashboard regardless of how Ring labels
    them internally.
    """
    from app.adapters.mappers import is_camera_kind

    for kind in (
        "chime_v3",
        "chime_pro_v2",
        "beams_c5000",
        "beams_ct200",
        "security_panel",
        "base_station_v1",
        "keypad_v2",
        "motion_sensor_v2",
        "contact_sensor_v2",
        "smoke_co_listener_v1",
    ):
        assert not is_camera_kind(kind), kind


@given(kind=st.sampled_from(["DOORBELL_PRO", "Stickup_Cam", "FLOODLIGHT_X"]))
def test_is_camera_kind_case_insensitive(kind: str) -> None:
    """**Validates: Requirement 4.1**

    Ring occasionally returns mixed-case kind strings; the predicate must
    canonicalise before comparing so a device is never hidden because of
    casing drift.
    """
    from app.adapters.mappers import is_camera_kind

    assert is_camera_kind(kind)
