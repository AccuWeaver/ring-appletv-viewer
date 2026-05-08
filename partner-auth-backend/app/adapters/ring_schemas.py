"""Permissive Pydantic models for Ring consumer API responses.

These models describe the **raw wire shapes** returned by Ring's consumer
API (``https://api.ring.com``) and OAuth endpoint
(``https://oauth.ring.com/oauth/token``). They are consumed by the
``RingConsumerClient`` (task 6.1) and by the mappers used inside the
``UnofficialRingAdapter`` (task 5.2), which translate them into the strict
tvOS-facing ``DeviceResource`` / ``EventResource`` models defined in
`app/adapters/models.py`.

Design intent:
    - Every model sets ``extra="ignore"``. This is the deliberate
      complement to the ``extra="forbid"`` policy used in `models.py`:
      Ring's consumer API is undocumented and may grow new fields at any
      time, so the adapter tolerates unknowns at the inbound boundary and
      only enforces strictness on the outbound, tvOS-facing contracts.
    - Fields that Ring sometimes omits (firmware version, battery level on
      hardwired devices, event ``duration`` for in-progress events, rotated
      refresh tokens, etc.) are typed as ``| None`` with a ``None`` default
      so parsing does not fail on minor response variations.
    - ``kind`` on both devices and events is a free-form ``str`` rather than
      a ``Literal`` union; Ring defines many device kinds and event kinds
      and new ones appear regularly. The mapper layer is responsible for
      translating / filtering these into the constrained tvOS vocabulary.
"""

from pydantic import BaseModel, ConfigDict


class RingDeviceHealth(BaseModel):
    """Nested ``health`` sub-object returned inside a Ring device payload.

    Ring reports battery and signal health here for devices that support
    it. Hardwired devices typically omit ``battery_life``; older firmware
    payloads may omit every field, so all three are optional.
    """

    model_config = ConfigDict(extra="ignore")

    battery_life: int | None = None
    wifi_signal_strength: int | None = None
    firmware: str | None = None


class RingDevice(BaseModel):
    """Raw device record from Ring's consumer API.

    Ring uses integer device IDs in the consumer API (the tvOS-facing
    `DeviceResource.id` is a string; the mapper converts). ``description``
    is the user-assigned camera name (e.g. "Front Door"). ``battery_life``
    appears both at the top level and nested inside ``health`` in many
    Ring responses; the mapper prefers the nested value when both are
    present.
    """

    model_config = ConfigDict(extra="ignore")

    id: int
    kind: str
    description: str
    firmware_version: str | None = None
    battery_life: int | None = None
    health: RingDeviceHealth | None = None


class RingEvent(BaseModel):
    """Raw event record from Ring's consumer API history endpoint.

    ``kind`` is the raw Ring event kind (``"motion"``, ``"ding"``,
    ``"alarm"``, ``"on_demand"``, ...). The mapper translates the subset
    the tvOS app understands and filters the rest. ``duration`` may be
    absent for events still in progress at the time of the API call.
    """

    model_config = ConfigDict(extra="ignore")

    id: int
    kind: str
    created_at: str
    duration: int | None = None


class RingOAuthTokenResponse(BaseModel):
    """Response body from ``POST https://oauth.ring.com/oauth/token``.

    Ring's refresh-token rotation is opportunistic: successful exchanges
    may or may not return a new ``refresh_token``. When absent, the caller
    must continue using the previously stored refresh token. ``scope`` is
    also optional; Ring does not always echo it back.
    """

    model_config = ConfigDict(extra="ignore")

    access_token: str
    token_type: str
    expires_in: int
    refresh_token: str | None = None
    scope: str | None = None
