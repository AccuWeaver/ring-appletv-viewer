"""Adapter factory — wires the RingAdapter chosen by `RING_ADAPTER`.

Called from `app/main.py`'s lifespan hook exactly once per running
backend; installs the resulting adapter via `app.dependency_overrides`.
"""

from __future__ import annotations

import logging
from collections.abc import Awaitable, Callable

import httpx

from app.adapters.base import RingAdapter
from app.adapters.go2rtc_client import Go2rtcClient
from app.adapters.mock import MockRingAdapter
from app.adapters.partner import PartnerRingAdapter
from app.adapters.rate_limit import RateLimitGovernor
from app.adapters.ring_consumer_client import RingConsumerClient
from app.adapters.session_map import StreamSessionMap
from app.adapters.sip_bridge_client import SipBridgeClient
from app.adapters.unofficial import UnofficialRingAdapter
from app.config import ConfigurationError, Settings
from app.data.encryptor import FernetEncryptor
from app.data.refresh_token_store import RefreshTokenStore

logger = logging.getLogger(__name__)

# Rate-limit governor queue budget (Requirement 8.2): callers wait up to
# this many seconds for a slot before a RateLimitedError is raised.
_RATE_LIMIT_QUEUE_WAIT_SECONDS: float = 5.0


async def create_adapters_for_profile(
    settings: Settings,
    token_provider: Callable[[], Awaitable[str]] | None = None,
) -> list[RingAdapter]:
    """Instantiate one RingAdapter per mode in ``settings.routing_profile``.

    Returns adapters in profile order.  The caller (lifespan hook) is
    responsible for closing any adapters that own HTTP clients on shutdown.

    Args:
        settings: Validated application settings.
        token_provider: Async callable that returns a valid partner OAuth
            access token.  Required when ``"partner"`` appears in the
            routing profile; ignored otherwise.

    Raises:
        ConfigurationError: when the unofficial adapter is selected but no
            refresh token is available, when ``"partner"`` is in the profile
            but no *token_provider* is supplied, or when an unknown mode is
            encountered.

    Requirements: 1.1, 1.2, 9.1, 9.5
    """
    adapters: list[RingAdapter] = []
    for mode in settings.routing_profile:
        if mode == "mock":
            logger.info("startup adapter_mode=mock")
            adapters.append(MockRingAdapter(mediamtx_whep_url=settings.mediamtx_whep_url))

        elif mode == "unofficial":
            adapters.append(await _create_unofficial_adapter(settings))

        elif mode == "partner":
            if token_provider is None:
                raise ConfigurationError(
                    "routing profile includes 'partner' but no token_provider was supplied"
                )
            adapters.append(_create_partner_adapter(token_provider))

        else:
            # config.py already validates tokens, but belt-and-braces here.
            raise ConfigurationError(f"unknown adapter mode {mode!r} in routing profile")

    return adapters


async def create_adapter(settings: Settings) -> RingAdapter:
    """Instantiate the RingAdapter selected by ``settings.ring_adapter``.

    Exactly one instance is created per running backend; the lifespan hook
    in ``app/main.py`` is responsible for installing it via
    ``app.dependency_overrides`` so every ``/mock/*`` route shares the
    same object (Requirement 7.3).

    Raises:
        ConfigurationError: when the unofficial adapter is selected but no
            refresh token is available (neither stored nor env bootstrap),
            or when ``ring_adapter`` is an unexpected value.
    """
    if settings.ring_adapter == "mock":
        logger.info("startup adapter_mode=mock")
        return MockRingAdapter(mediamtx_whep_url=settings.mediamtx_whep_url)

    if settings.ring_adapter == "unofficial":
        return await _create_unofficial_adapter(settings)

    # ``config.py`` already validates the enum, but belt-and-braces here so a
    # future refactor that bypasses the config check still fails cleanly
    # (Requirement 7.2).
    raise ConfigurationError(f"unknown ring_adapter {settings.ring_adapter!r}")


