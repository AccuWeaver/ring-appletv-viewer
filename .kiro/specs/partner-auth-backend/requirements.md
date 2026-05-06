# Requirements Document

## Introduction

This document specifies the requirements for building a companion backend service that handles Ring Partner API OAuth 2.0 authentication on behalf of the RingAppleTV tvOS application, updating the tvOS app to authenticate through this backend instead of directly with Ring, and documenting the Ring AppStore publishing process.

The Ring Partner API uses the OAuth 2.0 Authorization Code flow — not the Device Authorization Grant currently implemented in the tvOS app. The actual flow is: a Ring user installs the partner app from the Ring AppStore, selects devices to share, and Ring sends an authorization code to the partner's registered Token Exchange URL. The partner backend exchanges that code for access and refresh tokens. Account linking uses HMAC-SHA256 nonce verification to bind the Ring user to the partner's account. The tvOS app cannot participate in this flow directly because it requires a server-side callback endpoint, HMAC signature verification, and secure storage of the `client_secret` and HMAC signing key. A lightweight backend service (Python or Node.js) bridges this gap.

The existing tvOS app already has the Partner API client, WHEP streaming, device discovery, and event/media retrieval working. The only missing piece is obtaining tokens through the correct Ring Partner API OAuth flow.

## Glossary

- **Auth_Backend**: The companion backend service (Python or Node.js) that handles Ring Partner API OAuth 2.0 token exchange, token refresh, account linking, and webhook reception on behalf of the tvOS app
- **Token_Exchange_Endpoint**: The backend URL registered with Ring as the Token Exchange URL; Ring sends authorization codes here after a user authorizes the partner app in the Ring AppStore
- **Account_Link_Endpoint**: The backend URL registered with Ring as the Account Link URL; receives HMAC-SHA256 signed nonce payloads to bind a Ring user to a partner account
- **Webhook_Endpoint**: The backend URL registered with Ring as the Webhook URL; receives real-time event notifications (motion, doorbell press, device status changes)
- **App_Homepage_Endpoint**: The backend URL registered with Ring as the App Homepage URL; serves a landing page or redirect for the partner app listing in the Ring AppStore
- **HMAC_Nonce_Verification**: The process of verifying a Ring-provided nonce using HMAC-SHA256 with the partner's signing key to confirm the authenticity of an account linking request
- **Authorization_Code_Exchange**: The OAuth 2.0 process where the backend exchanges a short-lived authorization code (received from Ring) for an access token and refresh token pair
- **Ring_AppStore**: The marketplace within the Ring app where users discover and install partner integrations
- **Partner_Credentials**: The set of `client_id`, `client_secret`, and HMAC signing key issued to the partner, stored in `app-credentials.csv`
- **Token_Store**: The backend's persistent storage for per-user access tokens and refresh tokens, keyed by a partner-defined user identifier
- **tvOS_Auth_Client**: The updated authentication layer in the tvOS app that retrieves and refreshes tokens from the Auth_Backend instead of directly from Ring's OAuth server

## Requirements

### Requirement 1: Backend Token Exchange Endpoint

**User Story:** As the Ring platform, I want to send authorization codes to the partner's Token Exchange URL after a user authorizes the app, so that the partner can obtain OAuth tokens on behalf of the user.

#### Acceptance Criteria

1. THE Auth_Backend SHALL expose an HTTP POST endpoint at a configurable path (e.g., `/ring/token-exchange`) that accepts the authorization code and related parameters sent by Ring after user authorization
2. WHEN the Auth_Backend receives a valid authorization code from Ring, THE Auth_Backend SHALL exchange it for an access token and refresh token by sending a POST request to Ring's OAuth token endpoint with `grant_type=authorization_code`, the `code`, `client_id`, and `client_secret`
3. WHEN the token exchange succeeds, THE Auth_Backend SHALL persist the access token, refresh token, token expiry time, and associated user identifier in the Token_Store
4. WHEN the token exchange succeeds, THE Auth_Backend SHALL return an HTTP 200 response to Ring to acknowledge successful processing
5. IF the authorization code is invalid or expired, THEN THE Auth_Backend SHALL return an appropriate HTTP error response and log the failure with the error details
6. THE Auth_Backend SHALL load the `client_id` and `client_secret` from environment variables or a secure configuration source, not from hardcoded values in source code

### Requirement 2: Backend Account Linking with HMAC Verification

**User Story:** As a partner developer, I want the backend to verify Ring account linking requests using HMAC-SHA256, so that only authentic Ring-initiated requests can bind a Ring user to a partner account.

