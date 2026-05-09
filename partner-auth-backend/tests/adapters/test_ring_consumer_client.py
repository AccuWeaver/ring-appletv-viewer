"""Property and example tests for ``RingConsumerClient``.

Property 4 (task 6.2): Access-token refresh threshold.
    For any ``expires_in`` in ``[60, 86400]`` and simulated wall-clock ``now``,
    the client refreshes iff ``(expires_at - now) <= REFRESH_THRESHOLD_SECONDS``
    (Requirements 3.3, 3.4).

Retry / header / refresh examples (task 6.3):
    - 429 ``Retry-After`` honored exactly once.
    - 429 without ``Retry-After`` uses exponential backoff 1 → 2 → 4 → 8 → 16 s.
    - 5xx retried up to two times, then ``UpstreamUnavailableError``.
    - Per-request timeout equals 10 s.
    - ``User-Agent`` header includes ``ring-adapter-backend/<version>``.
    - Rotated refresh token triggers ``store.rotate``.
    - 401 on refresh marks the store invalid and raises ``AuthenticationRequiredError``.

Validates: Requirements 3.3, 3.4, 3.5, 3.7, 8.3, 8.4, 8.5, 8.6.
"""

from __future__ import annotations

import asyncio
from typing import Any
from unittest.mock import patch

import httpx
import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.adapters.errors import (
    AuthenticationRequiredError,
    UpstreamUnavailableError,
)
from app.adapters.rate_limit import RateLimitGovernor
from app.adapters.ring_consumer_client import (
    REFRESH_THRESHOLD_SECONDS,
    RingConsumerClient,
)

# ---------------------------------------------------------------------------
# Fakes and helpers
# ---------------------------------------------------------------------------


class FakeStore:
    """In-memory stand-in for `RefreshTokenStore`.

    Duck-typed: ``RingConsumerClient`` only calls ``load``, ``rotate``, and
    ``mark_invalid`` on the store, so we do not need to subclass the real
    SQLite-backed implementation to drive these tests.
    """

    def __init__(self, initial: str | None = "rt0") -> None:
        self.value = initial
        self.rotations: list[str] = []
        self.marked_invalid = False

    async def load(self) -> str | None:
        if self.marked_invalid:
            return None
        return self.value

    async def rotate(self, new_refresh_token: str) -> None:
        self.rotations.append(new_refresh_token)
        self.value = new_refresh_token

    async def save(self, value: str) -> None:
        self.value = value

    async def mark_invalid(self) -> None:
        self.marked_invalid = True

    async def is_valid(self) -> bool:
        return not self.marked_invalid


def _make_governor() -> RateLimitGovernor:
    """Build a governor that never throttles in a test.

    ``max_per_minute=1000`` is well above any single test's request count,
    so ``acquire()`` is effectively instant with no queue wait.
    """
    return RateLimitGovernor(max_per_minute=1000, queue_wait_seconds=0.0)


def _oauth_response(
    access_token: str = "at",
    expires_in: int = 3600,
    refresh_token: str | None = None,
) -> httpx.Response:
    body: dict[str, Any] = {
        "access_token": access_token,
        "token_type": "Bearer",
        "expires_in": expires_in,
    }
    if refresh_token is not None:
        body["refresh_token"] = refresh_token
    return httpx.Response(200, json=body)


# ---------------------------------------------------------------------------
# Task 6.2 — Property 4: refresh iff within threshold.
# ---------------------------------------------------------------------------


