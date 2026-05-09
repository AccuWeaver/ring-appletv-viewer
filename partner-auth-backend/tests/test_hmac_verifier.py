"""Property tests for HMAC verification correctness.

# Feature: partner-auth-backend, Property 2: HMAC verification correctness
"""

import base64
import hashlib
import hmac

from hypothesis import given, settings
from hypothesis import strategies as st

from app.services.hmac_verifier import HMACVerifier

# Strategy: random bytes for the signing key (16-64 bytes), base64-encoded
key_strategy = st.binary(min_size=16, max_size=64).map(lambda b: base64.b64encode(b).decode())

# Strategy: random text strings for the nonce
nonce_strategy = st.text(min_size=1, max_size=200)


@settings(max_examples=100)
@given(key_b64=key_strategy, nonce=nonce_strategy)
def test_hmac_verifier_accepts_correct_signature(key_b64: str, nonce: str) -> None:
    """Property 2: HMAC verification correctness

    For any random key and nonce, HMACVerifier SHALL accept the correct
    HMAC-SHA256 signature.

    **Validates: Requirements 2.2, 2.5**
    """
    # Compute the correct signature using Python's hmac module directly
    key_bytes = base64.b64decode(key_b64)
    correct_sig = hmac.new(key_bytes, nonce.encode(), hashlib.sha256).hexdigest()

    # Verify that HMACVerifier accepts the correct signature
    verifier = HMACVerifier(key_b64)
    assert verifier.verify(nonce, correct_sig) is True, (
        f"HMACVerifier rejected a correct signature for nonce={nonce!r}"
    )


@settings(max_examples=100)
@given(
    key_b64=key_strategy,
    nonce=nonce_strategy,
    mutation_index=st.integers(min_value=0),
)
def test_hmac_verifier_rejects_mutated_signature(
    key_b64: str, nonce: str, mutation_index: int
) -> None:
    """Property 2: HMAC verification correctness

    For any random key and nonce, HMACVerifier SHALL reject any signature
    that differs from the correct one by at least one byte.

    **Validates: Requirements 2.2, 2.5**
    """
    # Compute the correct signature
    key_bytes = base64.b64decode(key_b64)
    correct_sig = hmac.new(key_bytes, nonce.encode(), hashlib.sha256).hexdigest()

    # Mutate at least one character in the signature
    # A hex signature is 64 characters (SHA-256 = 32 bytes = 64 hex chars)
    pos = mutation_index % len(correct_sig)
    original_char = correct_sig[pos]

    # Pick a different hex character
    hex_chars = "0123456789abcdef"
    replacement = hex_chars[(hex_chars.index(original_char) + 1) % len(hex_chars)]

    mutated_sig = correct_sig[:pos] + replacement + correct_sig[pos + 1 :]

    # Ensure the mutation actually changed the signature
    assert mutated_sig != correct_sig

    # Verify that HMACVerifier rejects the mutated signature
    verifier = HMACVerifier(key_b64)
    assert verifier.verify(nonce, mutated_sig) is False, (
        f"HMACVerifier accepted a mutated signature for nonce={nonce!r}"
    )
