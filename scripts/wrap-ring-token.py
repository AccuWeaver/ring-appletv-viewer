#!/usr/bin/env python3
"""Wrap a Ring refresh token (JWT or raw) in go2rtc's AuthConfig envelope.

Go2rtc's ring source expects ``base64(json({"rt": <refresh>, "hid": <hardware_id>}))``.
This script reads the token from stdin, wraps it, and writes the wrapped
value to stdout so it can be piped into env files or curl requests.

Usage:
    echo "$RING_REFRESH_TOKEN" | uv run python scripts/wrap-ring-token.py

The hardware ID is deterministic per (token, salt) so restarts don't
spawn a new hardware entry in Ring's device list on every boot.
"""

from __future__ import annotations

import base64
import hashlib
import json
import sys


def wrap(token: str, *, salt: str = "ring-appletv-viewer") -> str:
    token = token.strip()
    if not token:
        raise SystemExit("empty token on stdin")
    hid = hashlib.sha256((salt + ":" + token).encode()).hexdigest()[:32]
    envelope = {"rt": token, "hid": hid}
    raw = json.dumps(envelope, separators=(",", ":")).encode()
    return base64.standard_b64encode(raw).decode()


def main() -> None:
    token = sys.stdin.read()
    print(wrap(token))


if __name__ == "__main__":
    main()
