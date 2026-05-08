"""Property tests for fail-fast environment variable validation.

# Feature: partner-auth-backend, Property 7: Fail-fast environment variable validation
"""

import os
from unittest.mock import patch

from hypothesis import given, settings
from hypothesis import strategies as st

from app.config import REQUIRED_ENV_VARS, ConfigurationError, Settings

# Strategy: generate non-empty subsets of required env vars to omit
# We use sets of indices into REQUIRED_ENV_VARS, then map to variable names
non_empty_subsets = st.frozensets(
    st.sampled_from(REQUIRED_ENV_VARS), min_size=1
)


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
            raise AssertionError(
                f"Expected ConfigurationError for omitted vars: {omitted}"
            )
        except ConfigurationError as exc:
            error_message = str(exc)
            # Every omitted variable name must appear in the error message
            for var_name in omitted:
                assert var_name in error_message, (
                    f"Missing variable '{var_name}' not found in error message: "
                    f"{error_message}"
                )
