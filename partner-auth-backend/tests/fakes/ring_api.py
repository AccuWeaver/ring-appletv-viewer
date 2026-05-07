"""Fake Ring consumer API for integration tests.

Provides a ``build_ring_api_transport`` helper that returns an
``httpx.MockTransport`` serving the subset of Ring's consumer API the
``UnofficialRingAdapter`` exercises:

  - ``POST https://oauth.ring.com/oauth/token``
  - ``GET  https://api.ring.com/clients_api/ring_devices``
  - ``GET  https://api.ring.com/clients_api/doorbots/{id}/history``
  - ``GET  https://api.ring.com/clients_api/snapshots/image/{id}``
  - ``GET  https://api.ring.com/clients_api/dings/{event_id}/recording``

The handler records every request so tests can assert on call counts
(e.g. for refresh-token rotation).
"""

from __future__ import annotations

import httpx


def build_ring_api_transport(
    *,
    devices: list[dict] | None = None,
    events: list[dict] | None = None,
    snapshot_bytes: bytes = b"\x89PNGfake",
    clip_url: str = "https://cdn.ring.invalid/clip-123.mp4",
    rotate_refresh_token: str | None = None,
) -> tuple[httpx.MockTransport, list[httpx.Request]]:
    """Return ``(transport, request_log)``.

    ``request_log`` lists every intercepted request in arrival order so
    tests can assert on counts (e.g. "the OAuth endpoint was called
    exactly once").

    Args:
        devices: Raw Ring-shaped device dicts returned from
            ``/clients_api/ring_devices`` (flattened into ``doorbots``).
        events: Raw Ring-shaped event dicts returned from the history
            endpoint. Defaults to a single ``motion`` event.
        snapshot_bytes: Bytes returned from the snapshot endpoint.
        clip_url: URL returned from the clip ``/recording`` endpoint.
        rotate_refresh_token: When not ``None``, the OAuth handler
            includes this value as ``refresh_token`` in its response
            body to simulate Ring's opportunistic refresh-token rotation.
    """
    devices = devices or [
        {
            "id": 123,
            "kind": "doorbell_pro",
            "description": "Front Door",
            "firmware_version": "3.48.42",
        }
    ]
    events = events or [
        {
            "id": 1,
            "kind": "motion",
            "created_at": "2025-01-01T00:00:00Z",
            "duration": 15,
        }
    ]
    request_log: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        request_log.append(request)
        url = str(request.url)

        if "oauth.ring.com" in url:
            body: dict = {
                "access_token": "fake-at",
                "token_type": "Bearer",
                "expires_in": 3600,
            }
            if rotate_refresh_token is not None:
                body["refresh_token"] = rotate_refresh_token
            return httpx.Response(200, json=body)

        if url.endswith("/clients_api/ring_devices"):
            return httpx.Response(200, json={"doorbots": devices})

        if "/clients_api/doorbots/" in url and "/history" in url:
            return httpx.Response(200, json=events)

        if "/clients_api/snapshots/image/" in url:
            return httpx.Response(
                200,
                content=snapshot_bytes,
                headers={"content-type": "image/jpeg"},
            )

        if "/clients_api/dings/" in url and url.endswith("/recording"):
            return httpx.Response(200, json={"url": clip_url})

        return httpx.Response(404, json={"error": "not_found"})

    return httpx.MockTransport(handler), request_log
