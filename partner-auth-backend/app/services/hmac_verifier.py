"""HMAC-SHA256 signature verification for Ring account linking."""

import base64
import hashlib
import hmac


class HMACVerifier:
    """Verifies HMAC-SHA256 signatures for Ring account linking requests.

    The signing key is provided as a base64-encoded string (matching the
    RING_HMAC_KEY environment variable format).
    """

    def __init__(self, signing_key_b64: str) -> None:
        """Initialize with a base64-encoded HMAC signing key.

        Args:
            signing_key_b64: The HMAC signing key, base64-encoded.
        """
        self._signing_key = base64.b64decode(signing_key_b64)

    def verify(self, nonce: str, provided_signature: str) -> bool:
        """Verify that the provided signature matches HMAC-SHA256(key, nonce).

        Computes HMAC-SHA256 of the nonce using the decoded signing key,
        encodes the result as a hex string, and performs a timing-safe
        comparison against the provided signature.

        Args:
            nonce: The nonce string to verify (e.g., "<timestamp>:<account_id>").
            provided_signature: The hex-encoded HMAC signature to check.

        Returns:
            True if the signatures match, False otherwise.
        """
        computed = hmac.new(
            key=self._signing_key,
            msg=nonce.encode("utf-8"),
            digestmod=hashlib.sha256,
        ).hexdigest()

        return hmac.compare_digest(computed, provided_signature)
