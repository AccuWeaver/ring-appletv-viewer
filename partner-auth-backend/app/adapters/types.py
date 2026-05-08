"""Internal dataclasses shared across Ring adapter implementations.

These types are used by `RingConsumerClient` (for access-token caching) and
`StreamSessionMap` (for tracking live WHEP sessions). They are deliberately
kept free of any HTTP or JSON:API shape concerns so they can be reused by
both the unofficial and mock adapters.
"""

from dataclasses import dataclass
from typing import Literal

StreamSessionState = Literal["active", "terminated"]
"""Lifecycle state of a `StreamSession`.

A session is ``"active"`` from the moment it is bound in `StreamSessionMap`
until `delete_stream_session` completes successfully, at which point it
transitions to ``"terminated"`` before being removed from the map.
"""


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


@dataclass(slots=True)
class StreamSession:
    """Live WHEP stream session tracked by `StreamSessionMap`.

    The ``state`` field is mutable so the adapter can mark a session as
    terminated before removing it from the map (see design doc section on
    `StreamSessionMap`).

    Attributes:
        session_id: Backend-generated UUID v4; this is the identifier exposed
            to tvOS via the WHEP ``Location`` header.
        bridge_session_id: Opaque ID returned by the Node sidecar; used when
            calling the sidecar's ``DELETE /sessions/{id}`` endpoint.
        device_id: Ring device ID this session is streaming from.
        mediamtx_path: MediaMTX path the session is published to, e.g.
            ``"ring/<device_id>"``.
        created_at: Session creation time as unix epoch seconds.
        state: Lifecycle state; see `StreamSessionState`.
        has_audio: Whether the negotiated SDP answer includes an audio track.
    """

    session_id: str
    bridge_session_id: str
    device_id: str
    mediamtx_path: str
    created_at: float
    state: StreamSessionState
    has_audio: bool
