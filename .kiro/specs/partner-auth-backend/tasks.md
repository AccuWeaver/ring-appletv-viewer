# Implementation Plan: Partner Auth Backend

## Overview

Build a Python/FastAPI backend service that handles Ring Partner API OAuth 2.0 authentication on behalf of the RingAppleTV tvOS app, update the tvOS app to authenticate through this backend, and document the Ring AppStore publishing process. The backend uses SQLite for token storage with Fernet encryption at rest, HMAC-SHA256 for account linking verification, and a shared API key for tvOS ↔ backend authentication.

## Tasks

- [x] 1. Backend project scaffolding and configuration
  - [x] 1.1 Create `partner-auth-backend/` directory with Python project structure
    - Create `partner-auth-backend/` with subdirectories: `app/`, `app/routes/`, `app/services/`, `app/data/`, `app/models/`, `tests/`
    - Create `requirements.txt` with dependencies: fastapi, uvicorn, cryptography, pydantic, aiosqlite, httpx, slowapi
    - Create `Dockerfile` for containerized deployment
    - Create `.env.example` with all required environment variables documented
    - _Requirements: 6.1, 6.2, 6.7_

  - [x] 1.2 Implement configuration and environment variable validation in `app/config.py`
    - Define a `Settings` class that loads `RING_CLIENT_ID`, `RING_CLIENT_SECRET`, `RING_HMAC_KEY`, `APP_API_KEY`, `TOKEN_ENCRYPTION_KEY`, `DATABASE_PATH`, `LOG_LEVEL` from environment variables
    - Implement fail-fast startup validation: if any required variable is missing, raise an error listing all missing variables
    - _Requirements: 1.6, 2.6, 6.2, 6.8_

  - [x] 1.3 Write property test for fail-fast environment variable validation
    - **Property 7: Fail-fast environment variable validation**
    - For any non-empty subset of required env vars that is omitted, startup SHALL raise an error whose message contains every missing variable name
    - **Validates: Requirements 6.8**

  - [x] 1.4 Create FastAPI application entry point in `app/main.py`
    - Wire together all routers, middleware (request logging, rate limiting, input sanitization), and service dependencies
    - Add startup event that validates config and initializes the database
    - Add health check endpoint `GET /health` returning HTTP 200
    - _Requirements: 6.1, 6.4, 6.5_

  - [x] 1.5 Create `partner-auth-backend/README.md`
    - Document setup instructions, environment variables, example deployment commands, and local development workflow
    - _Requirements: 6.6_

- [x] 2. Checkpoint — Verify backend project scaffolding
  - Ensure the FastAPI app starts successfully with valid environment variables and `GET /health` returns 200. Ask the user if questions arise.

- [x] 3. Backend data layer (SQLite + Fernet encryption)
  - [x] 3.1 Implement `FernetEncryptor` in `app/data/encryptor.py`
    - `encrypt(plaintext: str) -> str` — encrypt a string, return base64-encoded ciphertext
    - `decrypt(ciphertext: str) -> str` — decrypt base64-encoded ciphertext, return plaintext
    - Initialize from `TOKEN_ENCRYPTION_KEY` environment variable
    - _Requirements: 9.4_

  - [x] 3.2 Write property test for Fernet encryption round-trip
    - **Property 6: Token encryption round-trip**
    - For any random string, `decrypt(encrypt(s)) == s` and `encrypt(s) != s`
    - **Validates: Requirements 9.4**

  - [x] 3.3 Implement `TokenStore` in `app/data/token_store.py`
    - Create SQLite schema: `users`, `tokens`, `webhook_events` tables (as defined in design)
    - Implement `save_tokens`, `get_tokens`, `update_tokens`, `invalidate` methods with Fernet encryption for access_token and refresh_token fields
    - Implement `save_event`, `get_recent_events` for webhook event storage
    - Use `aiosqlite` for async database access
    - _Requirements: 1.3, 6.3, 9.4_

  - [x] 3.4 Implement Pydantic data models in `app/models/`
    - `TokenExchangeRequest`, `AccountLinkRequest`, `AccountLinkResponse`, `TokenRecord`, `TokenResponse`, `WebhookEvent`, `RingOAuthTokenResponse` as defined in design
    - _Requirements: 1.1, 2.1, 3.5, 4.1_

