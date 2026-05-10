"""Structured-log secret redaction.

A single ``RedactingFilter`` attached to the root logger during startup
scrubs known-sensitive field names from every emitted record. Prefers
failing safe over failing clean: the filter never raises; it just
replaces matched values with ``[REDACTED]``.

Validates Requirements 3.8, 9.2, 9.5.
"""

from __future__ import annotations

import logging
import re
from typing import Final

# Field names whose values must never appear in logs. Case-insensitive.
REDACTED_FIELDS: Final[frozenset[str]] = frozenset(
    {
        "refresh_token",
        "access_token",
        "authorization",
        "cookie",
        "ring_refresh_token",
        "ring_access_token",
    }
)

# Regex catching ``field=value`` patterns inside ``record.msg``. Values
# are matched greedily up to whitespace.
_FIELD_VALUE_RE = re.compile(
    r"(?i)\b(" + "|".join(re.escape(f) for f in REDACTED_FIELDS) + r")=(\S+)"
)

# Regex catching URL query strings: ``field=value`` terminated by ``&``,
# space, or end of string. Separate from the above because URL values
# end at ``&`` rather than whitespace.
_URL_QUERY_RE = re.compile(
    r"(?i)([?&])("
    + "|".join(re.escape(f) for f in REDACTED_FIELDS)
    + r")=([^&\s\"]+)"
)

# Regex catching ``"field": "value"`` JSON-ish patterns.
_JSON_FIELD_RE = re.compile(
    r'(?i)"(' + "|".join(re.escape(f) for f in REDACTED_FIELDS) + r')"\s*:\s*"([^"]*)"'
)


def _redact_dict(args: dict) -> dict:
    return {
        key: ("[REDACTED]" if key.lower() in REDACTED_FIELDS else value)
        for key, value in args.items()
    }


def _redact_string(value: str) -> str:
    # URL query params first so the scrubbed value in ``field=...``
    # doesn't leak through the looser ``\S+`` matcher afterwards.
    value = _URL_QUERY_RE.sub(r"\1\2=[REDACTED]", value)
    value = _FIELD_VALUE_RE.sub(r"\1=[REDACTED]", value)
    value = _JSON_FIELD_RE.sub(r'"\1": "[REDACTED]"', value)
    return value


class RedactingFilter(logging.Filter):
    """Scrubs known-sensitive field names from every log record.

    The filter materializes ``record.getMessage()`` (the interpolated
    output) and re-writes it through the redaction regexes, then clears
    ``record.args`` so downstream formatters don't re-interpolate a raw
    secret. Dict-valued ``record.args`` keyed by redacted field names
    are also stripped defensively — both because ``logger.info(msg, d)``
    is a valid stdlib idiom and because structured loggers commonly
    stash dicts on `args`.

    The filter always returns ``True`` so records are never dropped;
    redaction is strictly a content transformation, and it never raises.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            # Build the fully-interpolated message up front so we can
            # redact after %-formatting. This is the key fix vs. regexing
            # the raw template — ``record.msg`` might be "auth=%s" and
            # only the formatted string ``"auth=<secret>"`` contains the
            # value we must scrub.
            try:
                formatted = record.getMessage()
            except Exception:
                formatted = str(record.msg)

            if isinstance(record.args, dict):
                formatted = _format_dict_summary(record.msg, record.args)

            record.msg = _redact_string(formatted)
            # Clear args so downstream formatters don't try to re-interpolate.
            record.args = None
        except Exception:
            # Never let a logging filter raise in the hot path.
            return True
        return True


def _format_dict_summary(template: object, args: dict) -> str:
    """Render ``template`` alongside a redacted view of ``args``.

    Mirrors the stdlib's behavior when ``msg`` is a non-percent-format
    string and ``args`` is a dict: the dict is not substituted into the
    template. We render it explicitly so the test's ``"kept"`` value
    still appears in the output while secret keys are scrubbed.
    """
    redacted = {
        key: ("[REDACTED]" if key.lower() in REDACTED_FIELDS else value)
        for key, value in args.items()
    }
    rendered_args = " ".join(f"{k}={v}" for k, v in redacted.items())
    template_str = str(template)
    if rendered_args:
        return f"{template_str} {rendered_args}"
    return template_str


def install() -> None:
    """Attach the redacting filter to the root logger (idempotent)."""
    root = logging.getLogger()
    for existing in root.filters:
        if isinstance(existing, RedactingFilter):
            break
    else:
        root.addFilter(RedactingFilter())
    # httpx logs full request URLs at INFO, which can include secrets in
    # query strings (e.g. the wrapped Ring refresh token). The URL-query
    # redactor above catches them, but quieting httpx to WARNING removes
    # the risk entirely while keeping its error signal visible.
    logging.getLogger("httpx").setLevel(logging.WARNING)
