# Login MFA Debug Checklist

## Changes Made
I've added comprehensive logging to help debug the MFA login issue.

### Files Modified:
1. **AuthViewModel.swift** - Added debug prints throughout the `login()` method
2. **DefaultRingAPIClient.swift** - Added response body logging for errors and decoding
3. **AuthViewModel.swift** - Added logging to `isAuthenticated` computed property

## How to Debug

### Step 1: Run the App and Attempt Login
1. Launch the app
2. Enter your email and password
3. When prompted for 2FA code, enter it
4. Watch the console for log messages

### Step 2: Look for These Log Patterns

#### ✅ **Successful Login Pattern:**
```
🔐 [AuthViewModel] Attempting login with 2FA code
✅ [AuthViewModel] 2FA login successful, token received
✅ [AuthViewModel] State updated to .loaded, requiresTwoFactor = false
🔍 [AuthViewModel] isAuthenticated called, returning: true, state: loaded(...)
```

#### ❌ **Failed Login Patterns:**

**Invalid MFA Code:**
```
❌ [AuthViewModel] RingAPIError caught: twoFactorInvalid
⚠️ [AuthViewModel] Invalid 2FA code
```

**Network Error:**
```
Network error: [description]
❌ [AuthViewModel] RingAPIError caught: networkError(...)
```

**Decoding Error (API changed):**
```
Decoding error: [description]
Failed to decode response body: {...}
❌ [AuthViewModel] RingAPIError caught: decodingError(...)
```

## Common Issues and Solutions

### Issue 1: Login Succeeds but Returns to Login Screen

**Symptoms:**
- Console shows "✅ 2FA login successful"
- But `isAuthenticated` returns `false`
- UI shows login screen again

**Cause:** State is loaded but `ContentView` isn't observing the change

**Solution:** Check that `ServiceContainer` properly propagates the `authViewModel` changes. The issue might be:
```swift
// In ContentView, this should trigger a re-render:
if container.authViewModel.isAuthenticated { ... }
```

Make sure `ServiceContainer` is a `@StateObject` or `@ObservedObject` in the parent.

### Issue 2: Error is Silent (No Message Shown)

**Symptoms:**
- Console shows error
- But UI doesn't show error message

**Cause:** Error state isn't being displayed or viewModel state isn't observed

**Solution:** Check that LoginView properly observes viewModel:
```swift
if case .error(let message) = viewModel.state {
    Text(message)...
}
```

### Issue 3: API Returns Unexpected Response

**Symptoms:**
- Console shows "Response status 200" (or other code)
- But decoding fails or shows unexpected body

**Possible Ring API Changes:**
- Ring might have changed their 2FA implementation
- Different headers might be required
- Response format might have changed

**Next Steps:**
1. Check the response body in console logs
2. Compare with Ring API documentation (if available)
3. Try different header formats for 2FA

### Issue 4: 2FA Code Format Issue

The current implementation sends the 2FA code as a header:
```swift
request.setValue(twoFactorCode, forHTTPHeaderField: "2fa-code")
```

Some Ring API endpoints might expect it differently:
- In the request body as a parameter
- Different header name
- Different format (e.g., prefixed, padded)

## Verification Steps

After adding the logs, verify:

1. ✅ Email/password are being sent correctly (initial auth)
2. ✅ 412 status triggers `twoFactorRequired` correctly  
3. ✅ UI shows 2FA input field
4. ✅ 2FA code is captured and sent in subsequent request
5. ✅ Response is received and decoded
6. ✅ Token is stored in AuthService
7. ✅ AuthViewModel state updates to `.loaded`
8. ✅ `isAuthenticated` returns `true`
9. ✅ ContentView re-renders with MainTabView

## Additional Debug Points

If the above logs don't reveal the issue, add these additional checks:

### In DefaultAuthService.swift:
```swift
func login(email: String, password: String, twoFactorCode: String) async throws -> AuthToken {
    print("🔐 [AuthService] login with 2FA called")
    let response = try await apiClient.authenticate(email: email, password: password, twoFactorCode: twoFactorCode)
    print("✅ [AuthService] Got response: \(response)")
    let token = response.toDomain()
    print("✅ [AuthService] Converted to domain token")
    try storeToken(token)
    print("✅ [AuthService] Token stored")
    return token
}
```

### In ContentView.swift:
```swift
var body: some View {
    Group {
        if container.authViewModel.isAuthenticated {
            print("✅ [ContentView] Showing MainTabView")
            MainTabView(container: container)
        } else {
            print("⚠️ [ContentView] Showing LoginView")
            LoginView(viewModel: container.authViewModel)
        }
    }
    .task {
        await container.authViewModel.checkExistingAuth()
    }
}
```

Note: SwiftUI doesn't allow prints in the body directly, so you'd need to use `.onAppear { print(...) }` instead.

## Quick Test

To rule out Ring API issues, try this simple test:
1. Clear any stored credentials
2. Start fresh login flow
3. Use an INCORRECT 2FA code first - you should see error message
4. Then use the CORRECT 2FA code - should login successfully

If incorrect code doesn't show an error, the issue is in error handling/display.
If correct code doesn't login, the issue is in the success path.