- [x] 4. Backend services (TokenService, HMACVerifier)
  - [x] 4.1 Implement `HMACVerifier` in `app/services/hmac_verifier.py`
    - `verify(nonce: str, provided_signature: str) -> bool` using `hmac.compare_digest` for timing-safe comparison
    - Load HMAC signing key from config
    - _Requirements: 2.2, 2.5_

  - [x] 4.2 Write property test for HMAC verification correctness
    - **Property 2: HMAC verification correctness**
    - For any random key and nonce, HMACVerifier SHALL accept the correct HMAC-SHA256 signature and reject any signature differing by at least one byte
    - **Validates: Requirements 2.2, 2.5**

  - [x] 4.3 Implement `TokenService` in `app/services/token_service.py`
    - `exchange_code(code, user_id)` — POST to Ring OAuth endpoint with authorization code, store encrypted tokens
    - `get_valid_token(user_id)` — return valid token, proactively refresh if within 5 minutes of expiry
    - `refresh_token(user_id)` — refresh using stored refresh_token; on Ring 401, mark session invalid
    - `invalidate_session(user_id)` — mark session invalid in TokenStore
    - Use `httpx.AsyncClient` for Ring OAuth HTTP calls
    - _Requirements: 1.2, 3.1, 3.2, 3.3, 3.4_

  - [x] 4.4 Write property test for token exchange and persistence round-trip
    - **Property 1: Token exchange and persistence round-trip**
    - For any valid authorization code and OAuth response, exchanging the code and reading back from TokenStore SHALL produce a TokenRecord with matching decrypted values
    - **Validates: Requirements 1.2, 1.3, 3.3**

  - [x] 4.5 Write property test for proactive token refresh decision
    - **Property 4: Proactive token refresh decision (backend)**
    - For any TokenRecord with random expires_at, TokenService SHALL refresh if and only if current time is within 5 minutes of expiry or past it
    - **Validates: Requirements 3.2**

- [x] 5. Checkpoint — Verify data layer and services
  - Ensure all tests pass for encryptor, token store, HMAC verifier, and token service. Ask the user if questions arise.

- [x] 6. Backend Ring callback endpoints
  - [x] 6.1 Implement `POST /ring/token-exchange` in `app/routes/ring_callbacks.py`
    - Accept `TokenExchangeRequest`, call `TokenService.exchange_code`, return HTTP 200 on success
    - Return HTTP 400 for invalid/expired codes, HTTP 502 for Ring upstream errors
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5_

  - [x] 6.2 Implement `POST /ring/account-link` in `app/routes/ring_callbacks.py`
    - Accept `AccountLinkRequest`, verify HMAC signature via `HMACVerifier`
    - On match: create/update user record in TokenStore, return HTTP 200 with `AccountLinkResponse`
    - On mismatch: return HTTP 403 and log verification failure
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5_

  - [x] 6.3 Write property test for account linking persistence
    - **Property 3: Account linking persistence**
    - For any valid account linking request with correct HMAC, TokenStore SHALL contain the user record; re-linking with the same account_id SHALL update, not duplicate
    - **Validates: Requirements 2.3**

  - [x] 6.4 Implement `POST /ring/webhook` in `app/routes/ring_callbacks.py`
    - Accept webhook event payload, validate, log event type/device_id/timestamp, store in TokenStore
    - Always return HTTP 200 (even for unrecognized event types), log unrecognized types at WARNING
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_

  - [x] 6.5 Write property test for webhook event storage round-trip
    - **Property 5: Webhook event storage round-trip**
    - For any random webhook event payload, storing and retrieving SHALL preserve all original fields
    - **Validates: Requirements 4.2, 4.3**

  - [x] 6.6 Implement `GET /ring/app-homepage` in `app/routes/ring_callbacks.py`
    - Return HTTP 200 with HTML page containing app name, description, and tvOS setup instructions
    - _Requirements: 5.1, 5.2, 5.3_

- [x] 7. Backend app API endpoints
  - [x] 7.1 Implement API key authentication dependency in `app/services/auth.py`
    - `verify_api_key` FastAPI dependency that checks `Authorization: Bearer {key}` header against configured `APP_API_KEY`
    - Return HTTP 401 for missing or invalid API key
    - _Requirements: 3.6, 9.6_

  - [x] 7.2 Write property test for API key rejection
    - **Property 10: API key rejection**
    - For any random string not equal to the configured API key, the token endpoint SHALL return HTTP 401
    - **Validates: Requirements 9.6**

  - [x] 7.3 Implement `GET /api/token` in `app/routes/app_api.py`
    - Accept `user_id` query parameter (default: "default"), require valid API key
    - Call `TokenService.get_valid_token`, return `TokenResponse` with access_token, token_type, expires_at
    - Return HTTP 404 if no tokens exist, HTTP 401 if session invalid
    - _Requirements: 3.1, 3.2, 3.5, 3.6_

