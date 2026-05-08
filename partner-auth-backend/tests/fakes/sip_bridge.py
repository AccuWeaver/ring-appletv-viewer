"""Fake ring-sip-bridge sidecar for integration tests.

Serves the sidecar's HTTP contract:

  - ``POST /sessions`` → 201 ``{bridge_session_id, rtsp_path, has_audio}``
  - ``DELETE /sessions/{id}`` → 204
  - ``GET /health`` → 200 ``{status, active_sessions}``
"""

from __future__ import annotations

import json
import uuid

import httpx


def build_sip_bridge_transport() -> httpx.MockTransport:
    """Return a ``MockTransport`` that emulates the SIP bridge sidecar."""
    sessions: dict[str, dict] = {}

    def handler(request: httpx.Request) -> httpx.Response:
        path = request.url.path
        if request.method == "POST" and path == "/sessions":
            raw = request.content.decode() if request.content else "{}"
            data = json.loads(raw) if raw else {}
            device_id = data.get("device_id", "unknown")
            bsid = str(uuid.uuid4())
            sessions[bsid] = {"device_id": device_id, "state": "active"}
            return httpx.Response(
                201,
                json={
                    "bridge_session_id": bsid,
                    "rtsp_path": f"ring/{device_id}",
                    "has_audio": True,
                },
            )
        if request.method == "DELETE" and path.startswith("/sessions/"):
            bsid = path.rsplit("/", 1)[-1]
            sessions.pop(bsid, None)
            return httpx.Response(204)
        if request.method == "GET" and path == "/health":
            return httpx.Response(
                200,
                json={"status": "ok", "active_sessions": len(sessions)},
            )
        return httpx.Response(404)

    return httpx.MockTransport(handler)
