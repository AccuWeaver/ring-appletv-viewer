"""Mappers from Ring consumer API schemas to the adapter-facing JSON:API shape.

The permissive inbound models (`RingDevice`, `RingEvent`) live in
`app/adapters/ring_schemas.py`; the strict outbound models (`DeviceResource`,
`EventResource`) live in `app/adapters/models.py`. These pure functions
bridge the two.

Design notes
------------

power_source derivation (Requirement 4.2)
    Ring's consumer API reports ``battery_life`` either at the top level of
    a device payload or inside ``health``. The mapper prefers the nested
    value (Ring populates it more reliably) and falls back to the
    top-level field. A present non-null value implies a battery-powered
    device; any other case is treated as ``"hardwired"``.

status default (Requirement 4.2)
    Ring does not consistently expose an ``online``/``offline`` flag on
    every response. When missing, the mapper defaults to ``"online"`` so
    the tvOS app can see the device. Health-based offline detection would
    require an additional API call we do not yet make.

firmware_version fallback (Requirement 4.2)
    Prefer ``RingDevice.firmware_version``; if absent fall back to
    ``health.firmware`` if present; otherwise use the sentinel ``"unknown"``.

Camera-kind filtering (Requirement 4.1)
    The tvOS app's device list is intended to show "the user's cameras and
    doorbells" — not chimes, base stations, keypads, or other non-camera
    accessories. ``is_camera_kind`` encodes that rule against the Ring
    consumer API's ``kind`` field. The list is deliberately a
    permissive allow-pattern (everything containing ``doorbell``, ``cam``,
    ``floodlight``, or ``spotlight``) rather than a deny-list, so future
    Ring product introductions default to being shown and can be
    tightened after manual testing. Known non-camera kinds (``chime_*``,
    ``beams_*``, ``security_*``) are explicitly excluded.

Event kind filtering (Requirement 4.4)
    The adapter-facing ``EventResource.type`` is restricted to
    ``"motion"`` and ``"ding"``. The mapper raises ``ValueError`` for any
    other ``RingEvent.kind`` so callers (the adapter) can filter these
    out — that's simpler than returning ``None`` and adds a clear error
    path for debugging unexpected Ring kinds.

Duration default (Requirement 4.4)
    When Ring omits ``duration`` (event in progress), the mapper uses
    ``0`` to satisfy the strict ``EventResource.duration: int`` contract.
"""

from app.adapters.models import DeviceAttributes, DeviceResource, EventResource
from app.adapters.ring_schemas import RingDevice, RingEvent

_MAPPABLE_EVENT_KINDS: frozenset[str] = frozenset({"motion", "ding"})
_UNKNOWN_FIRMWARE: str = "unknown"

# Substrings that identify a Ring device kind as having a camera. Checked
# case-insensitively against ``RingDevice.kind``. Anything matching is
# considered a camera; anything explicitly in ``_NON_CAMERA_KIND_PREFIXES``
# is rejected first so a future ``beams_doorbell`` hybrid would still be
# excluded if it ever existed. The allow-list deliberately leans
# permissive — if Ring ships a new ``stickup_cam_v5`` we'd rather show it
# by default than silently hide it.
_CAMERA_KIND_SUBSTRINGS: tuple[str, ...] = (
    "doorbell",
    "cam",         # covers ``stickup_cam``, ``spotlight_cam``, ``indoor_cam``, ``cocoa_cam``, ...
    "floodlight",  # covers ``cocoa_floodlight`` and the older ``hp_cam_v2`` family
    "spotlight",
    "lpd_",        # ``lpd_v1``/``lpd_v4`` — Lighted Peephole Doorbell
    "jbox_",       # ``jbox_v1``/``jbox_v2`` — junction-box doorbell chassis
)
_NON_CAMERA_KIND_PREFIXES: tuple[str, ...] = (
    "chime_",
    "beams_",       # outdoor smart lighting; no camera
    "security_",    # alarm base stations, keypads
    "base_station_",
    "keypad_",
    "rangextender_",
    "motion_sensor_",
    "contact_sensor_",
    "smoke_co_listener_",
    "flood_freeze_sensor_",
    "tilt_sensor_",
)


def is_camera_kind(kind: str) -> bool:
    """Return ``True`` if the Ring ``kind`` identifies a camera-bearing device.

    The adapter uses this to filter ``list_devices()`` down to devices the
    tvOS app can meaningfully display (Req 4.1). Case-insensitive.

    >>> is_camera_kind("cocoa_doorbell")
    True
    >>> is_camera_kind("stickup_cam_v3")
    True
    >>> is_camera_kind("chime_v3")
    False
    >>> is_camera_kind("chime_pro_v2")
    False
    """
    k = kind.lower()
    if any(k.startswith(prefix) for prefix in _NON_CAMERA_KIND_PREFIXES):
        return False
    return any(substr in k for substr in _CAMERA_KIND_SUBSTRINGS)


def map_device(device: RingDevice) -> DeviceResource:
    """Translate a Ring consumer API device record into a tvOS-facing resource."""
    # Prefer nested battery_life; fall back to top-level.
    nested_battery = device.health.battery_life if device.health else None
    battery = nested_battery if nested_battery is not None else device.battery_life
    power_source = "battery" if battery is not None else "hardwired"

    firmware = (
        device.firmware_version
        or (device.health.firmware if device.health else None)
        or _UNKNOWN_FIRMWARE
    )

    return DeviceResource(
        id=str(device.id),
        type=device.kind,
        attributes=DeviceAttributes(
            name=device.description,
            model=device.kind,
            firmware_version=firmware,
            power_source=power_source,
            status="online",
        ),
    )


def map_event(event: RingEvent, device_id: str) -> EventResource:
    """Translate a Ring consumer API event into a tvOS-facing resource.

    Raises:
        ValueError: when ``event.kind`` is not a recognised tvOS event type.
            The caller is expected to filter these (e.g. ``on_demand``,
            ``alarm``) out of the adapter's ``list_events`` result.
    """
    if event.kind not in _MAPPABLE_EVENT_KINDS:
        raise ValueError(f"unsupported ring event kind: {event.kind!r}")

    return EventResource(
        id=str(event.id),
        device_id=device_id,
        type=event.kind,  # type: ignore[arg-type]  # narrowed by the membership check above
        created_at=event.created_at,
        duration=event.duration if event.duration is not None else 0,
    )