- [x] 8. Backend security (rate limiting, input validation, request logging)
  - [x] 8.1 Implement rate limiting middleware
    - Use `slowapi` to enforce max 60 requests/minute per user on `/api/token`
    - Return HTTP 429 with `retry_after` on limit exceeded
    - _Requirements: 9.5_

  - [x] 8.2 Implement input validation and sanitization middleware
    - Validate and sanitize all incoming request parameters (SQL injection patterns, script injection, null bytes)
    - Leverage Pydantic validation plus custom sanitization where needed
    - _Requirements: 9.2_

  - [x] 8.3 Write property test for input sanitization
    - **Property 8: Input sanitization**
    - For any request parameter containing SQL injection, script injection, or null bytes, the validation layer SHALL reject or sanitize the dangerous pattern
    - **Validates: Requirements 9.2**

  - [x] 8.4 Implement request logging middleware
    - Log timestamp, unique request ID, HTTP method, path for every request
    - Log full error details server-side only; return minimal error details to callers
    - _Requirements: 6.5, 9.3_

  - [x] 8.5 Write property test for request logging completeness
    - **Property 12: Request logging completeness**
    - For any HTTP request, the log entry SHALL contain timestamp, unique request ID, method, and path
    - **Validates: Requirements 6.5**

  - [x] 8.6 Write property test for error response minimality
    - **Property 9: Error response minimality**
    - For any error condition, the HTTP response SHALL NOT contain tracebacks, file paths, DB schema, or raw exception messages
    - **Validates: Requirements 9.3**

- [x] 9. Checkpoint — Verify all backend endpoints and security
  - Ensure all backend tests pass (property tests and unit tests). Run `pytest` from `partner-auth-backend/`. Ask the user if questions arise.

- [x] 10. Backend unit and integration tests
  - [x] 10.1 Write example-based endpoint tests in `tests/test_endpoints.py`
    - Token exchange with valid code returns 200
    - Token exchange with invalid code returns 400
    - Account link with valid HMAC returns 200 with confirmation payload
    - Token refresh failure (Ring 401) marks session invalid and returns 401
    - API key auth: valid key accepted, missing key rejected, wrong key rejected
    - Webhook with unrecognized event type returns 200
    - App homepage returns 200 with HTML containing app name and description
    - Health check returns 200
    - Rate limiting: 61st request in a minute returns 429
    - _Requirements: 1.4, 1.5, 2.4, 3.4, 3.6, 4.4, 4.5, 5.1, 5.2, 5.3, 6.4, 9.5_

  - [x] 10.2 Write integration tests in `tests/test_integration.py`
    - End-to-end token exchange flow with mocked Ring OAuth server
    - End-to-end account linking flow with real HMAC computation
    - Webhook delivery → storage → retrieval cycle
    - Startup with missing env vars → descriptive error and exit
    - _Requirements: 1.2, 2.2, 4.2, 6.8_