#### Acceptance Criteria

1. THE Auth_Backend SHALL expose an HTTP endpoint at a configurable path (e.g., `/ring/account-link`) that receives account linking requests from Ring containing a nonce and user information
2. WHEN the Auth_Backend receives an account linking request, THE Auth_Backend SHALL compute an HMAC-SHA256 signature of the nonce using the partner's HMAC signing key and compare it to the signature provided by Ring
3. WHEN the HMAC signature matches, THE Auth_Backend SHALL create or update the association between the Ring user and the partner account in the Token_Store
4. WHEN the HMAC signature matches, THE Auth_Backend SHALL return an HTTP 200 response with the required confirmation payload to Ring
5. IF the HMAC signature does not match, THEN THE Auth_Backend SHALL reject the request with an HTTP 403 response and log the verification failure
6. THE Auth_Backend SHALL load the HMAC signing key from environment variables or a secure configuration source, not from hardcoded values in source code

### Requirement 3: Backend Token Refresh and Management

**User Story:** As a tvOS app user, I want the backend to keep my Ring tokens valid, so that the app can access my Ring devices without requiring me to re-authorize.

#### Acceptance Criteria

1. THE Auth_Backend SHALL expose an HTTP endpoint (e.g., `GET /api/token?user_id={id}`) that returns a valid access token for the specified user
2. WHEN the stored access token for a user is within 5 minutes of expiry or already expired, THE Auth_Backend SHALL proactively refresh it by sending a POST request to Ring's OAuth token endpoint with `grant_type=refresh_token`, the stored `refresh_token`, `client_id`, and `client_secret`
3. WHEN a token refresh succeeds, THE Auth_Backend SHALL update the Token_Store with the new access token, refresh token, and expiry time
4. IF a token refresh fails with an HTTP 401 response from Ring, THEN THE Auth_Backend SHALL mark the user's session as invalid in the Token_Store and return an HTTP 401 response to the caller indicating re-authorization is required
5. WHEN the Auth_Backend returns a token to the tvOS app, THE Auth_Backend SHALL include the access token, token type, and expiry time in the response body
6. THE Auth_Backend SHALL authenticate requests from the tvOS app using a shared API key or equivalent mechanism to prevent unauthorized token retrieval

### Requirement 4: Backend Webhook Endpoint

**User Story:** As a tvOS app user, I want the backend to receive real-time event notifications from Ring, so that the app can eventually display push notifications for motion and doorbell events.

#### Acceptance Criteria

1. THE Auth_Backend SHALL expose an HTTP POST endpoint at a configurable path (e.g., `/ring/webhook`) that receives event notifications from Ring (motion detected, doorbell pressed, device status changes)
2. WHEN the Auth_Backend receives a webhook event, THE Auth_Backend SHALL validate the event payload and log the event type, device identifier, and timestamp
3. WHEN the Auth_Backend receives a webhook event, THE Auth_Backend SHALL store the event in a retrievable format so the tvOS app can poll for recent events
4. IF the Auth_Backend receives a webhook event with an unrecognized event type, THEN THE Auth_Backend SHALL log the raw payload and return an HTTP 200 response without raising an error
5. THE Auth_Backend SHALL return an HTTP 200 response to Ring within a reasonable timeframe for all valid webhook deliveries to prevent Ring from retrying

### Requirement 5: Backend App Homepage Endpoint

**User Story:** As a Ring user browsing the Ring AppStore, I want to see a landing page for the partner app, so that I can understand what the app does before installing it.

#### Acceptance Criteria

1. THE Auth_Backend SHALL expose an HTTP GET endpoint at a configurable path (e.g., `/ring/app-homepage`) that serves a landing page or redirect for the partner app listing
2. THE landing page SHALL display the app name, a brief description of the app's functionality, and setup instructions for the tvOS app
3. WHEN Ring requests the App Homepage URL during AppStore listing verification, THE Auth_Backend SHALL return an HTTP 200 response with valid HTML content

### Requirement 6: Backend Deployment and Configuration

**User Story:** As a developer, I want the backend service to be easy to deploy and configure, so that I can run it locally for development and deploy it to a cloud provider for production.

#### Acceptance Criteria

