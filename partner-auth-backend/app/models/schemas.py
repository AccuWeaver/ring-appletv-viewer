"""Pydantic data models for the Partner Auth Backend."""

from datetime import datetime

from pydantic import BaseModel


class TokenExchangeRequest(BaseModel):
    """Payload Ring sends to the Token Exchange URL."""

    code: str
    grant_type: str = "authorization_code"
    redirect_uri: str | None = None


class AccountLinkRequest(BaseModel):
    """Payload Ring sends to the Account Link URL."""

    nonce: str
    signature: str
    account_id: str
    partner_account_id: str | None = None


class AccountLinkResponse(BaseModel):
    """Confirmation payload returned to Ring."""

    status: str = "linked"
    account_id: str


class TokenRecord(BaseModel):
    """Internal representation of stored tokens."""

    user_id: str
    access_token: str
    refresh_token: str
    expires_at: datetime
    token_type: str = "Bearer"
    scope: str | None = None
    is_valid: bool = True
    created_at: datetime
    updated_at: datetime


class TokenResponse(BaseModel):
    """Response to tvOS app token requests."""

    access_token: str
    token_type: str = "Bearer"
    expires_at: str  # ISO 8601 datetime string


class WebhookEvent(BaseModel):
    """Stored webhook event from Ring."""

    event_id: str
    event_type: str
    device_id: str
    timestamp: datetime
    payload: dict
    received_at: datetime


class RingOAuthTokenResponse(BaseModel):
    """Response from Ring's OAuth token endpoint."""

    access_token: str
    refresh_token: str
    expires_in: int
    token_type: str = "Bearer"
    scope: str | None = None
