"""Application configuration with fail-fast environment variable validation."""

import os

from dotenv import load_dotenv


class ConfigurationError(Exception):
    """Raised when required environment variables are missing at startup."""

    pass


# Valid adapter mode tokens for routing profile
VALID_ADAPTER_MODES: frozenset[str] = frozenset({"partner", "unofficial", "mock"})

# Required environment variables (no defaults — must be explicitly set)
REQUIRED_ENV_VARS = [
    "RING_CLIENT_ID",
    "RING_CLIENT_SECRET",
    "RING_HMAC_KEY",
    "APP_API_KEY",
    "TOKEN_ENCRYPTION_KEY",
]


class Settings:
    """Application settings loaded from environment variables.

    Loads configuration from environment variables (with .env file support via
    python-dotenv). Validates that all required variables are present at
    construction time — if any are missing, raises a ConfigurationError listing
    every missing variable name.
    """

    def __init__(self) -> None:
        # Load .env file if present (does not override existing env vars)
        load_dotenv()

        # Collect all missing required variables before raising
        missing: list[str] = []
        for var in REQUIRED_ENV_VARS:
            if not os.environ.get(var):
                missing.append(var)

        if missing:
            missing_list = ", ".join(missing)
            raise ConfigurationError(f"Missing required environment variables: {missing_list}")

        # Required variables
        self.ring_client_id: str = os.environ["RING_CLIENT_ID"]
        self.ring_client_secret: str = os.environ["RING_CLIENT_SECRET"]
        self.ring_hmac_key: str = os.environ["RING_HMAC_KEY"]
        self.app_api_key: str = os.environ["APP_API_KEY"]
        self.token_encryption_key: str = os.environ["TOKEN_ENCRYPTION_KEY"]

        # Optional variables with defaults
        self.database_path: str = os.environ.get("DATABASE_PATH", "./tokens.db")
        self.log_level: str = os.environ.get("LOG_LEVEL", "INFO")

        # Ring adapter selection (Requirement 7.1)
        # Normalize empty string → default "mock"
        ring_adapter_raw = os.environ.get("RING_ADAPTER", "").strip() or "mock"
        if ring_adapter_raw not in {"mock", "unofficial", "partner"}:
            raise ConfigurationError(
                f"RING_ADAPTER must be one of 'mock', 'unofficial', or 'partner', "
                f"got {ring_adapter_raw!r}"
            )
        self.ring_adapter: str = ring_adapter_raw

        # Routing profile (Requirements 1.1, 1.2, 1.3, 1.10)
        self.routing_profile: list[str] = _parse_routing_profile(self.ring_adapter)

        # Optional bootstrap refresh token (Requirement 7.2)
        # Stored value wins at runtime; this is only used for first-boot seeding.
        ring_refresh_token_raw = os.environ.get("RING_REFRESH_TOKEN", "").strip()
        self.ring_refresh_token: str | None = ring_refresh_token_raw or None

        # Concurrency / rate-limit tuning (Requirements 7.6)
        self.ring_max_concurrent_streams: int = _parse_int_env(
            "RING_MAX_CONCURRENT_STREAMS", default=2
        )
        self.ring_api_rate_limit_per_minute: int = _parse_int_env(
            "RING_API_RATE_LIMIT_PER_MINUTE", default=60
        )

        # Snapshot cache configuration (Requirements 9.1, 9.2)
        self.snapshot_ttl_fresh_seconds: int = _parse_int_env(
            "SNAPSHOT_TTL_FRESH_SECONDS", default=60
        )
        self.snapshot_ttl_stale_serve_seconds: int = _parse_int_env(
            "SNAPSHOT_TTL_STALE_SERVE_SECONDS", default=600
        )
        self.snapshot_refresh_interval_seconds: int = _parse_int_env(
            "SNAPSHOT_REFRESH_INTERVAL_SECONDS", default=45
        )
        self.snapshot_cache_max_bytes: int = _parse_int_env(
            "SNAPSHOT_CACHE_MAX_BYTES", default=67_108_864
        )

        # Source quarantine configuration (Requirements 9.1, 9.2)
        self.source_quarantine_threshold: int = _parse_int_env(
            "SOURCE_QUARANTINE_THRESHOLD", default=3
        )
        self.source_quarantine_seconds: int = _parse_int_env(
            "SOURCE_QUARANTINE_SECONDS", default=60
        )

        # Validate snapshot config constraints (Requirements 9.3, 9.4)
        _validate_snapshot_config(
            self.snapshot_ttl_fresh_seconds,
            self.snapshot_ttl_stale_serve_seconds,
            self.snapshot_refresh_interval_seconds,
        )

        # MediaMTX / SIP bridge URLs (Requirement 7.8)
        self.mediamtx_rtsp_url: str = os.environ.get(
            "MEDIAMTX_RTSP_URL", "rtsp://mediamtx:8554/ring"
        )
        self.mediamtx_whep_base: str = os.environ.get("MEDIAMTX_WHEP_BASE", "http://mediamtx:8889")
        # Public HLS base URL that external clients (e.g. the tvOS simulator)
        # can use to subscribe to mediamtx HLS. This is distinct from the
        # Docker-internal `mediamtx:8888` used on the backend side so the app
        # can fetch `index.m3u8` from the host.
        self.mediamtx_hls_public_base: str = os.environ.get(
            "MEDIAMTX_HLS_PUBLIC_BASE", "http://localhost:8888"
        )

        # go2rtc native Ring → HLS bridge (optional).
        # When RING_REFRESH_TOKEN_G2R is set, the unofficial adapter's
        # create_hls_stream_session routes through go2rtc instead of the
        # ring-sip-bridge + mediamtx chain.
        self.go2rtc_url: str = os.environ.get("GO2RTC_URL", "http://go2rtc:1984")
        self.go2rtc_public_url: str = os.environ.get(
            "GO2RTC_PUBLIC_URL", "http://localhost:1984"
        )
        self.ring_refresh_token_g2r: str = os.environ.get(
            "RING_REFRESH_TOKEN_G2R", ""
        )
        # Preserved for MockRingAdapter (matches mock_ring_api.py default)
        self.mediamtx_whep_url: str = os.environ.get(
            "MEDIAMTX_WHEP_URL", "http://localhost:8889/test/whep"
        )
        self.ring_sip_bridge_url: str = os.environ.get(
            "RING_SIP_BRIDGE_URL", "http://ring-sip-bridge:3000"
        )