1. THE Auth_Backend SHALL be implemented as a lightweight service in Python (Flask/FastAPI) or Node.js (Express) with minimal dependencies
2. THE Auth_Backend SHALL read all sensitive configuration (client_id, client_secret, HMAC signing key, API key for tvOS app authentication) from environment variables
3. THE Auth_Backend SHALL use a file-based Token_Store (e.g., SQLite or JSON file) for simplicity, with the storage path configurable via environment variable
4. THE Auth_Backend SHALL include a health check endpoint (e.g., `GET /health`) that returns HTTP 200 when the service is running
5. THE Auth_Backend SHALL log all incoming requests and errors with timestamps and request identifiers for debugging
6. THE Auth_Backend SHALL include a `README.md` with setup instructions, environment variable documentation, and example deployment commands
7. THE Auth_Backend SHALL include a `Dockerfile` for containerized deployment
8. IF a required environment variable is missing at startup, THEN THE Auth_Backend SHALL fail fast with a descriptive error message listing the missing variables

### Requirement 7: tvOS App Authentication Update

**User Story:** As a tvOS app user, I want the app to get its Ring tokens from the partner backend, so that authentication works through the correct Ring Partner API OAuth flow.

#### Acceptance Criteria

1. THE tvOS_Auth_Client SHALL replace the Device Authorization Grant flow with a backend-mediated token retrieval flow, fetching tokens from the Auth_Backend's token endpoint
2. THE tvOS_Auth_Client SHALL display a setup instruction screen directing the user to install the partner app from the Ring AppStore and complete device authorization there, instead of displaying a device code
3. WHEN the user indicates they have completed Ring AppStore authorization, THE tvOS_Auth_Client SHALL request a valid token from the Auth_Backend using the configured user identifier
4. WHEN the Auth_Backend returns a valid token, THE tvOS_Auth_Client SHALL persist the token in the tvOS Keychain and update the in-memory cache, consistent with the existing token storage pattern
5. WHEN the stored access token is within 60 seconds of expiry, THE tvOS_Auth_Client SHALL request a fresh token from the Auth_Backend rather than refreshing directly with Ring's OAuth server
6. WHEN the Auth_Backend returns an HTTP 401 response indicating the session is invalid, THE tvOS_Auth_Client SHALL clear all stored tokens and transition the app to the unauthenticated state, prompting the user to re-authorize through the Ring AppStore
7. THE tvOS_Auth_Client SHALL send the shared API key in the `Authorization` header (or equivalent) when communicating with the Auth_Backend
8. THE tvOS_Auth_Client SHALL configure the Auth_Backend base URL via a build-time configuration constant or environment variable, supporting both local development and production URLs

### Requirement 8: Ring AppStore Publishing Documentation

**User Story:** As a developer, I want clear documentation on the Ring AppStore publishing process, so that I can submit the partner app for listing and understand the requirements.

#### Acceptance Criteria

1. THE documentation SHALL describe the Ring AppStore partner registration process, including where to register and what information is required
2. THE documentation SHALL list all required endpoint URLs that must be registered with Ring: Token Exchange URL, Account Link URL, Webhook URL, and App Homepage URL
3. THE documentation SHALL describe the app review and approval process, including expected timelines and common rejection reasons where known
4. THE documentation SHALL describe the required app metadata for the Ring AppStore listing (app name, description, icon, screenshots)
5. THE documentation SHALL describe how the end-to-end user flow works from the Ring user's perspective: discovering the app in the Ring AppStore, installing it, selecting devices, and the resulting account linking and token exchange
6. THE documentation SHALL include a checklist of prerequisites that must be completed before submitting the app for Ring AppStore review (backend deployed, endpoints accessible, credentials configured, HMAC verification working)
7. THE documentation SHALL be stored as a Markdown file in the repository (e.g., `docs/RING_APPSTORE_PUBLISHING.md`)

### Requirement 9: Backend Security

**User Story:** As a developer, I want the backend to follow security best practices, so that partner credentials and user tokens are protected.

#### Acceptance Criteria

1. THE Auth_Backend SHALL serve all endpoints over HTTPS in production (TLS termination may be handled by a reverse proxy or load balancer)
2. THE Auth_Backend SHALL validate and sanitize all incoming request parameters to prevent injection attacks
3. THE Auth_Backend SHALL return minimal error details in HTTP responses to external callers, logging full error details server-side only
4. THE Token_Store SHALL encrypt stored tokens at rest when using file-based storage, or rely on the underlying database's encryption capabilities
5. THE Auth_Backend SHALL enforce rate limiting on the token retrieval endpoint to prevent abuse (e.g., maximum 60 requests per minute per user)
6. IF the Auth_Backend receives a request with an invalid or missing API key on protected endpoints, THEN THE Auth_Backend SHALL return an HTTP 401 response without processing the request

