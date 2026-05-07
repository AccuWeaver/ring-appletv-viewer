"""API key authentication dependency for FastAPI."""

from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from app.config import get_settings

_bearer_scheme = HTTPBearer(auto_error=False)


async def verify_api_key(
    credentials: HTTPAuthorizationCredentials | None = Depends(_bearer_scheme),  # noqa: B008
) -> str:
    """FastAPI dependency that validates the API key from the Authorization header.

    Checks that the request includes an `Authorization: Bearer {key}` header
    and that the key matches the configured APP_API_KEY.

    Returns:
        The validated API key string.

    Raises:
        HTTPException: 401 if the header is missing or the key is invalid.
    """
    if credentials is None:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"error": "unauthorized"},
        )

    settings = get_settings()
    if credentials.credentials != settings.app_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"error": "unauthorized"},
        )

    return credentials.credentials
