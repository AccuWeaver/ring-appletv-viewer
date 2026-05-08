#!/usr/bin/env python3
"""Bootstrap a fresh Ring refresh token and bring the backend up in unofficial mode.

Steps performed, end-to-end:

1. Prompt for Ring email, password, and 2FA code (password is read without echo).
2. POST to Ring's consumer OAuth endpoint to exchange credentials for a refresh
   token (https://oauth.ring.com/oauth/token). On 2FA challenge, re-POST with the
   ``2fa-support`` / ``2fa-code`` headers.
3. Write the resulting ``refresh_token`` into the root ``.env`` file, preserving
   (or inserting) ``RING_ADAPTER=unofficial`` alongside it. Existing unrelated
   keys are left untouched.
4. Run ``docker compose exec backend rm -f /data/tokens.db`` so the fresh env
   value becomes the bootstrap source (per design Req 3.2: stored value wins
   over env, and we just invalidated the stored one).
5. Run ``docker compose up -d --force-recreate backend`` to restart.
6. Poll ``/health/adapter`` with the API key from ``.env`` / docker-compose.yml
   and report ``refresh_token_valid`` and the current rate counter.

Usage::

    python3 scripts/bootstrap_ring_refresh_token.py

The refresh token is never printed to stdout, only written to ``.env``.
"""

from __future__ import annotations

import getpass
import json
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ENV_PATH = REPO_ROOT / ".env"
COMPOSE_FILE = REPO_ROOT / "docker-compose.yml"

RING_OAUTH_URL = "https://oauth.ring.com/oauth/token"
RING_CLIENT_PAYLOAD = {
    "client_id": "ring_official_android",
    "scope": "client",
}
HEALTH_ADAPTER_URL = "http://localhost:8000/health/adapter"
HEALTH_URL = "http://localhost:8000/health"
API_KEY = "local-dev-api-key"  # matches APP_API_KEY in docker-compose.yml

TOKEN_KEY = "RING_REFRESH_TOKEN"
ADAPTER_KEY = "RING_ADAPTER"


# ---------------------------------------------------------------------------
# OAuth
# ---------------------------------------------------------------------------


def _post_oauth(
    email: str, password: str, twofa_code: str | None = None
) -> dict:
    body = urllib.parse.urlencode(
        {
            **RING_CLIENT_PAYLOAD,
            "grant_type": "password",
            "username": email,
            "password": password,
        }
    ).encode()

    headers = {
        "Content-Type": "application/x-www-form-urlencoded",
        "User-Agent": "ring-adapter-backend-bootstrap/1.0",
        "hardware_id": "ring-adapter-backend-bootstrap",
        "2fa-support": "true",
    }
    if twofa_code:
        headers["2fa-code"] = twofa_code

    req = urllib.request.Request(
        RING_OAUTH_URL, data=body, headers=headers, method="POST"
    )
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:  # noqa: S310
            return json.loads(resp.read().decode())
    except urllib.error.HTTPError as exc:
        return {
            "_http_status": exc.code,
            "_body": exc.read().decode(errors="replace"),
        }


def obtain_refresh_token() -> str:
    email = input("Ring email: ").strip()
    password = getpass.getpass("Ring password: ")

    resp = _post_oauth(email, password)
    if resp.get("_http_status") == 412 or (
        resp.get("_http_status") == 400
        and "2fa" in resp.get("_body", "").lower()
    ):
        code = input("2FA code sent to your device: ").strip()
        resp = _post_oauth(email, password, twofa_code=code)

    if "refresh_token" not in resp:
        status = resp.get("_http_status", "unknown")
        body = resp.get("_body", "") or json.dumps(resp)
        print(
            f"ERROR: Ring OAuth did not return a refresh_token. "
            f"HTTP {status}. Body: {body}",
            file=sys.stderr,
        )
        sys.exit(1)
    return resp["refresh_token"]


# ---------------------------------------------------------------------------
# .env upsert
# ---------------------------------------------------------------------------