@settings(max_examples=40, deadline=None)
@given(
    expires_in=st.integers(min_value=60, max_value=86_400),
    elapsed=st.integers(min_value=0, max_value=86_400),
)
def test_property4_refresh_iff_within_threshold(expires_in: int, elapsed: int) -> None:
    """**Validates: Requirements 3.3, 3.4**

    Pin a fake clock, make an initial ``ensure_access_token()`` call (which
    always refreshes because no token is cached), advance the clock by
    ``elapsed`` seconds, then call again. The second call must hit the
    OAuth endpoint iff ``(expires_at - now) <= REFRESH_THRESHOLD_SECONDS``
    and otherwise must reuse the cached token with no new HTTP traffic.
    """

    async def run() -> None:
        refresh_calls: list[httpx.Request] = []

        def handler(request: httpx.Request) -> httpx.Response:
            if "oauth.ring.com" in str(request.url):
                refresh_calls.append(request)
                return _oauth_response(
                    access_token=f"at-{len(refresh_calls)}",
                    expires_in=expires_in,
                )
            return httpx.Response(200, json=[])

        http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
        try:
            store = FakeStore()
            client = RingConsumerClient(http, _make_governor(), store)

            t0 = 1_700_000_000.0
            now = [t0]
            with patch(
                "app.adapters.ring_consumer_client.time.time",
                side_effect=lambda: now[0],
            ):
                # First call: no cached token, always refreshes.
                tok1 = await client.ensure_access_token()
                assert tok1 == "at-1"
                assert len(refresh_calls) == 1

                # Advance the clock and call again.
                now[0] = t0 + elapsed
                tok2 = await client.ensure_access_token()

                time_until_expiry = expires_in - elapsed
                if time_until_expiry <= REFRESH_THRESHOLD_SECONDS:
                    assert len(refresh_calls) == 2, (
                        f"expected refresh at threshold: expires_in={expires_in} "
                        f"elapsed={elapsed} until_expiry={time_until_expiry}"
                    )
                    assert tok2 == "at-2"
                else:
                    assert len(refresh_calls) == 1, (
                        f"expected cached token reuse: expires_in={expires_in} "
                        f"elapsed={elapsed} until_expiry={time_until_expiry}"
                    )
                    assert tok2 == "at-1"
        finally:
            await http.aclose()

    asyncio.run(run())


# ---------------------------------------------------------------------------
# Task 6.3 — retry / header / refresh example tests.
# ---------------------------------------------------------------------------


def _seeded_handler(api_responses: list[httpx.Response]) -> Any:
    """Return a ``MockTransport`` handler that serves OAuth uniformly and
    emits ``api_responses`` in order for any non-OAuth request.

    OAuth always returns a 1-hour access token so tests can focus solely on
    API-side behavior (retries, headers, 5xx handling).
    """
    api_iter = iter(api_responses)

    def handler(request: httpx.Request) -> httpx.Response:
        if "oauth.ring.com" in str(request.url):
            return _oauth_response()
        return next(api_iter)

    return handler


@pytest.fixture
def recorded_sleeps(monkeypatch: pytest.MonkeyPatch) -> list[float]:
    """Replace ``asyncio.sleep`` inside the client module with a zero-latency
    recorder so retry backoff timing is observable without real delays.
    """
    recorded: list[float] = []

    async def fake_sleep(seconds: float) -> None:
        recorded.append(float(seconds))

    monkeypatch.setattr("app.adapters.ring_consumer_client.asyncio.sleep", fake_sleep)
    return recorded


async def test_429_retry_after_honored_exactly_once(
    recorded_sleeps: list[float],
) -> None:
    """429 with ``Retry-After`` → the client sleeps for the header value and
    retries exactly once before the follow-up 200 succeeds (Req 8.3)."""
    responses = [
        httpx.Response(429, headers={"retry-after": "7"}),
        httpx.Response(200, json=[]),
    ]
    http = httpx.AsyncClient(transport=httpx.MockTransport(_seeded_handler(responses)))
    try:
        client = RingConsumerClient(http, _make_governor(), FakeStore())
        await client.get_devices()
    finally:
        await http.aclose()

    # Exactly one backoff sleep — the 7 s from the Retry-After header — is
    # recorded; no additional retries followed the 200 success.
    assert recorded_sleeps == [7.0], recorded_sleeps


async def test_429_without_retry_after_uses_exponential_backoff(
    recorded_sleeps: list[float],
) -> None:
    """Sequence of 429s (no ``Retry-After``) produces the capped-exponential
    1 → 2 → 4 → 8 → 16 → 30 s backoff schedule (Req 8.3)."""
    responses = [httpx.Response(429) for _ in range(5)] + [httpx.Response(200, json=[])]
    http = httpx.AsyncClient(transport=httpx.MockTransport(_seeded_handler(responses)))
    try:
        client = RingConsumerClient(http, _make_governor(), FakeStore())
        await client.get_devices()
    finally:
        await http.aclose()

    # The 429 path does not add jitter, so values are exact.
    assert recorded_sleeps[:5] == [1.0, 2.0, 4.0, 8.0, 16.0], recorded_sleeps


