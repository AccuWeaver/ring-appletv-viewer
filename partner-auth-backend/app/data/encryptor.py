"""Fernet symmetric encryption for token storage at rest."""

from cryptography.fernet import Fernet


class FernetEncryptor:
    """Encrypts and decrypts string values using Fernet symmetric encryption.

    Fernet guarantees that data encrypted with it cannot be read or tampered
    with without the key. It uses AES-128-CBC with HMAC-SHA256 for
    authentication.
    """

    def __init__(self, key: str) -> None:
        """Initialize the encryptor with a Fernet key.

        Args:
            key: A URL-safe base64-encoded 32-byte key suitable for Fernet.
        """
        self._fernet = Fernet(key.encode())

    def encrypt(self, plaintext: str) -> str:
        """Encrypt a plaintext string.

        Args:
            plaintext: The string value to encrypt.

        Returns:
            The encrypted ciphertext as a base64-encoded string.
        """
        token = self._fernet.encrypt(plaintext.encode())
        return token.decode()

    def decrypt(self, ciphertext: str) -> str:
        """Decrypt a base64-encoded ciphertext string.

        Args:
            ciphertext: The base64-encoded encrypted value.

        Returns:
            The original plaintext string.
        """
        plaintext = self._fernet.decrypt(ciphertext.encode())
        return plaintext.decode()