async def _create_unofficial_adapter(settings: Settings) -> UnofficialRingAdapter:
    """Build the full unofficial-adapter dependency graph."""
    encryptor = FernetEncryptor(settings.token_encryption_key)
    refresh_store = RefreshTokenStore(settings.database_path, encryptor)
    await refresh_store.initialize()

    # Bootstrap: stored value wins over env (Requirement 3.2); missing on
    # both raises ConfigurationError (Requirements 3.6, 7.2).
    await _bootstrap_refresh_token(refresh_store, settings)

    # Outbound rate-limit governor — shapes traffic to api.ring.com only
    # (Requirements 8.1, 8.2).
    governor = RateLimitGovernor(
        max_per_minute=settings.ring_api_rate_limit_per_minute,
        queue_wait_seconds=_RATE_LIMIT_QUEUE_WAIT_SECONDS,
    )

    # The Ring consumer client and the mediamtx WHEP proxy live on
    # different upstream hosts and have different retry characteristics,
    # so they each get their own ``httpx.AsyncClient``. The adapter owns
    # the WHEP client itself; we hand the Ring API client to the consumer
    # and keep a reference below so the lifespan hook can close it on
    # shutdown (see the assignment to ``adapter._ring_http`` at the end
    # of this function).
    ring_http = httpx.AsyncClient()
    consumer = RingConsumerClient(ring_http, governor, refresh_store)

    sip = SipBridgeClient(
        base_url=settings.ring_sip_bridge_url,
        refresh_token_provider=refresh_store.load,
    )

    adapter = UnofficialRingAdapter(
        client=consumer,
        sip=sip,
        sessions=StreamSessionMap(),
        max_concurrent=settings.ring_max_concurrent_streams,
        mediamtx_whep_base=settings.mediamtx_whep_base,
        mediamtx_hls_public_base=settings.mediamtx_hls_public_base,
        sip_bridge_public_url=settings.ring_sip_bridge_public_url,
        go2rtc=_build_go2rtc_client(settings),
    )

    # Stash the Ring-API httpx client on the adapter so the lifespan hook
    # (task 9.2) can close it alongside ``adapter.aclose()``. The consumer
    # client accepts the httpx client as a non-owning reference, so
    # something has to close it eventually; owning it here keeps the
    # factory's teardown contract explicit.
    adapter._ring_http = ring_http  # type: ignore[attr-defined]

    logger.info("startup adapter_mode=unofficial")
    return adapter


def _create_partner_adapter(
    token_provider: Callable[[], Awaitable[str]],
) -> PartnerRingAdapter:
    """Build a PartnerRingAdapter with its own httpx.AsyncClient.

    The HTTP client is owned by the adapter; the lifespan hook closes it
    via ``adapter.aclose()`` on shutdown.

    Requirements: 2.1, 9.1
    """
    http = httpx.AsyncClient()
    adapter = PartnerRingAdapter(
        http=http,
        token_provider=token_provider,
        session_map=StreamSessionMap(),
    )
    # Stash the http client so the lifespan hook can close it on shutdown.
    adapter._http_owned = True  # type: ignore[attr-defined]
    logger.info("startup adapter_mode=partner")
    return adapter


def _build_go2rtc_client(settings: Settings) -> Go2rtcClient | None:
    """Return a go2rtc client when the wrapped refresh token is present.

    The unofficial adapter uses this client to upsert per-camera Ring
    streams and return a public HLS URL for simulator clients. If the
    ``RING_REFRESH_TOKEN_G2R`` env var is empty, we return None and the
    adapter falls back to the ring-sip-bridge path.
    """
    if not settings.ring_refresh_token_g2r:
        return None
    return Go2rtcClient(
        internal_base_url=settings.go2rtc_url,
        public_base_url=settings.go2rtc_public_url,
        wrapped_refresh_token=settings.ring_refresh_token_g2r,
        ice_servers_json=settings.go2rtc_ring_ice_servers,
        ice_transport_policy=settings.go2rtc_ring_ice_transport_policy,
    )


async def _bootstrap_refresh_token(store: RefreshTokenStore, settings: Settings) -> None:
    """Seed the refresh-token store from env only when the store is empty.

    Implements Requirements 3.1 and 3.2:

    - If the store already holds a valid token, the env var is ignored so
      a previously rotated token is never clobbered by a stale bootstrap
      value.
    - If the store is empty and an env token is present, persist it
      (encrypted at rest via ``FernetEncryptor``).
    - If both are empty, raise :class:`ConfigurationError` so startup
      fails fast (Requirements 3.6, 7.2, 10.6).

    Token values are never logged — only the source is recorded.
    """
    stored = await store.load()
    if stored is not None:
        logger.info("ring_refresh_token_source=stored")
        return

    env_value = settings.ring_refresh_token
    if env_value:
        await store.save(env_value)
        logger.info("ring_refresh_token_source=env_bootstrap")
        return

    raise ConfigurationError(
        "RING_ADAPTER=unofficial requires RING_REFRESH_TOKEN on first boot "
        "or a pre-seeded ring_refresh_token row; neither was found"
    )