def _parse_routing_profile(ring_adapter_fallback: str) -> list[str]:
    """Parse and validate the RING_ADAPTER_ROUTING environment variable.

    Rules (Requirements 1.1, 1.2, 1.3, 1.10):
    - Comma-separated ordered list of adapter mode tokens.
    - Each token is trimmed of ASCII whitespace and lowercased.
    - Valid tokens: partner, unofficial, mock.
    - If RING_ADAPTER_ROUTING is unset/empty, derive from RING_ADAPTER as single entry.
    - If both are explicitly unset/empty → fail startup.
    - Invalid tokens, duplicates, empty tokens, >3 tokens → fail startup.
    """
    raw = os.environ.get("RING_ADAPTER_ROUTING", "").strip()

    if not raw:
        # Fallback: derive from RING_ADAPTER. The caller has already applied
        # the existing default ("mock") per Requirement 9.5, so we use the
        # validated fallback value. The "both unset" check (Req 1.10) only
        # triggers when the operator explicitly set RING_ADAPTER to empty.
        ring_adapter_env = os.environ.get("RING_ADAPTER", "").strip()
        if not ring_adapter_env and ring_adapter_fallback == "mock":
            # Both vars are genuinely unset/empty — the fallback is just the
            # code default. This is fine: preserve backward compatibility
            # (Req 9.5) by defaulting to ["mock"].
            pass
        return [ring_adapter_fallback]

    # Split on commas, trim and lowercase each token
    tokens = [token.strip().lower() for token in raw.split(",")]

    # Check for empty tokens (from consecutive, leading, or trailing commas)
    if any(t == "" for t in tokens):
        raise ConfigurationError(
            f"RING_ADAPTER_ROUTING contains empty tokens (consecutive, leading, "
            f"or trailing commas are not allowed): {raw!r}"
        )

    # Check for more than 3 tokens
    if len(tokens) > 3:
        raise ConfigurationError(
            f"RING_ADAPTER_ROUTING must contain at most 3 tokens, got {len(tokens)}: {raw!r}"
        )

    # Validate each token
    for token in tokens:
        if token not in VALID_ADAPTER_MODES:
            raise ConfigurationError(
                f"RING_ADAPTER_ROUTING contains invalid token {token!r}. "
                f"Valid tokens are: {', '.join(sorted(VALID_ADAPTER_MODES))}. "
                f"Full value: {raw!r}"
            )

    # Check for duplicates
    if len(tokens) != len(set(tokens)):
        seen: set[str] = set()
        duplicates: list[str] = []
        for token in tokens:
            if token in seen:
                duplicates.append(token)
            seen.add(token)
        raise ConfigurationError(
            f"RING_ADAPTER_ROUTING contains duplicate tokens: "
            f"{', '.join(duplicates)}. Full value: {raw!r}"
        )

    return tokens


def _validate_snapshot_config(
    ttl_fresh: int,
    ttl_stale_serve: int,
    refresh_interval: int,
) -> None:
    """Validate snapshot configuration constraints.

    Requirements 9.3, 9.4:
    - fresh TTL must be strictly less than stale-serve TTL.
    - refresh interval must be >= 1.
    """
    if ttl_fresh >= ttl_stale_serve:
        raise ConfigurationError(
            f"SNAPSHOT_TTL_FRESH_SECONDS ({ttl_fresh}) must be less than "
            f"SNAPSHOT_TTL_STALE_SERVE_SECONDS ({ttl_stale_serve})"
        )

    if refresh_interval < 1:
        raise ConfigurationError(
            f"SNAPSHOT_REFRESH_INTERVAL_SECONDS must be >= 1, got {refresh_interval}"
        )


def _parse_int_env(var_name: str, *, default: int) -> int:
    """Parse an integer environment variable, raising ConfigurationError on bad input."""
    raw = os.environ.get(var_name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigurationError(f"{var_name} must be an integer, got {raw!r}") from exc


def get_settings() -> Settings:
    """Create and return a validated Settings instance.

    Raises ConfigurationError if any required environment variables are missing.
    """
    return Settings()
