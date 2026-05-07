"""Exception hierarchy for Ring adapter failures.

Each subclass carries a stable ``code`` (from `ErrorCode`) and an
``http_status`` that the routing layer translates into an HTTP error
envelope. The ``message`` field is for server-side logging only and MUST
NOT be echoed to clients.
"""

from app.adapters.error_codes import ErrorCode


class RingAdapterError(Exception):
    """Base class for all Ring adapter failures.

    Subclasses override ``code`` and ``http_status`` to describe a specific
    failure mode. ``message`` is an optional human-readable string used for
    logs; it is never returned in HTTP responses.
    """

    code: str = ""
    http_status: int = 500

    def __init__(self, message: str = "") -> None:
        super().__init__(message)
        self.message = message


class AdapterConfigurationError(RingAdapterError):
    """The adapter is missing required configuration (500)."""

    code = ErrorCode.ADAPTER_MISCONFIGURED
    http_status = 500


class AuthenticationRequiredError(RingAdapterError):
    """Upstream credentials are missing, expired, or rejected (401)."""

    code = ErrorCode.AUTHENTICATION_REQUIRED
    http_status = 401


class UpstreamUnavailableError(RingAdapterError):
    """Upstream Ring service returned an error or was unreachable (502)."""

    code = ErrorCode.UPSTREAM_ERROR
    http_status = 502


class UpstreamTimeoutError(RingAdapterError):
    """Upstream Ring service did not respond within the deadline (504)."""

    code = ErrorCode.UPSTREAM_TIMEOUT
    http_status = 504


class RateLimitedError(RingAdapterError):
    """Upstream applied a rate limit to the request (429)."""

    code = ErrorCode.RATE_LIMITED
    http_status = 429


class DeviceNotFoundError(RingAdapterError):
    """Requested device does not exist or is not visible to the account (404)."""

    code = ErrorCode.DEVICE_NOT_FOUND
    http_status = 404


class SubscriptionRequiredError(RingAdapterError):
    """Operation requires a Ring Protect subscription the account lacks (402)."""

    code = ErrorCode.SUBSCRIPTION_REQUIRED
    http_status = 402


class SnapshotUnavailableError(RingAdapterError):
    """No snapshot is currently available for the device (503)."""

    code = ErrorCode.SNAPSHOT_UNAVAILABLE
    http_status = 503


class StreamCapacityExceededError(RingAdapterError):
    """Too many concurrent stream sessions for the device or account (429)."""

    code = ErrorCode.STREAM_CAPACITY_EXCEEDED
    http_status = 429


class StreamSessionNotFoundError(RingAdapterError):
    """Referenced stream session does not exist or has already ended (404)."""

    code = ErrorCode.SESSION_NOT_FOUND
    http_status = 404
