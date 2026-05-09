"""Property tests for the routing profile parser.

# Feature: ring-adapter-live-media, Property 1: Routing Profile Parser Correctness
"""

import os
from unittest.mock import patch

import pytest
from hypothesis import given, settings
from hypothesis import strategies as st

from app.config import VALID_ADAPTER_MODES, ConfigurationError, _parse_routing_profile

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

MODES = sorted(VALID_ADAPTER_MODES)  # ["mock", "partner", "unofficial"]

# A minimal valid environment that satisfies RING_ADAPTER so the parser's
# "both unset" path is never triggered by accident.
_VALID_BASE_ENV = {
    "RING_ADAPTER": "mock",
}


def _run_parser(routing_value: str) -> list[str]:
    """Run _parse_routing_profile with RING_ADAPTER_ROUTING set to *routing_value*."""
    env = {**_VALID_BASE_ENV, "RING_ADAPTER_ROUTING": routing_value}
    with patch.dict(os.environ, env, clear=True):
        return _parse_routing_profile("mock")


# ---------------------------------------------------------------------------
# Property 1a: Arbitrary text input — parser never crashes unexpectedly
#
# For any arbitrary string supplied as RING_ADAPTER_ROUTING, the parser MUST
# either return a valid normalised list or raise ConfigurationError.
# Any other exception (AttributeError, KeyError, …) is a bug.
#
# Validates: Requirements 1.1, 1.3
# ---------------------------------------------------------------------------


# Env vars must be valid UTF-8 with no null bytes or surrogate characters.
# st.characters(blacklist_categories=("Cs",)) excludes surrogates; we also
# blacklist the null byte explicitly.
_env_safe_text = st.text(
    alphabet=st.characters(
        blacklist_categories=("Cs",),  # exclude surrogates
        blacklist_characters="\x00",
    )
)


@settings(max_examples=500)
@given(raw=_env_safe_text)
def test_arbitrary_input_returns_valid_list_or_raises_configuration_error(
    raw: str,
) -> None:
    """Property 1a: Routing Profile Parser Correctness — arbitrary text

    For any input string, the parser either produces a valid normalised list
    or raises ConfigurationError.  No other exception is acceptable.

    **Validates: Requirements 1.1, 1.3**
    """
    try:
        result = _run_parser(raw)
    except ConfigurationError:
        # Expected failure path — the parser correctly rejected the input.
        return
    except Exception as exc:  # noqa: BLE001
        pytest.fail(
            f"Parser raised unexpected exception {type(exc).__name__}: {exc!r} for input {raw!r}"
        )

    # If we reach here the parser succeeded — validate the returned list.
    assert isinstance(result, list), f"Expected list, got {type(result)}"
    assert 1 <= len(result) <= 3, f"Result length {len(result)} out of range [1, 3]: {result!r}"
    for token in result:
        assert token in VALID_ADAPTER_MODES, (
            f"Token {token!r} not in VALID_ADAPTER_MODES for input {raw!r}"
        )
    assert len(result) == len(set(result)), (
        f"Result contains duplicates: {result!r} for input {raw!r}"
    )


# ---------------------------------------------------------------------------
# Property 1b: Valid inputs always succeed
#
# For any list of 1–3 unique tokens from {partner, unofficial, mock} joined
# with commas, the parser MUST succeed and return the normalised list.
#
# Validates: Requirements 1.1, 1.3
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    tokens=st.lists(
        st.sampled_from(MODES),
        min_size=1,
        max_size=3,
        unique=True,
    )
)
def test_valid_token_list_always_succeeds(tokens: list[str]) -> None:
    """Property 1b: Routing Profile Parser Correctness — valid inputs

    For any valid list of 1–3 unique tokens from {partner, unofficial, mock}
    joined with commas, the parser always succeeds and returns the normalised
    list in the same order.

    **Validates: Requirements 1.1, 1.3**
    """
    raw = ",".join(tokens)
    try:
        result = _run_parser(raw)
    except ConfigurationError as exc:
        pytest.fail(f"Parser raised ConfigurationError for valid input {raw!r}: {exc}")

    assert result == tokens, f"Parser returned {result!r} but expected {tokens!r} for input {raw!r}"


# ---------------------------------------------------------------------------
# Property 1c: Whitespace-padded valid tokens are normalised correctly
#
# Tokens with leading/trailing ASCII whitespace must be trimmed and still
# accepted, returning the same normalised list as the unpadded version.
#
# Validates: Requirement 1.1
# ---------------------------------------------------------------------------


@settings(max_examples=200)
@given(
    tokens=st.lists(
        st.sampled_from(MODES),
        min_size=1,
        max_size=3,
        unique=True,
    ),
    padding=st.text(
        alphabet=st.characters(whitelist_categories=("Zs",), whitelist_characters=" \t"),
        max_size=4,
    ),
)
def test_whitespace_padded_tokens_are_normalised(tokens: list[str], padding: str) -> None:
    """Property 1c: Whitespace padding is stripped from each token.

    **Validates: Requirement 1.1**
    """
    raw = ",".join(f"{padding}{t}{padding}" for t in tokens)
    try:
        result = _run_parser(raw)
    except ConfigurationError as exc:
        pytest.fail(f"Parser raised ConfigurationError for whitespace-padded input {raw!r}: {exc}")

    assert result == tokens, (
        f"Parser returned {result!r} but expected {tokens!r} for padded input {raw!r}"
    )
