# Partner Auth Backend

A lightweight Python/FastAPI backend service that handles Ring Partner API OAuth 2.0 authentication on behalf of the RingAppleTV tvOS application. It receives authorization codes from Ring, exchanges them for tokens, manages token refresh, handles account linking with HMAC-SHA256 verification, and stores encrypted tokens in SQLite.

## Prerequisites

- Python 3.12+
- [uv](https://docs.astral.sh/uv/) (Python package manager)
- Docker (optional, for containerized deployment)

## Local Development Setup

### 1. Install dependencies

```bash
cd partner-auth-backend
uv sync
```

This installs all runtime and dev dependencies defined in `pyproject.toml`.

### 2. Configure environment variables

```bash
cp .env.example .env
```

Edit `.env` and fill in your actual values (see [Environment Variables](#environment-variables) below).

### 3. Start the development server

```bash
uv run uvicorn app.main:app --reload
```

The server starts at `http://localhost:8000`. The `--reload` flag enables auto-restart on code changes.

### 4. Verify it's running

```bash
curl http://localhost:8000/health
```

Should return HTTP 200 with a JSON health status.

## Running Tests

```bash
uv run pytest
```

This runs all unit tests, property-based tests (Hypothesis), and integration tests in the `tests/` directory.

To run with verbose output:

```bash
uv run pytest -v
```

To run a specific test file:

```bash
uv run pytest tests/test_endpoints.py
```

## Environment Variables

| Variable | Required | Default | Description |
|----------|----------|---------|-------------|
| `RING_CLIENT_ID` | Yes | — | Ring Partner API client ID |
| `RING_CLIENT_SECRET` | Yes | — | Ring Partner API client secret |
| `RING_HMAC_KEY` | Yes | — | Base64-encoded HMAC-SHA256 signing key for account linking verification |
| `APP_API_KEY` | Yes | — | Shared API key for tvOS app ↔ backend authentication |
| `TOKEN_ENCRYPTION_KEY` | Yes | — | Fernet key for encrypting tokens at rest. Generate with: `python -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())"` |
| `DATABASE_PATH` | No | `./tokens.db` | Path to the SQLite database file |
| `LOG_LEVEL` | No | `INFO` | Logging level (DEBUG, INFO, WARNING, ERROR, CRITICAL) |

If any required environment variable is missing at startup, the service exits immediately with an error listing all missing variables.

## Docker Deployment

### Build the image

```bash
docker build -t partner-auth-backend .
```

### Run the container

```bash
docker run -d \
  --name partner-auth-backend \
  -p 8000:8000 \
  -v $(pwd)/data:/data \
  -e RING_CLIENT_ID=your_client_id \
  -e RING_CLIENT_SECRET=your_client_secret \
  -e RING_HMAC_KEY=your_hmac_key \
  -e APP_API_KEY=your_api_key \
  -e TOKEN_ENCRYPTION_KEY=your_fernet_key \
  -e DATABASE_PATH=/data/tokens.db \
  partner-auth-backend
```

The container exposes port 8000 and stores the SQLite database in `/data/` (mounted as a volume for persistence).

## API Endpoints

### Health Check

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/health` | None | Returns HTTP 200 when the service is running |

### Ring Callback Endpoints

These endpoints are registered with Ring during partner app setup.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/ring/token-exchange` | None (Ring-initiated) | Receives authorization codes from Ring and exchanges them for OAuth tokens |
| POST | `/ring/account-link` | HMAC-SHA256 verification | Receives account linking requests; verifies HMAC signature and binds Ring user to partner account |
| POST | `/ring/webhook` | None (Ring-initiated) | Receives real-time event notifications (motion, doorbell, device status) |
| GET | `/ring/app-homepage` | None | Serves the app landing page for the Ring AppStore listing |

### App API Endpoints

Used by the tvOS app to retrieve tokens.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/token` | API Key (`Authorization: Bearer {key}`) | Returns a valid access token for the specified user. Accepts `user_id` query parameter (default: `"default"`). Proactively refreshes tokens within 5 minutes of expiry. |

## Project Structure

```text
partner-auth-backend/
├── app/
│   ├── main.py              # FastAPI application entry point
│   ├── config.py            # Environment variable validation
│   ├── routes/
│   │   ├── ring_callbacks.py  # Ring callback endpoints
│   │   └── app_api.py        # tvOS app API endpoints
│   ├── services/
│   │   ├── token_service.py   # Token lifecycle management
│   │   ├── hmac_verifier.py   # HMAC-SHA256 verification
│   │   └── auth.py           # API key authentication
│   ├── data/
│   │   ├── token_store.py     # SQLite persistence layer
│   │   └── encryptor.py       # Fernet encryption/decryption
│   └── models/               # Pydantic data models
├── tests/                    # Unit, property-based, and integration tests
├── pyproject.toml            # Project dependencies (uv)
├── Dockerfile                # Container build definition
├── .env.example              # Environment variable template
└── README.md                 # This file
```
