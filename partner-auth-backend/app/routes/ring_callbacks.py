"""Ring callback endpoints: token exchange, account linking, webhooks, app homepage."""

import logging
import uuid
from datetime import UTC, datetime

from fastapi import APIRouter, Request
from fastapi.responses import HTMLResponse, JSONResponse

from app.config import get_settings
from app.data.encryptor import FernetEncryptor
from app.data.token_store import TokenStore
from app.models.schemas import (
    AccountLinkRequest,
    AccountLinkResponse,
    TokenExchangeRequest,
)
from app.services.hmac_verifier import HMACVerifier
from app.services.token_service import TokenService, UpstreamError

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/ring")


# ---------------------------------------------------------------------------
# Dependency helpers — create service instances from config
# ---------------------------------------------------------------------------


def _get_settings():
    """Return validated application settings."""
    return get_settings()


def _get_encryptor() -> FernetEncryptor:
    """Create a FernetEncryptor from the configured encryption key."""
    settings = _get_settings()
    return FernetEncryptor(settings.token_encryption_key)


def _get_token_store() -> TokenStore:
    """Create a TokenStore instance from config."""
    settings = _get_settings()
    encryptor = _get_encryptor()
    return TokenStore(db_path=settings.database_path, encryptor=encryptor)


def _get_token_service() -> TokenService:
    """Create a TokenService instance from config."""
    settings = _get_settings()
    token_store = _get_token_store()
    return TokenService(
        client_id=settings.ring_client_id,
        client_secret=settings.ring_client_secret,
        token_store=token_store,
    )


def _get_hmac_verifier() -> HMACVerifier:
    """Create an HMACVerifier from the configured HMAC key."""
    settings = _get_settings()
    return HMACVerifier(signing_key_b64=settings.ring_hmac_key)


# ---------------------------------------------------------------------------
# POST /ring/token-exchange
# ---------------------------------------------------------------------------


@router.post("/token-exchange")
async def token_exchange(request: TokenExchangeRequest) -> JSONResponse:
    """Receive authorization code from Ring and exchange for tokens.

    Returns HTTP 200 on success, HTTP 400 for invalid/expired codes,
    HTTP 502 for Ring upstream errors.
    """
    token_service = _get_token_service()

    try:
        await token_service.exchange_code(code=request.code, user_id="default")
        return JSONResponse(status_code=200, content={"status": "success"})
    except UpstreamError as exc:
        logger.error("Token exchange upstream error: %s", str(exc))
        return JSONResponse(status_code=502, content={"error": "upstream_error"})
    except Exception as exc:
        logger.error("Token exchange failed: %s", str(exc))
        return JSONResponse(status_code=400, content={"error": "invalid_code"})


# ---------------------------------------------------------------------------
# POST /ring/account-link
# ---------------------------------------------------------------------------


@router.post("/account-link")
async def account_link(request: AccountLinkRequest) -> JSONResponse:
    """Receive account linking request from Ring with HMAC-signed nonce.

    Verifies HMAC-SHA256 signature. On match, creates/updates user record
    and returns HTTP 200 with confirmation. On mismatch, returns HTTP 403.
    """
    hmac_verifier = _get_hmac_verifier()
    token_store = _get_token_store()

    if not hmac_verifier.verify(nonce=request.nonce, provided_signature=request.signature):
        logger.warning(
            "Account link HMAC verification failed for account_id=%s",
            request.account_id,
        )
        return JSONResponse(status_code=403, content={"error": "forbidden"})

    # Create or update user record
    user_id = request.partner_account_id or request.account_id
    await token_store.create_or_update_user(user_id=user_id, account_id=request.account_id)

    response = AccountLinkResponse(status="linked", account_id=request.account_id)
    return JSONResponse(status_code=200, content=response.model_dump())


# ---------------------------------------------------------------------------
# POST /ring/webhook
# ---------------------------------------------------------------------------


@router.post("/webhook")
async def webhook(request: Request) -> JSONResponse:
    """Receive real-time event notifications from Ring.

    Validates payload, logs event details, stores in TokenStore.
    Always returns HTTP 200 to prevent Ring retries.
    """
    token_store = _get_token_store()

    try:
        body = await request.json()
    except Exception:
        logger.warning("Webhook received non-JSON payload")
        return JSONResponse(status_code=200, content={"status": "received"})

    # Extract fields with sensible defaults
    event_type = body.get("event_type", "unknown")
    device_id = body.get("device_id", "unknown")
    timestamp = body.get("timestamp", datetime.now(UTC).isoformat())
    event_id = body.get("event_id", str(uuid.uuid4()))

    # Log the event
    logger.info(
        "Webhook event received: event_type=%s device_id=%s timestamp=%s event_id=%s",
        event_type,
        device_id,
        timestamp,
        event_id,
    )

    # Log unrecognized event types at WARNING
    known_event_types = {"motion", "ding", "device_status", "on_demand"}
    if event_type not in known_event_types:
        logger.warning("Unrecognized webhook event type: %s", event_type)

    # Store the event
    try:
        await token_store.save_event(
            event_id=event_id,
            event_type=event_type,
            device_id=device_id,
            timestamp=timestamp,
            payload=body,
        )
    except Exception as exc:
        logger.error("Failed to store webhook event: %s", str(exc))

    return JSONResponse(status_code=200, content={"status": "received"})


# ---------------------------------------------------------------------------
# GET /ring/app-homepage
# ---------------------------------------------------------------------------

_APP_HOMEPAGE_HTML = """<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>RingAppleTV - Ring Partner App</title>
    <style>
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 2rem;
            line-height: 1.6;
            color: #333;
        }
        h1 { color: #1C9BF6; }
        .setup-steps { background: #f5f5f5; padding: 1.5rem; border-radius: 8px; }
        .setup-steps ol { padding-left: 1.5rem; }
        .setup-steps li { margin-bottom: 0.75rem; }
    </style>
</head>
<body>
    <h1>RingAppleTV</h1>
    <p>
        View your Ring doorbell and camera live streams directly on your Apple TV.
        RingAppleTV brings real-time video from your Ring devices to the big screen,
        with motion and doorbell event notifications.
    </p>

    <div class="setup-steps">
        <h2>tvOS Setup Instructions</h2>
        <ol>
            <li>Install the RingAppleTV app on your Apple TV from the App Store.</li>
            <li>Open the Ring app on your phone and go to the Ring AppStore.</li>
            <li>Find and install the "RingAppleTV" partner app.</li>
            <li>Select the Ring devices you want to share with your Apple TV.</li>
            <li>Complete the authorization when prompted.</li>
            <li>Return to the RingAppleTV app on your Apple TV and tap "I've Completed Setup".</li>
        </ol>
    </div>
</body>
</html>"""


@router.get("/app-homepage")
async def app_homepage() -> HTMLResponse:
    """Serve the app homepage for Ring AppStore listing verification.

    Returns HTTP 200 with HTML containing app name, description,
    and tvOS setup instructions.
    """
    return HTMLResponse(content=_APP_HOMEPAGE_HTML, status_code=200)
