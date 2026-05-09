"""Property tests for Fernet encryption round-trip.

# Feature: partner-auth-backend, Property 6: Token encryption round-trip
"""

from cryptography.fernet import Fernet
from hypothesis import given, settings
from hypothesis import strategies as st

from app.data.encryptor import FernetEncryptor

# Fixed valid Fernet key for deterministic testing
TEST_KEY = Fernet.generate_key().decode()


@settings(max_examples=100)
@given(plaintext=st.text(min_size=0))
def test_encrypt_decrypt_round_trip(plaintext: str) -> None:
    """Property 6: Token encryption round-trip

    For any random string s: decrypt(encrypt(s)) == s (round-trip).

    **Validates: Requirements 9.4**
    """
    encryptor = FernetEncryptor(TEST_KEY)
    ciphertext = encryptor.encrypt(plaintext)
    decrypted = encryptor.decrypt(ciphertext)
    assert decrypted == plaintext, f"Round-trip failed: expected {plaintext!r}, got {decrypted!r}"


@settings(max_examples=100)
@given(plaintext=st.text(min_size=1))
def test_encrypt_produces_different_output(plaintext: str) -> None:
    """Property 6: Token encryption round-trip

    For any non-empty string s: encrypt(s) != s (ciphertext differs from plaintext).

    **Validates: Requirements 9.4**
    """
    encryptor = FernetEncryptor(TEST_KEY)
    ciphertext = encryptor.encrypt(plaintext)
    assert ciphertext != plaintext, (
        f"Ciphertext should differ from plaintext for input: {plaintext!r}"
    )
