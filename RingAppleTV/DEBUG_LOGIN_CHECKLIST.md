# Device Code Flow Debug Checklist

## Overview
The app uses OAuth 2.0 Device Authorization Grant (RFC 8628) for account linking.
The user sees a code on the TV, authorizes on their phone/computer, and the app polls for the token.

### Key Components:
1. **AuthViewModel.swift** — Manages the device code flow UI state
2. **PartnerAPIClient.swift** — Handles HTTP requests to the OAuth and Partner API endpoints
3. **DefaultAuthService.swift** — Orchestrates the device code flow lifecycle

## How to Debug

### Step 1: Start the Device Code Flow
1. Launch the app
2. The app requests a device code from `oauth.ring.com/oauth/device/code`
3. A user code and verification URL are displayed on screen
4. Watch the console for log messages

### Step 2: Look for These Log Patterns

#### ✅ **Successful Flow:**
```
🔐 [AuthViewModel] Starting device code flow
✅ [AuthViewModel] Device code received, displaying user code
🔄 [AuthViewModel] Polling for authorization...
✅ [AuthViewModel] Authorization complete, token received
✅ [AuthViewModel] State updated to .loaded
🔍 [AuthViewModel] isAuthenticated called, returning: true
```

#### ❌ **Failed Flow Patterns:**

**Authorization Pending (expected during polling):**
```
🔄 [AuthViewModel] Authorization pending, continuing to poll...
```

**Slow Down (polling too fast):**
```
⚠️ [AuthViewModel] Slow down received, increasing polling interval by 5s
```

**Device Code Expired:**
```
❌ [AuthViewModel] Device code expired, prompting user to restart
```

**Network Error:**
```
❌ [AuthViewModel] PartnerAPIError caught: networkError(...)
```

## Common Issues and Solutions

### Issue 1: Device Code Not Displayed

**Symptoms:**
- Console shows error requesting device code
- No user code shown on screen

**Cause:** OAuth server may be unreachable or client_id is incorrect

**Solution:** Check network connectivity and verify the client_id configuration.

### Issue 2: Polling Never Completes

**Symptoms:**
- Console shows repeated "Authorization pending" messages
- User has completed authorization on their phone

**Cause:** Polling may be using wrong device_code or token endpoint

**Solution:** Verify the device_code and token endpoint URL in console logs.

### Issue 3: Token Received but App Shows Login Screen

**Symptoms:**
- Console shows "✅ Authorization complete"
- But `isAuthenticated` returns `false`

**Cause:** Token may not be stored correctly in Keychain

**Solution:** Check Keychain storage logs and verify token persistence.

## Verification Steps

1. ✅ Device code request sent to correct OAuth endpoint
2. ✅ User code and verification URL displayed on screen
3. ✅ Polling starts at the correct interval
4. ✅ Slow down responses increase the polling interval
5. ✅ Token is received and stored in Keychain
6. ✅ AuthViewModel state updates to `.loaded`
7. ✅ `isAuthenticated` returns `true`
8. ✅ ContentView re-renders with MainTabView
