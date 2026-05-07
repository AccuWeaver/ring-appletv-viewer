# Ring AppStore Publishing Guide

This document describes the process for submitting the **Ring Camera Viewer** (RingAppleTV) partner app to the Ring AppStore, including registration, endpoint requirements, app metadata, and the end-to-end user experience.

---

## Table of Contents

1. [Partner Registration](#partner-registration)
2. [Required Endpoint URLs](#required-endpoint-urls)
3. [App Review and Approval Process](#app-review-and-approval-process)
4. [Required App Metadata](#required-app-metadata)
5. [End-to-End User Flow](#end-to-end-user-flow)
6. [Pre-Submission Checklist](#pre-submission-checklist)

---

## Partner Registration

### Overview

To list an app in the Ring AppStore, you must register as a Ring Partner through the Ring Partner Developer Portal. This establishes your partner account and provides the credentials needed for OAuth 2.0 integration.

### Registration Process

1. **Apply for Partner Access** — Submit a partner application through Ring's developer program. Provide your company/developer information, a description of your intended integration, and the target platform (tvOS).

2. **Receive Partner Credentials** — Once approved, Ring issues the following credentials:
   - `client_id` — Identifies your partner application
   - `client_secret` — Used for OAuth 2.0 token exchange (server-side only)
   - HMAC signing key — Used for account linking verification (base64-encoded)

3. **Store Credentials Securely** — Credentials are stored in `app-credentials.csv` for reference but must be loaded from environment variables in production. Never hardcode credentials in source code or commit them to version control.

4. **Register Endpoint URLs** — Provide Ring with the four required endpoint URLs (see next section). These must be publicly accessible HTTPS endpoints.

### Required Information for Registration

| Field | Description | Example |
|-------|-------------|---------|
| Partner Name | Your company or developer name | — |
| App Name | Display name in the Ring AppStore | Ring Camera Viewer |
| Contact Email | Technical contact for integration issues | — |
| Token Exchange URL | Endpoint that receives authorization codes | `https://your-domain.com/ring/token-exchange` |
| Account Link URL | Endpoint for HMAC-verified account linking | `https://your-domain.com/ring/account-link` |
| Webhook URL | Endpoint for real-time event notifications | `https://your-domain.com/ring/webhook` |
| App Homepage URL | Landing page for the AppStore listing | `https://your-domain.com/ring/app-homepage` |

---

## Required Endpoint URLs

All four endpoints must be registered with Ring during partner setup. They must be publicly accessible over HTTPS in production.

### 1. Token Exchange URL

- **Path:** `POST /ring/token-exchange`
- **Purpose:** Receives the OAuth 2.0 authorization code from Ring after a user authorizes the partner app in the Ring AppStore.
- **Behavior:** The backend exchanges the authorization code for access and refresh tokens by calling Ring's OAuth token endpoint with `grant_type=authorization_code`, the `code`, `client_id`, and `client_secret`. Tokens are encrypted and stored in the Token Store.
- **Expected Response:** HTTP 200 on successful processing; HTTP 4xx on invalid/expired codes.

### 2. Account Link URL

- **Path:** `POST /ring/account-link`
- **Purpose:** Receives HMAC-SHA256 signed account linking requests from Ring to bind a Ring user to the partner account.
- **Behavior:** The backend computes `HMAC-SHA256(signing_key, nonce)` and compares it (timing-safe) to the signature provided by Ring. On match, the user record is created or updated.
- **Expected Response:** HTTP 200 with confirmation payload (`{"status": "linked", "account_id": "..."}`) on success; HTTP 403 on HMAC mismatch.

### 3. Webhook URL

- **Path:** `POST /ring/webhook`
- **Purpose:** Receives real-time event notifications from Ring (motion detected, doorbell pressed, device status changes).
- **Behavior:** The backend validates the event payload, logs the event type/device/timestamp, and stores the event for later retrieval by the tvOS app.
- **Expected Response:** HTTP 200 for all deliveries (including unrecognized event types) to prevent Ring from retrying.

### 4. App Homepage URL

- **Path:** `GET /ring/app-homepage`
- **Purpose:** Serves a landing page for the partner app listing in the Ring AppStore. Ring requests this URL during AppStore listing verification.
- **Behavior:** Returns an HTML page displaying the app name, a brief description of functionality, and setup instructions for the tvOS app.
- **Expected Response:** HTTP 200 with valid HTML content.

---

## App Review and Approval Process

### Submission Steps

1. **Complete Integration** — Ensure all four endpoints are deployed, accessible, and functioning correctly.
2. **Prepare App Metadata** — Gather all required metadata (see next section).
3. **Submit for Review** — Submit the app through the Ring Partner Developer Portal with all metadata and endpoint URLs.
4. **Ring Verification** — Ring's team verifies:
   - All endpoint URLs respond correctly over HTTPS
   - Token exchange flow completes successfully with test authorization codes
   - Account linking HMAC verification works with test payloads
   - Webhook endpoint acknowledges test events with HTTP 200
   - App Homepage returns valid HTML with appropriate content
5. **Approval or Feedback** — Ring approves the listing or provides feedback on issues to resolve.

### Expected Timelines

| Phase | Estimated Duration |
|-------|-------------------|
| Initial review | 5–10 business days |
| Feedback/revision cycle | 3–5 business days per round |
| Final approval to listing | 1–2 business days after approval |
| Total (if no revisions needed) | ~2 weeks |

### Common Rejection Reasons

- Endpoints not accessible over HTTPS (HTTP-only or self-signed certificates)
- HMAC verification failing with Ring's test payloads
- Token exchange endpoint not returning HTTP 200 for valid codes
- Webhook endpoint returning non-200 status codes
- App Homepage missing required content (app name, description)
- Incomplete or inaccurate app metadata
- App description not matching actual functionality

---

## Required App Metadata

The following metadata must be provided when submitting the app to the Ring AppStore:

### App Identity

| Field | Value | Notes |
|-------|-------|-------|
| App Name | Ring Camera Viewer | Display name shown in the Ring AppStore |
| Developer Name | (Your name/company) | Shown on the listing page |
| App Version | 1.0.0 | Semantic versioning |
| Platform | tvOS (Apple TV) | Target platform for the integration |

### Description

Provide a clear, concise description of what the app does:

> View your Ring camera live streams on Apple TV. Ring Camera Viewer brings your Ring doorbells and security cameras to the big screen with real-time WebRTC streaming, device browsing, and event history.

### Visual Assets

| Asset | Specification |
|-------|---------------|
| App Icon | High-resolution PNG, square format (1024×1024 recommended) |
| Screenshots | 2–5 screenshots showing the app running on Apple TV (1920×1080) |
| Banner Image | Optional promotional banner for featured listings |

Screenshots should demonstrate:
- Device list/grid view showing Ring cameras
- Live stream view with camera feed
- Event history or recent activity view
- Login/setup instructions screen

### Categories and Tags

- **Category:** Smart Home / Security
- **Tags:** camera, live stream, security, doorbell, Apple TV

---

## End-to-End User Flow

This describes the complete experience from the Ring user's perspective:

### Step 1: Discovery

The user opens the Ring mobile app (iOS/Android) and navigates to the **Ring AppStore** section. They browse or search for partner integrations and find **Ring Camera Viewer**.

### Step 2: App Details

The user taps on the app listing and sees:
- App name and icon
- Description of functionality
- Screenshots of the tvOS app
- Link to the App Homepage for more information

### Step 3: Installation and Device Selection

1. The user taps **Install** (or **Enable**) on the partner app listing.
2. Ring presents a device selection screen where the user chooses which Ring devices (doorbells, cameras) to share with the partner app.
3. The user confirms their selection and authorizes the integration.

### Step 4: Account Linking (Automatic)

Behind the scenes:
1. Ring sends an account linking request to the partner's **Account Link URL** with an HMAC-signed nonce.
2. The partner backend verifies the HMAC signature and creates a user record.
3. Ring confirms the account link is established.

### Step 5: Token Exchange (Automatic)

Behind the scenes:
1. Ring sends the OAuth 2.0 authorization code to the partner's **Token Exchange URL**.
2. The partner backend exchanges the code for access and refresh tokens.
3. Tokens are encrypted and stored — the user's Ring devices are now accessible via the Partner API.

### Step 6: tvOS App Setup

1. The user opens **Ring Camera Viewer** on their Apple TV.
2. The app displays a setup screen: *"Complete setup in the Ring app"* with instructions to install the partner app from the Ring AppStore (if not already done).
3. The user taps **"I've completed setup"** (or the app polls automatically).
4. The tvOS app requests a token from the partner backend.
5. On success, the app transitions to the authenticated state and displays the user's Ring devices.

### Step 7: Ongoing Use

- The tvOS app uses the access token to call the Ring Partner API for device lists, live streams, and event history.
- The backend automatically refreshes tokens before they expire (proactive refresh within 5 minutes of expiry).
- Ring sends webhook events (motion, doorbell press) to the backend for future push notification support.

### Flow Diagram

```
Ring User                Ring App              Partner Backend         tvOS App
   │                       │                        │                    │
   ├── Browse AppStore ───►│                        │                    │
   ├── Install app ───────►│                        │                    │
   ├── Select devices ────►│                        │                    │
   │                       ├── Account Link ───────►│                    │
   │                       │   (HMAC nonce)         ├── Verify HMAC     │
   │                       │◄── 200 OK ────────────┤   Store user       │
   │                       ├── Token Exchange ─────►│                    │
   │                       │   (auth code)          ├── Exchange code    │
   │                       │◄── 200 OK ────────────┤   Store tokens     │
   │                       │                        │                    │
   │                       │                        │◄── GET /api/token ─┤
   │                       │                        ├── Return token ───►│
   │                       │                        │                    ├── Show devices
   │                       │                        │                    │
```

---

## Pre-Submission Checklist

Complete all items before submitting the app for Ring AppStore review:

### Backend Deployment

- [ ] Backend service is deployed to a production environment (cloud provider, VPS, or container platform)
- [ ] All endpoints are accessible over HTTPS with a valid TLS certificate (not self-signed)
- [ ] Backend is running and the health check endpoint (`GET /health`) returns HTTP 200
- [ ] Database (SQLite or equivalent) is initialized and writable

### Endpoint Verification

- [ ] `POST /ring/token-exchange` — Accepts authorization codes and returns HTTP 200
- [ ] `POST /ring/account-link` — Verifies HMAC signatures and returns HTTP 200 with confirmation payload
- [ ] `POST /ring/webhook` — Accepts event payloads and returns HTTP 200
- [ ] `GET /ring/app-homepage` — Returns HTTP 200 with HTML content including app name and description

### Credentials and Configuration

- [ ] `RING_CLIENT_ID` environment variable is set with the partner client ID
- [ ] `RING_CLIENT_SECRET` environment variable is set with the partner client secret
- [ ] `RING_HMAC_KEY` environment variable is set with the base64-encoded HMAC signing key
- [ ] `APP_API_KEY` environment variable is set for tvOS app authentication
- [ ] `TOKEN_ENCRYPTION_KEY` environment variable is set for Fernet encryption of stored tokens
- [ ] No credentials are hardcoded in source code or committed to version control

### HMAC Verification

- [ ] Account linking endpoint correctly computes `HMAC-SHA256(signing_key, nonce)`
- [ ] Signature comparison uses timing-safe comparison (`hmac.compare_digest`)
- [ ] Valid signatures return HTTP 200; invalid signatures return HTTP 403
- [ ] Tested with known nonce/signature pairs from Ring's documentation or test tools

### Security

- [ ] All endpoints served over HTTPS (TLS termination via reverse proxy or load balancer is acceptable)
- [ ] Input validation and sanitization is active on all endpoints
- [ ] Error responses do not expose internal details (no stack traces, file paths, or schema info)
- [ ] Rate limiting is configured on the token retrieval endpoint (`GET /api/token`)
- [ ] API key authentication is enforced on protected endpoints

### App Metadata

- [ ] App name, description, and developer name are finalized
- [ ] App icon (1024×1024 PNG) is prepared
- [ ] 2–5 tvOS screenshots (1920×1080) are captured
- [ ] App Homepage content is accurate and matches the app description

### tvOS App

- [ ] tvOS app is configured to point to the production backend URL
- [ ] tvOS app successfully retrieves tokens from the backend after Ring AppStore authorization
- [ ] tvOS app handles 401 responses by clearing tokens and showing re-authorization prompt
- [ ] tvOS app displays appropriate setup instructions for new users

---

## Additional Resources

- Ring Partner API documentation (provided during partner onboarding)
- Backend service README: `partner-auth-backend/README.md`
- Backend deployment guide: `partner-auth-backend/Dockerfile`
- tvOS app configuration: `RingAppleTV/Sources/Models/AppConfiguration.swift`
- Partner credentials reference: `RingAppleTV/app-credentials.csv` (do not commit to public repos)
