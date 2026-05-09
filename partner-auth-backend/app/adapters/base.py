"""Abstract base class for Ring adapters.

Every `/mock/*` route depends on a single `RingAdapter` instance that is
selected at startup (see the ring-adapter-backend design document). Concrete
implementations (`MockRingAdapter`, `UnofficialRingAdapter`) live alongside
this module.
"""

from abc import ABC, abstractmethod
from typing import NamedTuple


class SnapshotPayload(NamedTuple):
    """Binary snapshot returned by `RingAdapter.download_snapshot`."""

    content: bytes
    content_type: str  # "image/png" or "image/jpeg"


class StreamSessionResult(NamedTuple):
    """Result of `RingAdapter.create_stream_session`."""

    sdp_answer: str
    location: str  # value for the WHEP "Location" response header
    session_id: str  # backend-generated UUID


class RingAdapter(ABC):
    """Abstract interface for all Ring-facing operations.

    All methods that perform I/O are asynchronous. `mode()` is synchronous
    and returns a stable identifier such as ``"mock"`` or ``"unofficial"``.
    """

    @abstractmethod
    async def list_devices(self) -> dict:
        """Return the device list in JSON:API shape.

        Shape: ``{"data": [{"id": ..., "type": ..., "attributes": {...}}, ...]}``.
        """

    @abstractmethod
    async def list_events(self, device_id: str, limit: int) -> list[dict]:
        """Return up to ``limit`` recent events for ``device_id``."""

    @abstractmethod
    async def download_snapshot(self, device_id: str) -> SnapshotPayload:
        """Return the most recent snapshot for ``device_id``."""

    @abstractmethod
    async def download_video(self, device_id: str, event_id: str | None) -> dict:
        """Return a signed clip URL.

        Shape: ``{"url": "..."}``. When ``event_id`` is ``None`` the adapter
        returns the latest available clip for ``device_id``.
        """

    @abstractmethod
    async def create_stream_session(self, device_id: str, sdp_offer: str) -> StreamSessionResult:
        """Create a WHEP stream session for ``device_id`` from an SDP offer."""

    @abstractmethod
    async def delete_stream_session(self, session_id: str) -> None:
        """Tear down the stream session identified by ``session_id``."""

    @abstractmethod
    def mode(self) -> str:
        """Stable identifier for this implementation, e.g. ``"mock"`` or ``"unofficial"``."""
