"""Pydantic models describing the adapter-facing JSON:API shapes.

These are the strict, tvOS-facing contracts produced by every `RingAdapter`
implementation (see `app/adapters/base.py`). Both `MockRingAdapter` and
`UnofficialRingAdapter` ultimately return values that validate against these
schemas, so the wire shape consumed by the tvOS app is identical regardless
of which adapter is active.

Strictness:
    - `extra="forbid"` is set on every model so accidental additions on the
      adapter side surface as validation errors during development rather
      than leaking undocumented fields to the client.
    - Enumerable attribute values (`power_source`, `status`, event `type`)
      are constrained to `Literal` unions matching Requirements 4.2 and 4.4.

The permissive, defensive Ring-consumer-API schemas (``RingDevice``,
``RingEvent``, ...) live in `app/adapters/ring_schemas.py` and are
deliberately the opposite: they tolerate unknown fields so minor Ring
response changes do not break the adapter.
"""

from typing import Literal

from pydantic import BaseModel, ConfigDict

PowerSource = Literal["hardwired", "battery"]
"""Power-source classification exposed to tvOS.

Matches the two values observed in the existing mock devices (see
``MOCK_DEVICES`` in `app/routes/mock_ring_api.py`) and required by
Requirement 4.2. The `UnofficialRingAdapter` mapper derives this from the
Ring consumer API's ``battery_life`` field: present implies ``"battery"``,
absent implies ``"hardwired"``.
"""

DeviceStatus = Literal["online", "offline"]
"""Device reachability state exposed to tvOS, per Requirement 4.2."""

EventType = Literal["motion", "ding"]
"""Event kinds the tvOS app recognises, per Requirement 4.4."""


class DeviceAttributes(BaseModel):
    """JSON:API ``attributes`` block for a device resource.

    The field set mirrors the mock adapter output exactly so the tvOS app
    cannot distinguish mock from unofficial responses by shape.
    """

    model_config = ConfigDict(extra="forbid")

    name: str
    model: str
    firmware_version: str
    power_source: PowerSource
    status: DeviceStatus


class DeviceResource(BaseModel):
    """JSON:API device resource returned by ``RingAdapter.list_devices()``.

    ``type`` is the Ring "kind" string (e.g. ``"doorbell_pro"``,
    ``"spotlight_cam"``, ``"stickup_cam"``). It is intentionally not
    ``Literal``-constrained because Ring defines many device kinds and new
    ones may appear; the mapper forwards whatever Ring returns.
    """

    model_config = ConfigDict(extra="forbid")

    id: str
    type: str
    attributes: DeviceAttributes


class EventResource(BaseModel):
    """Event record returned by ``RingAdapter.list_events()``.

    ``created_at`` is kept as a plain ISO 8601 string rather than a
    ``datetime`` because the mock generates values via ``datetime.isoformat()``
    and the tvOS client parses the string directly; converting through
    `datetime` would risk round-trip formatting drift.
    """

    model_config = ConfigDict(extra="forbid")

    id: str
    device_id: str
    type: EventType
    created_at: str
    duration: int
