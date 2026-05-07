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


def get_settings() -> Settings:
    """Create and return a validated Settings instance.

    Raises ConfigurationError if any required environment variables are missing.
    """
    return Settings()