async def test_5xx_retried_up_to_two_times_then_raises(
    recorded_sleeps: list[float],
) -> None:
    """5xx responses are retried up to twice (three attempts total); on the
    third 5xx the client raises ``UpstreamUnavailableError`` (Req 8.4)."""
    # Five 500s is more than enough — only three should be consumed before
    # the client gives up.
    responses = [httpx.Response(500) for _ in range(5)]
    http = httpx.AsyncClient(transport=httpx.MockTransport(_seeded_handler(responses)))
    try:
        client = RingConsumerClient(http, _make_governor(), FakeStore())
        with pytest.raises(UpstreamUnavailableError):
            await client.get_devices()
    finally:
        await http.aclose()

    # Two retries ⇒ two backoff sleeps. Jitter up to 0.25 s is added on the
    # 5xx path, so we assert count and lower-bound each value.
    assert len(recorded_sleeps) == 2, recorded_sleeps
    assert 1.0 <= recorded_sleeps[0] < 1.5
    assert 2.0 <= recorded_sleeps[1] < 2.5


async def test_user_agent_header_includes_backend_name_and_version() -> None:
    """Outbound API requests carry a ``User-Agent`` of the documented shape
    ``ring-adapter-backend/<version>`` (Req 8.6)."""
    api_user_agents: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        if "oauth.ring.com" in str(request.url):
            return _oauth_response()
        api_user_agents.append(request.headers.get("user-agent", ""))
        return httpx.Response(200, json=[])

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        client = RingConsumerClient(http, _make_governor(), FakeStore(), version="1.2.3")
        await client.get_devices()
    finally:
        await http.aclose()

    assert api_user_agents, "expected at least one API request"
    for ua in api_user_agents:
        assert ua.startswith("ring-adapter-backend/"), ua
        assert "1.2.3" in ua, ua


async def test_refresh_rotates_store_when_new_refresh_token_returned() -> None:
    """When Ring returns a new ``refresh_token`` in the OAuth response, the
    client writes it through ``store.rotate()`` (Req 3.5)."""

    def handler(request: httpx.Request) -> httpx.Response:
        if "oauth.ring.com" in str(request.url):
            return _oauth_response(refresh_token="rt_new")
        return httpx.Response(200, json=[])

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        store = FakeStore(initial="rt_old")
        client = RingConsumerClient(http, _make_governor(), store)
        await client.ensure_access_token()
    finally:
        await http.aclose()

    assert store.rotations == ["rt_new"]
    assert store.value == "rt_new"


async def test_refresh_same_token_does_not_rotate() -> None:
    """If Ring echoes the same ``refresh_token`` back (or omits it), the
    store is left untouched — rotation is skipped when nothing changed."""

    def handler(request: httpx.Request) -> httpx.Response:
        if "oauth.ring.com" in str(request.url):
            # Echo the existing refresh token back unchanged.
            return _oauth_response(refresh_token="rt_same")
        return httpx.Response(200, json=[])

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        store = FakeStore(initial="rt_same")
        client = RingConsumerClient(http, _make_governor(), store)
        await client.ensure_access_token()
    finally:
        await http.aclose()

    assert store.rotations == []


async def test_refresh_401_marks_store_invalid_and_raises() -> None:
    """OAuth 401 → ``store.mark_invalid()`` runs and
    ``AuthenticationRequiredError`` is raised (Req 3.7)."""

    def handler(request: httpx.Request) -> httpx.Response:
        if "oauth.ring.com" in str(request.url):
            return httpx.Response(401, json={"error": "invalid_grant"})
        return httpx.Response(200, json=[])

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        store = FakeStore()
        client = RingConsumerClient(http, _make_governor(), store)
        with pytest.raises(AuthenticationRequiredError):
            await client.ensure_access_token()
    finally:
        await http.aclose()

    assert store.marked_invalid is True


async def test_refresh_missing_token_raises_authentication_required() -> None:
    """An empty store surfaces ``AuthenticationRequiredError`` before any
    OAuth call is made (Req 3.7 — operator must bootstrap a token)."""
    oauth_hits = 0

    def handler(request: httpx.Request) -> httpx.Response:
        nonlocal oauth_hits
        if "oauth.ring.com" in str(request.url):
            oauth_hits += 1
        return httpx.Response(500)

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        client = RingConsumerClient(http, _make_governor(), FakeStore(initial=None))
        with pytest.raises(AuthenticationRequiredError):
            await client.ensure_access_token()
    finally:
        await http.aclose()

    assert oauth_hits == 0


