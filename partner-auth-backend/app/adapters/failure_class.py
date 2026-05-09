"""Failure classification for adapter operation routing decisions.

Each adapter failure is assigned a FailureClass that the Source_Router uses
to decide whether to fall back to the next source or return immediately.
"""

from enum import StrEnum


class FailureClass(StrEnum):
    """Classification of adapter operation failures for routing decisions."""

    CONFIGURATION = "configuration"
    AUTHENTICATION = "authentication"
    UPSTREAM_UNAVAILABLE = "upstream_unavailable"
    UPSTREAM_TIMEOUT = "upstream_timeout"
    NOT_FOUND = "not_found"
    SUBSCRIPTION_REQUIRED = "subscription_required"
    RATE_LIMITED = "rate_limited"
    CAPACITY_EXCEEDED = "capacity_exceeded"
    SNAPSHOT_UNAVAILABLE = "snapshot_unavailable"
    INTERNAL = "internal"


# Failures that permit fallback to the next source
FALLBACK_ELIGIBLE: frozenset[FailureClass] = frozenset(
    {
        FailureClass.UPSTREAM_UNAVAILABLE,
        FailureClass.UPSTREAM_TIMEOUT,
    }
)

# For snapshot operations only, snapshot_unavailable is also fallback-eligible
SNAPSHOT_FALLBACK_ELIGIBLE: frozenset[FailureClass] = FALLBACK_ELIGIBLE | {
    FailureClass.SNAPSHOT_UNAVAILABLE,
}
