"""Property 6: No plaintext secrets in log output.

For any random secret value passed through any log-emitting path, captured
log output contains no plaintext leakage; values referenced by redacted
field names produce ``[REDACTED]`` in emitted records.

Validates: Requirements 3.8, 9.2, 9.5.
"""

from __future__ import annotations

import io
import logging

from hypothesis import given, settings
from hypothesis import strategies as st

from app.logging_redaction import REDACTED_FIELDS, RedactingFilter


def _capture_logs(func) -> str:
    """Attach a memory handler with the redacting filter; run func; return output."""
    buffer = io.StringIO()
    handler = logging.StreamHandler(buffer)
    handler.setLevel(logging.DEBUG)
    handler.addFilter(RedactingFilter())

    root = logging.getLogger()
    root.addHandler(handler)
    prev_level = root.level
    root.setLevel(logging.DEBUG)
    try:
        func()
        handler.flush()
        return buffer.getvalue()
    finally:
        root.removeHandler(handler)
        root.setLevel(prev_level)


# Secret values: printable but non-whitespace so our `\S+` regex grabs them
# cleanly. Avoid quote characters so we don't collide with the JSON regex's
# delimiters when the secret itself happens to be quoted-shaped.
_secret_strategy = st.text(
    alphabet=st.characters(
        min_codepoint=0x21,
        max_codepoint=0x7E,
        blacklist_characters='"',
    ),
    min_size=6,
    max_size=60,
)


# Every redacted field name from the filter, as a lower-cased string.
_field_strategy = st.sampled_from(sorted(REDACTED_FIELDS))


# ---------------------------------------------------------------------------
# Property 6 (a): dict-args redaction
# ---------------------------------------------------------------------------


@settings(max_examples=50, deadline=None)
@given(field=_field_strategy, secret=_secret_strategy)
def test_property6_dict_args_redact_known_fields(field: str, secret: str) -> None:
    """When a log record's args is a dict keyed by a redacted field name,
    the formatted output replaces the value with ``[REDACTED]`` and does
    NOT contain the plaintext secret.

    **Validates: Requirements 3.8, 9.2, 9.5**
    """
    def run() -> None:
        logger = logging.getLogger("test.redaction.dict")
        logger.info("secret-log", {field: secret, "other": "kept"})

    output = _capture_logs(run)
    assert "[REDACTED]" in output
    assert secret not in output
    assert "kept" in output  # non-secret values survive


# ---------------------------------------------------------------------------
# Property 6 (b): field=value inside record.msg
# ---------------------------------------------------------------------------


@settings(max_examples=50, deadline=None)
@given(field=_field_strategy, secret=_secret_strategy)
def test_property6_field_value_patterns_in_message_are_redacted(
    field: str, secret: str
) -> None:
    """Free-form log strings of the form ``field=value`` get the value
    replaced by ``[REDACTED]`` regardless of which logger emitted them.

    **Validates: Requirements 3.8, 9.2, 9.5**
    """
    def run() -> None:
        logger = logging.getLogger("test.redaction.msg")
        logger.info("auth attempt %s=%s other=kept", field, secret)

    output = _capture_logs(run)
    assert f"{field}=[REDACTED]" in output
    assert secret not in output
    assert "kept" in output


# ---------------------------------------------------------------------------
# Property 6 (c): JSON-shaped patterns in record.msg
# ---------------------------------------------------------------------------


@settings(max_examples=50, deadline=None)
@given(field=_field_strategy, secret=_secret_strategy)
def test_property6_json_patterns_in_message_are_redacted(
    field: str, secret: str
) -> None:
    """JSON-ish patterns like ``"field": "value"`` in the message are
    redacted when the field name is in the redaction list.

    **Validates: Requirements 3.8, 9.2, 9.5**
    """
    def run() -> None:
        logger = logging.getLogger("test.redaction.json")
        logger.info('body: {"%s": "%s", "kept": "visible"}', field, secret)

    output = _capture_logs(run)
    # The redaction rewrites the message template before interpolation,
    # which also strips the secret.
    assert secret not in output
    assert "[REDACTED]" in output


# ---------------------------------------------------------------------------
# Property 6 (d): case-insensitive field match
# ---------------------------------------------------------------------------


@settings(max_examples=30, deadline=None)
@given(secret=_secret_strategy)
def test_property6_case_insensitive_field_matches(secret: str) -> None:
    """``Authorization=...`` is redacted identically to ``authorization=...``.

    **Validates: Requirements 3.8, 9.2, 9.5**
    """
    def run() -> None:
        logger = logging.getLogger("test.redaction.case")
        logger.info("header Authorization=%s", secret)

    output = _capture_logs(run)
    assert "Authorization=[REDACTED]" in output
    assert secret not in output


# ---------------------------------------------------------------------------
# Property 6 (e): non-secret strings are left intact
# ---------------------------------------------------------------------------


@settings(max_examples=30, deadline=None)
@given(benign=st.text(
    alphabet=st.characters(min_codepoint=0x21, max_codepoint=0x7E, blacklist_characters='"='),
    min_size=6,
    max_size=40,
))
def test_property6_benign_messages_are_not_mutated(benign: str) -> None:
    """Messages without any redacted field name pass through unchanged.

    **Validates: Requirements 3.8, 9.2, 9.5**
    """
    def run() -> None:
        logger = logging.getLogger("test.redaction.benign")
        logger.info("status ok=%s", benign)

    output = _capture_logs(run)
    assert benign in output
    assert "[REDACTED]" not in output
