"""Ring adapter package.

Exposes the `RingAdapter` ABC and its associated result types, the shared
error code enum and exception hierarchy used by every concrete adapter
implementation, and the Pydantic models that describe the adapter-facing
JSON:API shapes emitted to the tvOS app.
"""

from app.adapters.base import RingAdapter, SnapshotPayload, StreamSessionResult
from app.adapters.error_codes import ErrorCode
from app.adapters.errors import (
    AdapterConfigurationError,
    AuthenticationRequiredError,
    DeviceNotFoundError,
    RateLimitedError,
    RingAdapterError,
    SnapshotUnavailableError,
    StreamCapacityExceededError,
    StreamSessionNotFoundError,
    SubscriptionRequiredError,
    UpstreamTimeoutError,
    UpstreamUnavailableError,
)
from app.adapters.models import (
    DeviceAttributes,
    DeviceResource,
    DeviceStatus,
    EventResource,
    EventType,
    PowerSource,
)
from app.adapters.ring_schemas import (
    RingDevice,
    RingDeviceHealth,
    RingEvent,
    RingOAuthTokenResponse,
)
from app.adapters.types import (
    AccessTokenCacheEntry,
    StreamSession,
    StreamSessionState,
)

__all__ = [
    "AccessTokenCacheEntry",
    "AdapterConfigurationError",
    "AuthenticationRequiredError",
    "DeviceAttributes",
    "DeviceNotFoundError",
    "DeviceResource",
    "DeviceStatus",
    "ErrorCode",
    "EventResource",
    "EventType",
    "PowerSource",
    "RateLimitedError",
    "RingAdapter",
    "RingAdapterError",
    "RingDevice",
    "RingDeviceHealth",
    "RingEvent",
    "RingOAuthTokenResponse",
    "SnapshotPayload",
    "SnapshotUnavailableError",
    "StreamCapacityExceededError",
    "StreamSession",
    "StreamSessionNotFoundError",
    "StreamSessionResult",
    "StreamSessionState",
    "SubscriptionRequiredError",
    "UpstreamTimeoutError",
    "UpstreamUnavailableError",
]
