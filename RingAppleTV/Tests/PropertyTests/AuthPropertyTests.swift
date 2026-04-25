import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Generators

/// Generates an expired `AuthToken` (expiresAt in the past).
private let expiredTokenGen: Gen<AuthToken> = Gen<AuthToken>.compose { composer in
    let pastOffset = composer.generate(using: Int.arbitrary.suchThat { $0 > 60 && $0 < 1_000_000 })
    return AuthToken(
        accessToken: composer.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
        refreshToken: composer.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
        expiresAt: Date().addingTimeInterval(-Double(pastOffset)),
        scope: composer.generate(using: String?.arbitrary),
        tokenType: "Bearer"
    )
}

// MARK: - Property Tests

/// Property-based tests for token refresh behaviour.
///
/// **Property 2**: For any expired `AuthToken` where the refresh token is still
/// valid, calling `getValidToken()` should return an `AuthToken` whose
/// `isExpired` is `false` and whose `expiresAt` is in the future.
///
/// Validates: FR-1.2.1 (automatic token refresh), FR-1.2.5 (transparent refresh).
final class AuthPropertyTests: XCTestCase {

    /// Feature: AppleTVRing, Property 2: Token refresh always yields non-expired token
    func testTokenRefreshAlwaysYieldsNonExpiredToken() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        property("Feature: AppleTVRing, Property 2: Token refresh always yields non-expired token")
            <- forAll(expiredTokenGen) { (expiredToken: AuthToken) in
                // Set up fresh mocks for each iteration
                let mockAPI = MockRingAPIClient()
                let mockKeychain = MockKeychainService()

                // Configure the mock API to return a fresh token (1 hour expiry)
                let freshResponse = AuthTokenResponse(
                    accessToken: "refreshed_\(UUID().uuidString)",
                    refreshToken: "new_refresh_\(UUID().uuidString)",
                    expiresIn: 3600,
                    scope: "client",
                    tokenType: "Bearer"
                )
                mockAPI.refreshTokenResult = .success(freshResponse)

                // Store the expired token in the keychain
                guard let data = try? encoder.encode(expiredToken) else { return false }
                guard (try? mockKeychain.save(data, for: "auth_token")) != nil else { return false }

                let service = DefaultAuthService(apiClient: mockAPI, keychainService: mockKeychain)

                // Call getValidToken — should auto-refresh
                let semaphore = DispatchSemaphore(value: 0)
                var result: AuthToken?
                Task {
                    result = try? await service.getValidToken()
                    semaphore.signal()
                }
                semaphore.wait()

                guard let refreshedToken = result else { return false }

                // The refreshed token must not be expired and must have a future expiresAt
                return !refreshedToken.isExpired && refreshedToken.expiresAt > Date()
            }
    }
}
