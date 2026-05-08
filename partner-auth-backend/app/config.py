"""Application configuration with fail-fast environment variable validation."""

import os

from dotenv import load_dotenv


class ConfigurationError(Exception):
    """Raised when required environment variables are missing at startup."""

    pass


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
            raise ConfigurationError(
                f"Missing required environment variables: {missing_list}"
            )

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
        if ring_adapter_raw not in {"mock", "unofficial"}:
            raise ConfigurationError(
                f"RING_ADAPTER must be one of 'mock' or 'unofficial', "
                f"got {ring_adapter_raw!r}"
            )
        self.ring_adapter: str = ring_adapter_raw

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

        # MediaMTX / SIP bridge URLs (Requirement 7.8)
        self.mediamtx_rtsp_url: str = os.environ.get(
            "MEDIAMTX_RTSP_URL", "rtsp://mediamtx:8554/ring"
        )
        self.mediamtx_whep_base: str = os.environ.get(
            "MEDIAMTX_WHEP_BASE", "http://mediamtx:8889"
        )
        # Preserved for MockRingAdapter (matches mock_ring_api.py default)
        self.mediamtx_whep_url: str = os.environ.get(
            "MEDIAMTX_WHEP_URL", "http://localhost:8889/test/whep"
        )
        self.ring_sip_bridge_url: str = os.environ.get(
            "RING_SIP_BRIDGE_URL", "http://ring-sip-bridge:3000"
        )


def _parse_int_env(var_name: str, *, default: int) -> int:
    """Parse an integer environment variable, raising ConfigurationError on bad input."""
    raw = os.environ.get(var_name, "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigurationError(
            f"{var_name} must be an integer, got {raw!r}"
        ) from exc


def get_settings() -> Settings:
    """Create and return a validated Settings instance.

    Raises ConfigurationError if any required environment variables are missing.
    """
    return Settings()
