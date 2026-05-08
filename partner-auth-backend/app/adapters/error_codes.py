"""Stable machine-readable error codes for Ring adapter errors.

These string values are the single source of truth for the ``code`` field in
HTTP error envelopes. They are shared by the `RingAdapterError` hierarchy and
any client that needs to branch on specific failure modes.
"""

from enum import StrEnum


class ErrorCode(StrEnum):
    """Machine-readable error codes returned in HTTP error envelopes.

    ``StrEnum`` members are also ``str`` instances, so
    ``ErrorCode.UPSTREAM_ERROR == "upstream_error"`` holds and JSON
    serialization yields the raw string value.
    """

    ADAPTER_MISCONFIGURED = "adapter_misconfigured"
    AUTHENTICATION_REQUIRED = "authentication_required"
    UPSTREAM_ERROR = "upstream_error"
    UPSTREAM_TIMEOUT = "upstream_timeout"
    RATE_LIMITED = "rate_limited"
    DEVICE_NOT_FOUND = "device_not_found"
    SUBSCRIPTION_REQUIRED = "subscription_required"
    SNAPSHOT_UNAVAILABLE = "snapshot_unavailable"
    STREAM_CAPACITY_EXCEEDED = "stream_capacity_exceeded"
    SESSION_NOT_FOUND = "session_not_found"
