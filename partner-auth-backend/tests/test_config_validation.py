"""Tests for fail-fast environment variable validation.

Covers:
- Property 7: Fail-fast environment variable validation (existing property test)
- Unit tests for routing profile and snapshot config edge cases (task 3.3)
"""

import os
from unittest.mock import patch

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.config import REQUIRED_ENV_VARS, ConfigurationError, Settings

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A minimal set of required env vars that satisfies the base required-var check,
# allowing tests to focus on routing/snapshot config validation.
_BASE_ENV: dict[str, str] = {
    "RING_CLIENT_ID": "test-client-id",
    "RING_CLIENT_SECRET": "test-client-secret",
    "RING_HMAC_KEY": "test-hmac-key",
    "APP_API_KEY": "test-api-key",
    "TOKEN_ENCRYPTION_KEY": "test-encryption-key",
}


def _make_settings(extra: dict[str, str] | None = None) -> Settings:
    """Construct Settings with base required vars plus any extra overrides."""
    env = {**_BASE_ENV, **(extra or {})}
    with (
        patch.dict(os.environ, env, clear=True),
        patch("app.config.load_dotenv", lambda *a, **kw: False),
    ):
        return Settings()


def _expect_config_error(extra: dict[str, str] | None = None) -> str:
    """Assert Settings() raises ConfigurationError and return the message."""
    env = {**_BASE_ENV, **(extra or {})}
    with (
        patch.dict(os.environ, env, clear=True),
        patch("app.config.load_dotenv", lambda *a, **kw: False),
    ):
        with pytest.raises(ConfigurationError) as exc_info:
            Settings()
        return str(exc_info.value)


# ---------------------------------------------------------------------------
# Property test (existing)
# ---------------------------------------------------------------------------

# Strategy: generate non-empty subsets of required env vars to omit
# We use sets of indices into REQUIRED_ENV_VARS, then map to variable names
non_empty_subsets = st.frozensets(st.sampled_from(REQUIRED_ENV_VARS), min_size=1)


@settings(max_examples=100)
@given(omitted=non_empty_subsets)
def test_missing_env_vars_raises_error_listing_all_missing(
    omitted: frozenset[str],
) -> None:
    """Property 7: Fail-fast environment variable validation

    For any non-empty subset of required env vars that is omitted, startup SHALL
    raise an error whose message contains every missing variable name.

    **Validates: Requirements 6.8**
    """
    # Build an environment with only the non-omitted required vars set
    env = {}
    for var in REQUIRED_ENV_VARS:
        if var not in omitted:
            env[var] = "test-value"

    # Patch os.environ so only our chosen vars are present.  Also patch
    # ``load_dotenv`` so a checked-in ``.env`` file cannot re-populate the
    # environment between the `clear=True` and the ``Settings()`` call.
    with (
        patch.dict(os.environ, env, clear=True),
        patch("app.config.load_dotenv", lambda *a, **kw: False),
    ):
        try:
            Settings()
            # If no error raised, the test fails
            raise AssertionError(f"Expected ConfigurationError for omitted vars: {omitted}")
        except ConfigurationError as exc:
            error_message = str(exc)
            # Every omitted variable name must appear in the error message
            for var_name in omitted:
                assert var_name in error_message, (
                    f"Missing variable '{var_name}' not found in error message: {error_message}"
                )


# ---------------------------------------------------------------------------
# Unit tests: routing profile edge cases (Requirements 1.3, 1.10)
# ---------------------------------------------------------------------------


def test_both_routing_vars_unset_defaults_to_mock() -> None:
    """Requirement 1.10 vs 9.5: both RING_ADAPTER_ROUTING and RING_ADAPTER unset.

    Requirement 1.10 says this should fail startup, but the implementation
    intentionally preserves backward compatibility (Requirement 9.5): when both
    variables are unset/empty, the routing profile defaults to ["mock"] rather
    than failing. This test documents the actual implemented behavior.

    NOTE: If Requirement 1.10 is to be strictly enforced, the implementation in
    _parse_routing_profile() must be updated to raise ConfigurationError when
    both RING_ADAPTER_ROUTING and RING_ADAPTER are empty/unset.
    """
    s = _make_settings({"RING_ADAPTER_ROUTING": "", "RING_ADAPTER": ""})
    assert s.routing_profile == ["mock"], (
        f"Expected routing_profile=['mock'] for backward compat, got {s.routing_profile!r}"
    )


