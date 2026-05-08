"""Integration test for startup failure under bad unofficial-mode config.

With ``RING_ADAPTER=unofficial`` set and neither ``RING_REFRESH_TOKEN``
nor a pre-seeded store row, the backend must exit with a non-zero status
within 5 seconds (Requirement 10.6).
"""

from __future__ import annotations

import contextlib
import os
import subprocess
import sys
import tempfile
import time


def test_missing_refresh_token_in_unofficial_mode_exits_nonzero_fast() -> None:
    # Fresh temp DB so there's no pre-seeded row either.
    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tmp:
        db_path = tmp.name

    env = {
        "RING_CLIENT_ID": "test",
        "RING_CLIENT_SECRET": "test",
        "RING_HMAC_KEY": "dGVzdGhtYWNrZXkxMjM0NTY3ODkwMTIzNDU2Nzg5MDEyMw==",
        "APP_API_KEY": "test-api-key",
        "TOKEN_ENCRYPTION_KEY": "z-6mRAl-NHWoVYqHFG_sEjGk9iy2lpnWyDWDpVBy-u0=",
        "RING_ADAPTER": "unofficial",
        "DATABASE_PATH": db_path,
        # Preserve PATH so the subprocess can find python + its stdlib.
        "PATH": os.environ.get("PATH", ""),
    }

    # Drive the lifespan by running an ASGI-lifespan import. Importing
    # app.main alone does not exercise the lifespan; we use a tiny
    # runner script that forces a single lifespan entry.
    script = """
import asyncio, sys
# Disable python-dotenv so a committed .env can't re-seed the required vars.
import dotenv
dotenv.load_dotenv = lambda *a, **kw: False

async def main():
    from app.main import app
    async with app.router.lifespan_context(app):
        pass

try:
    asyncio.run(main())
except SystemExit as e:
    sys.exit(e.code or 1)
"""

    start = time.monotonic()
    proc = subprocess.run(
        [sys.executable, "-c", script],
        capture_output=True,
        text=True,
        cwd=os.path.dirname(
            os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        ),
        env=env,
        timeout=10,
        check=False,
    )
    elapsed = time.monotonic() - start

    try:
        assert proc.returncode != 0, (
            f"expected non-zero exit; stdout={proc.stdout!r} stderr={proc.stderr!r}"
        )
        # Requirement 10.6: "exit with a non-zero status code within 5 seconds".
        assert elapsed < 5.0, f"exit took {elapsed:.1f}s, expected < 5s"
    finally:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(db_path)
