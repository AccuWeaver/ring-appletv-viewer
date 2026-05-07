"""App API endpoints for the tvOS client."""

import logging

from fastapi import APIRouter, Depends, HTTPException, Query, Request, status

from app.config import get_settings
from app.data.encryptor import FernetEncryptor
from app.data.token_store import TokenStore
from app.middleware.rate_limiter import limiter
from app.models.schemas import TokenResponse
from app.services.auth import verify_api_key
from app.services.token_service import (
    SessionInvalidError,
    TokenNotFoundError,
    TokenService,
)

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api")


# ---------------------------------------------------------------------------
# Dependency helpers
# ---------------------------------------------------------------------------


def _get_token_service() -> TokenService:
    """Create a TokenService instance from config."""
    settings = get_settings()
    encryptor = FernetEncryptor(settings.token_encryption_key)
    token_store = TokenStore(db_path=settings.database_path, encryptor=encryptor)
    return TokenService(
        client_id=settings.ring_client_id,
        client_secret=settings.ring_client_secret,
        token_store=token_store,
    )


# ---------------------------------------------------------------------------
# GET /api/token
# ---------------------------------------------------------------------------


@router.get("/token")
@limiter.limit("60/minute")
async def get_token(
    request: Request,
    user_id: str = Query(default="default"),
    _api_key: str = Depends(verify_api_key),
) -> TokenResponse:
    """Return a valid access token for the specified user.

    Proactively refreshes if within 5 minutes of expiry.
    Requires valid API key in Authorization header.

    Returns:
        TokenResponse with access_token, token_type, and expires_at.

    Raises:
        HTTPException 404: If no tokens exist for the user.
        HTTPException 401: If the session has been invalidated.
    """
    token_service = _get_token_service()

    try:
        tokens = await token_service.get_valid_token(user_id=user_id)
    except TokenNotFoundError:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail={"error": "user_not_found"},
        ) from None
    except SessionInvalidError:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail={"error": "session_invalid", "message": "Re-authorization required"},
        ) from None
    except Exception:
        raise HTTPException(
            status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
            detail={"error": "internal_error"},
        ) from None

    return TokenResponse(
        access_token=tokens["access_token"],
        token_type=tokens.get("token_type", "Bearer"),
        expires_at=tokens["expires_at"],
    )