def test_duplicate_tokens_in_routing_profile_fails_startup() -> None:
    """Requirement 1.3: duplicate tokens in RING_ADAPTER_ROUTING → startup failure."""
    msg = _expect_config_error({"RING_ADAPTER_ROUTING": "mock,unofficial,mock"})
    assert "duplicate" in msg.lower() or "RING_ADAPTER_ROUTING" in msg, (
        f"Error message should mention duplicates or the variable name, got: {msg!r}"
    )


def test_invalid_token_in_routing_profile_fails_startup() -> None:
    """Requirement 1.3: invalid token in RING_ADAPTER_ROUTING → startup failure."""
    msg = _expect_config_error({"RING_ADAPTER_ROUTING": "unofficial,bogus"})
    assert "bogus" in msg or "invalid" in msg.lower() or "RING_ADAPTER_ROUTING" in msg, (
        f"Error message should name the invalid token or variable, got: {msg!r}"
    )


def test_valid_single_entry_fallback_from_ring_adapter() -> None:
    """Requirement 1.2: when RING_ADAPTER_ROUTING is unset, derive profile from RING_ADAPTER.

    A valid RING_ADAPTER value with no RING_ADAPTER_ROUTING set should produce
    a single-entry routing profile equal to the RING_ADAPTER value.
    """
    s = _make_settings({"RING_ADAPTER": "unofficial"})
    assert s.routing_profile == ["unofficial"], (
        f"Expected routing_profile=['unofficial'], got {s.routing_profile!r}"
    )
    assert s.ring_adapter == "unofficial"


# ---------------------------------------------------------------------------
# Unit tests: snapshot config constraints (Requirements 9.3, 9.4)
# ---------------------------------------------------------------------------


def test_fresh_ttl_equal_to_stale_ttl_fails_startup() -> None:
    """Requirement 9.3: SNAPSHOT_TTL_FRESH_SECONDS >= SNAPSHOT_TTL_STALE_SERVE_SECONDS → failure.

    Equal values violate the strict-less-than constraint.
    """
    msg = _expect_config_error(
        {
            "SNAPSHOT_TTL_FRESH_SECONDS": "300",
            "SNAPSHOT_TTL_STALE_SERVE_SECONDS": "300",
        }
    )
    assert "SNAPSHOT_TTL_FRESH_SECONDS" in msg or "SNAPSHOT_TTL_STALE_SERVE_SECONDS" in msg, (
        f"Error message should name the offending variables, got: {msg!r}"
    )


def test_fresh_ttl_greater_than_stale_ttl_fails_startup() -> None:
    """Requirement 9.3: SNAPSHOT_TTL_FRESH_SECONDS > SNAPSHOT_TTL_STALE_SERVE_SECONDS → failure."""
    msg = _expect_config_error(
        {
            "SNAPSHOT_TTL_FRESH_SECONDS": "700",
            "SNAPSHOT_TTL_STALE_SERVE_SECONDS": "300",
        }
    )
    assert "SNAPSHOT_TTL_FRESH_SECONDS" in msg or "SNAPSHOT_TTL_STALE_SERVE_SECONDS" in msg, (
        f"Error message should name the offending variables, got: {msg!r}"
    )


def test_refresh_interval_zero_fails_startup() -> None:
    """Requirement 9.4: SNAPSHOT_REFRESH_INTERVAL_SECONDS = 0 → startup failure."""
    msg = _expect_config_error({"SNAPSHOT_REFRESH_INTERVAL_SECONDS": "0"})
    assert "SNAPSHOT_REFRESH_INTERVAL_SECONDS" in msg, (
        f"Error message should name SNAPSHOT_REFRESH_INTERVAL_SECONDS, got: {msg!r}"
    )


def test_refresh_interval_negative_fails_startup() -> None:
    """Requirement 9.4: SNAPSHOT_REFRESH_INTERVAL_SECONDS < 0 → startup failure."""
    msg = _expect_config_error({"SNAPSHOT_REFRESH_INTERVAL_SECONDS": "-5"})
    assert "SNAPSHOT_REFRESH_INTERVAL_SECONDS" in msg, (
        f"Error message should name SNAPSHOT_REFRESH_INTERVAL_SECONDS, got: {msg!r}"
    )


def test_valid_snapshot_config_succeeds() -> None:
    """Sanity check: valid snapshot config values should not raise."""
    s = _make_settings(
        {
            "SNAPSHOT_TTL_FRESH_SECONDS": "30",
            "SNAPSHOT_TTL_STALE_SERVE_SECONDS": "300",
            "SNAPSHOT_REFRESH_INTERVAL_SECONDS": "15",
        }
    )
    assert s.snapshot_ttl_fresh_seconds == 30
    assert s.snapshot_ttl_stale_serve_seconds == 300
    assert s.snapshot_refresh_interval_seconds == 15
