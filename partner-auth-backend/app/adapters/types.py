"""Internal dataclasses shared across Ring adapter implementations.

These types are used by `RingConsumerClient` (for access-token caching) and
`StreamSessionMap` (for tracking live WHEP sessions). They are deliberately
kept free of any HTTP or JSON:API shape concerns so they can be reused by
both the unofficial and mock adapters.
"""

from dataclasses import dataclass
from typing import Literal

StreamSessionState = Literal["active", "terminated"]
"""Lifecycle state of a stream session.

A session is ``"active"`` from the moment it is bound in `StreamSessionMap`
until `delete_stream_session` completes successfully, at which point it
transitions to ``"terminated"`` before being removed from the map.
"""

StreamSessionMode = Literal["partner", "unofficial", "mock"]
"""Adapter mode that originated a stream session."""


@dataclass(frozen=True, slots=True)
class AccessTokenCacheEntry:
    """Cached Ring access token returned by `RingConsumerClient`.

    Attributes:
        token: The opaque bearer token to send in ``Authorization`` headers.
        expires_at: Absolute expiry time as unix epoch seconds (``time.time()``
            semantics). `RingConsumerClient._refresh()` computes this as
            ``time.time() + expires_in``.
    """

    token: str
    expires_at: float


# ---------------------------------------------------------------------------
# Tagged union session types
# ---------------------------------------------------------------------------


@dataclass(slots=True)
class BaseStreamSession:
    """Common fields for all session types.

    The ``state`` field is mutable so the adapter can mark a session as
    terminated before removing it from the map.

    Attributes:
        session_id: Backend-generated UUID v4; this is the identifier exposed
            to tvOS via the WHEP ``Location`` header.
        device_id: Ring device ID this session is streaming from.
        created_at: Session creation time as unix epoch seconds.
        state: Lifecycle state; see `StreamSessionState`.
        source_mode: Adapter mode that originated this session.
    """

    session_id: str
    device_id: str
    created_at: float
    state: StreamSessionState = "active"
    source_mode: StreamSessionMode = "mock"


@dataclass(slots=True)
class PartnerStreamSession(BaseStreamSession):
    """Partner API WHEP session.

    Attributes:
        partner_session_url: The ``Location`` header value returned by the
            Partner API on WHEP session creation; used for DELETE teardown.
    """

    source_mode: Literal["partner"] = "partner"
    partner_session_url: str = ""


@dataclass(slots=True)
class UnofficialStreamSession(BaseStreamSession):
    """Unofficial SIP→RTSP session via ring-sip-bridge and mediamtx.

    Attributes:
        bridge_session_id: Opaque ID returned by the Node sidecar; used when
            calling the sidecar's ``DELETE /sessions/{id}`` endpoint.
        mediamtx_path: MediaMTX path the session is published to, e.g.
            ``"ring/<device_id>"``.
        has_audio: Whether the negotiated SDP answer includes an audio track.
    """

    source_mode: Literal["unofficial"] = "unofficial"
    bridge_session_id: str = ""
    mediamtx_path: str = ""
    has_audio: bool = False


@dataclass(slots=True)
class MockStreamSession(BaseStreamSession):
    """Mock WHEP session (mediamtx test pattern)."""

    source_mode: Literal["mock"] = "mock"


# Backward-compatible alias: the original StreamSession is now
# UnofficialStreamSession. Existing code that imports StreamSession
# continues to work.
StreamSession = UnofficialStreamSession
