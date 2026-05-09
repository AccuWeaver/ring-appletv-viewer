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


class HLSStreamSessionResult(NamedTuple):
    """Result of `RingAdapter.create_hls_stream_session`.

    Returned only by adapters that can route a live feed through mediamtx
    so HLS clients (notably the tvOS simulator) can subscribe. The
    ``session_id`` is the same identifier used by
    ``delete_stream_session`` so the teardown contract is uniform.
    """

    hls_url: str
    session_id: str


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

    async def create_hls_stream_session(self, device_id: str) -> HLSStreamSessionResult:
        """Create an HLS stream session for ``device_id``.

        Concrete adapters that can republish a live feed via mediamtx
        override this. The default implementation signals "not supported"
        by raising so the route layer maps it to 501.
        """
        raise NotImplementedError(
            f"{self.__class__.__name__} does not support HLS stream sessions"
        )

    @abstractmethod
    async def delete_stream_session(self, session_id: str) -> None:
        """Tear down the stream session identified by ``session_id``."""

    @abstractmethod
    def mode(self) -> str:
        """Stable identifier for this implementation, e.g. ``"mock"`` or ``"unofficial"``."""