- [x] 11. tvOS app authentication update
  - [x] 11.1 Add backend configuration properties to `AppConfiguration.swift`
    - Add `authBackendBaseURL: String` (default: `"http://localhost:8000"`)
    - Add `authBackendAPIKey: String` (default: empty string)
    - Add `authBackendUserId: String` (default: `"default"`)
    - Update `init` and `Codable` conformance
    - _Requirements: 7.8_

  - [x] 11.2 Create `BackendTokenResponse` model in `Sources/Models/BackendTokenResponse.swift`
    - Define `BackendTokenResponse: Codable` with `accessToken`, `tokenType`, `expiresAt` (snake_case CodingKeys)
    - Implement `toDomain() -> AuthToken` converting ISO 8601 `expiresAt` to `Date`
    - _Requirements: 3.5, 7.4_

  - [x] 11.3 Update `AuthService` protocol in `Sources/Services/Protocols/AuthServiceProtocol.swift`
    - Remove `startDeviceCodeFlow()` and `pollForAuthorization(deviceCode:)` methods
    - Add `fetchTokenFromBackend() async throws -> AuthToken`
    - Keep `getValidToken()`, `logout()`, and `isAuthenticated`
    - _Requirements: 7.1_

  - [x] 11.4 Create `BackendAuthService` in `Sources/Services/Implementations/BackendAuthService.swift`
    - Implement `AuthService` protocol with backend-mediated token retrieval
    - `fetchTokenFromBackend()`: GET `{backendBaseURL}/api/token?user_id={userId}` with `Authorization: Bearer {apiKey}` header, decode `BackendTokenResponse`, convert to `AuthToken`, store in Keychain + memory cache
    - `getValidToken()`: check memory cache → Keychain → if expired/near-expiry (60s), call `fetchTokenFromBackend()`; on 401 from backend, clear tokens and throw unauthorized
    - `logout()`: clear Keychain and memory cache
    - `isAuthenticated`: check memory cache and Keychain for non-expired token
    - _Requirements: 7.1, 7.3, 7.4, 7.5, 7.6, 7.7_

  - [x] 11.5 Update `AuthViewModel` in `Sources/ViewModels/AuthViewModel.swift`
    - Remove `deviceCodeInfo` and `isPolling` published properties
    - Add `setupInstructionsVisible: Bool` published property
    - Replace `startLinking()` with `showSetupInstructions()` that sets `setupInstructionsVisible = true`
    - Add `checkBackendForToken()` that calls `authService.fetchTokenFromBackend()` and updates state
    - Keep `checkExistingAuth()` and `logout()` with updated logic
    - _Requirements: 7.1, 7.2, 7.3_

  - [x] 11.6 Update `LoginView` in `Sources/Views/Authentication/LoginView.swift`
    - Replace device code display with setup instructions: "Complete setup in the Ring app" with step-by-step instructions
    - Replace "Link Account" button with "I've Completed Setup" button that calls `viewModel.checkBackendForToken()`
    - Remove QR code generation and device code polling UI
    - Add retry/loading states for backend token fetch
    - _Requirements: 7.2, 7.3_

  - [x] 11.7 Update `ServiceContainer` to use `BackendAuthService`
    - Replace `DefaultAuthService` instantiation with `BackendAuthService` using configuration properties
    - Pass `backendBaseURL`, `apiKey`, `userId` from `AppConfiguration`
    - Wire `keychainService` dependency
    - _Requirements: 7.1, 7.8_

- [x] 12. Checkpoint — Verify tvOS app compiles
  - Ensure the tvOS app compiles successfully with `swift build` from `RingAppleTV/`. Ask the user if questions arise.

- [x] 13. tvOS app tests
  - [x] 13.1 Write unit tests for `BackendAuthService`
    - Test `fetchTokenFromBackend()` stores token in Keychain after successful fetch
    - Test `getValidToken()` returns cached token when not near expiry
    - Test `getValidToken()` fetches from backend when token is near expiry (within 60s)
    - Test 401 response clears tokens and transitions to unauthenticated
    - Test API key is included in Authorization header
    - Test `BackendTokenResponse.toDomain()` correctly converts ISO 8601 dates
    - _Requirements: 7.3, 7.4, 7.5, 7.6, 7.7_

- [x] 14. Ring AppStore publishing documentation
  - [x] 14.1 Create `docs/RING_APPSTORE_PUBLISHING.md`
    - Document partner registration process and required information
    - List all required endpoint URLs: Token Exchange URL, Account Link URL, Webhook URL, App Homepage URL
    - Describe app review and approval process with expected timelines
    - Document required app metadata: name, description, icon, screenshots
    - Describe end-to-end user flow from Ring user's perspective
    - Include pre-submission checklist: backend deployed, endpoints accessible, credentials configured, HMAC verification working
    - _Requirements: 8.1, 8.2, 8.3, 8.4, 8.5, 8.6, 8.7_

- [x] 15. Final checkpoint — Ensure all tests pass
  - Run `pytest` from `partner-auth-backend/` for all backend tests. Verify tvOS app compiles with `swift build` from `RingAppleTV/`. Ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Backend uses Python (FastAPI, pytest, Hypothesis for PBT); tvOS uses Swift (XCTest)
- Each task references specific requirements for traceability
- Property-based tests use Hypothesis with minimum 100 iterations per property
- Checkpoints ensure incremental validation at key milestones
- The existing `PartnerAPIClient`, WHEP streaming, device/event services remain unchanged