def upsert_env(path: Path, updates: dict[str, str]) -> None:
    lines: list[str] = []
    if path.exists():
        lines = path.read_text().splitlines()

    seen: set[str] = set()
    out: list[str] = []
    for line in lines:
        match = re.match(r"^([A-Z_][A-Z0-9_]*)=", line)
        if match and match.group(1) in updates:
            key = match.group(1)
            out.append(f"{key}={updates[key]}")
            seen.add(key)
        else:
            out.append(line)

    for key, value in updates.items():
        if key not in seen:
            out.append(f"{key}={value}")

    # Preserve trailing newline convention.
    path.write_text("\n".join(out) + "\n")


# ---------------------------------------------------------------------------
# Docker Compose orchestration
# ---------------------------------------------------------------------------


def _run(cmd: list[str], *, check: bool = True, cwd: Path = REPO_ROOT) -> int:
    print(f"$ {' '.join(cmd)}")
    result = subprocess.run(cmd, cwd=cwd, check=False)
    if check and result.returncode != 0:
        print(f"ERROR: command failed with exit code {result.returncode}", file=sys.stderr)
        sys.exit(result.returncode)
    return result.returncode


def reset_token_store_and_restart() -> None:
    # Best-effort: if the backend isn't running yet, `exec` will fail — treat as
    # a clean slate and continue.
    _run(
        ["docker", "compose", "exec", "-T", "backend", "rm", "-f", "/data/tokens.db"],
        check=False,
    )
    _run(["docker", "compose", "up", "-d", "--force-recreate", "backend"])


# ---------------------------------------------------------------------------
# Health poll
# ---------------------------------------------------------------------------


def _fetch_json(url: str, headers: dict | None = None, timeout: float = 5.0) -> dict:
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:  # noqa: S310
        return json.loads(resp.read().decode())


def wait_for_adapter_health(max_attempts: int = 20, delay: float = 1.0) -> dict:
    auth = {"Authorization": f"Bearer {API_KEY}"}
    last_err: Exception | None = None
    for attempt in range(1, max_attempts + 1):
        try:
            _fetch_json(HEALTH_URL, timeout=3.0)  # basic liveness first
            return _fetch_json(HEALTH_ADAPTER_URL, headers=auth, timeout=3.0)
        except Exception as exc:  # pragma: no cover - diagnostic only
            last_err = exc
            time.sleep(delay)
    assert last_err is not None
    raise RuntimeError(
        f"Backend never became healthy after {max_attempts} attempts: {last_err}"
    )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    if not COMPOSE_FILE.exists():
        print(f"ERROR: {COMPOSE_FILE} not found; run from repo root.", file=sys.stderr)
        sys.exit(2)

    print("Requesting a fresh Ring refresh token…")
    refresh_token = obtain_refresh_token()
    print("  ✓ token obtained (not echoed).")

    print(f"Updating {ENV_PATH.relative_to(REPO_ROOT)}…")
    upsert_env(
        ENV_PATH,
        {
            TOKEN_KEY: refresh_token,
            ADAPTER_KEY: "unofficial",
        },
    )
    print("  ✓ .env updated.")

    print("Dropping encrypted token store and restarting the backend…")
    reset_token_store_and_restart()

    print("Waiting for backend to report health…")
    health = wait_for_adapter_health()
    print(json.dumps(health, indent=2))

    if not health.get("refresh_token_valid"):
        print(
            "\nThe refresh token was rejected by Ring. Common causes:\n"
            "  • copy-paste included quotes or whitespace;\n"
            "  • the token was already rotated by another exchange;\n"
            "  • the account requires 2FA and the code was wrong.\n"
            "Re-run this script to try again.",
            file=sys.stderr,
        )
        sys.exit(3)

    print("\n✅ Backend is running in unofficial mode with a valid refresh token.")
    print("   Open the tvOS simulator app; device snapshots should come from Ring now.")


if __name__ == "__main__":
    main()