async def test_request_timeout_is_ten_seconds() -> None:
    """Every outbound HTTP call sets ``timeout=10 s`` (Req 8.5).

    ``httpx`` surfaces the effective per-request timeout via
    ``request.extensions["timeout"]``. We capture that from inside the mock
    transport and assert each bucket is 10 s.
    """
    observed_reads: list[float] = []

    def handler(request: httpx.Request) -> httpx.Response:
        timeout = request.extensions.get("timeout")
        if isinstance(timeout, dict) and "read" in timeout:
            observed_reads.append(float(timeout["read"]))
        if "oauth.ring.com" in str(request.url):
            return _oauth_response()
        return httpx.Response(200, json=[])

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        client = RingConsumerClient(http, _make_governor(), FakeStore())
        await client.get_devices()
    finally:
        await http.aclose()

    # OAuth + API request both pass through, each setting ``timeout=10.0``.
    assert observed_reads, "expected at least one observed timeout"
    for t in observed_reads:
        assert t == 10.0, observed_reads


# ---------------------------------------------------------------------------
# Snapshot refresh: 404 → POST → retry GET (manual trigger for stale caches)
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_get_snapshot_refreshes_when_cache_is_empty() -> None:
    """Ring returns 404 when it has no cached snapshot for a device.

    The client MUST then POST ``/clients_api/snapshots/update_all`` with
    body ``{"doorbot_ids": [<id>]}`` to request a fresh capture, wait
    briefly, and retry the GET. If the retry succeeds, the JPEG bytes
    are returned to the caller. Verbs, paths, and body contents are
    observable via the mock transport's request log.
    """

    import json as _json

    requests: list[tuple[str, str, bytes]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth.ring.com" in url:
            return _oauth_response()
        method = request.method
        body = request.content
        requests.append((method, url, body))
        if "/snapshots/image/" in url and method == "GET":
            # First GET 404s; second (post-refresh) GET returns a JPEG.
            get_count = sum(1 for m, u, _ in requests if m == "GET" and "/snapshots/image/" in u)
            if get_count == 1:
                return httpx.Response(404)
            return httpx.Response(
                200,
                content=b"\xff\xd8\xff\xe0JFIFfake",
                headers={"content-type": "image/jpeg"},
            )
        if url.endswith("/clients_api/snapshots/update_all") and method == "PUT":
            # Ring acknowledges the manual capture request.
            return httpx.Response(200, content=b"")
        return httpx.Response(500)

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        client = RingConsumerClient(
            http,
            _make_governor(),
            FakeStore(),
            snapshot_refresh_settle_seconds=0.0,
        )
        content, ctype = await client.get_snapshot("12345")
    finally:
        await http.aclose()

    assert content.startswith(b"\xff\xd8"), "expected JPEG bytes"
    assert ctype == "image/jpeg"

    # Verify the exact request sequence:
    #   GET  /snapshots/image/12345                        → 404
    #   PUT  /snapshots/update_all {doorbot_ids, refresh}  → 200
    #   GET  /snapshots/image/12345                        → 200
    paths = [(m, u.split("ring.com")[-1]) for m, u, _ in requests]
    assert paths == [
        ("GET", "/clients_api/snapshots/image/12345"),
        ("PUT", "/clients_api/snapshots/update_all"),
        ("GET", "/clients_api/snapshots/image/12345"),
    ], paths

    # Body of the refresh PUT carries the device id as an int plus refresh flag.
    _, _, refresh_body = requests[1]
    assert _json.loads(refresh_body) == {
        "doorbot_ids": [12345],
        "refresh": True,
    }


@pytest.mark.asyncio
async def test_get_snapshot_still_404_after_refresh_propagates() -> None:
    """If Ring refuses to capture (battery cam offline, account issue), the
    retry GET also 404s. The client MUST propagate the 404 as
    ``HTTPStatusError`` so the adapter layer maps it to
    ``SnapshotUnavailableError`` (→ HTTP 503, Req 5.2). Cache behavior
    and session reuse are unaffected.
    """

    def handler(request: httpx.Request) -> httpx.Response:
        url = str(request.url)
        if "oauth.ring.com" in url:
            return _oauth_response()
        if "/snapshots/image/" in url:
            # Always 404 regardless of verb.
            return httpx.Response(404)
        return httpx.Response(500)

    http = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    try:
        client = RingConsumerClient(
            http,
            _make_governor(),
            FakeStore(),
            snapshot_refresh_settle_seconds=0.0,
        )
        with pytest.raises(httpx.HTTPStatusError) as excinfo:
            await client.get_snapshot("999")
    finally:
        await http.aclose()

    assert excinfo.value.response.status_code == 404
