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
from app.adapters.failure_class import (
    FALLBACK_ELIGIBLE,
    SNAPSHOT_FALLBACK_ELIGIBLE,
    FailureClass,
)
from app.adapters.models import (
    DeviceAttributes,
    DeviceResource,
    DeviceStatus,
    EventResource,
    EventType,
    PowerSource,
)
from app.adapters.partner import PartnerRingAdapter
from app.adapters.ring_schemas import (
    RingDevice,
    RingDeviceHealth,
    RingEvent,
    RingOAuthTokenResponse,
)
from app.adapters.types import (
    AccessTokenCacheEntry,
    BaseStreamSession,
    MockStreamSession,
    PartnerStreamSession,
    StreamSession,
    StreamSessionMode,
    StreamSessionState,
    UnofficialStreamSession,
)

__all__ = [
    "AccessTokenCacheEntry",
    "AdapterConfigurationError",
    "PartnerRingAdapter",
    "AuthenticationRequiredError",
    "BaseStreamSession",
    "DeviceAttributes",
    "DeviceNotFoundError",
    "DeviceResource",
    "DeviceStatus",
    "ErrorCode",
    "EventResource",
    "EventType",
    "FALLBACK_ELIGIBLE",
    "FailureClass",
    "MockStreamSession",
    "PartnerStreamSession",
    "PowerSource",
    "RateLimitedError",
    "RingAdapter",
    "RingAdapterError",
    "RingDevice",
    "RingDeviceHealth",
    "RingEvent",
    "RingOAuthTokenResponse",
    "SNAPSHOT_FALLBACK_ELIGIBLE",
    "SnapshotPayload",
    "SnapshotUnavailableError",
    "StreamCapacityExceededError",
    "StreamSession",
    "StreamSessionMode",
    "StreamSessionNotFoundError",
    "StreamSessionResult",
    "StreamSessionState",
    "SubscriptionRequiredError",
    "UnofficialStreamSession",
    "UpstreamTimeoutError",
    "UpstreamUnavailableError",
]
