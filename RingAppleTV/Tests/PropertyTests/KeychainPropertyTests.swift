import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Arbitrary Conformances

extension AuthToken: Arbitrary {
    public static var arbitrary: Gen<AuthToken> {
        Gen<AuthToken>.compose { composer in
            AuthToken(
                accessToken: composer.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
                refreshToken: composer.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
                expiresAt: Date(timeIntervalSince1970: Double(composer.generate(using:
                    Int.arbitrary.suchThat { $0 > 0 && $0 < 4_000_000_000 }
                ))),
                scope: composer.generate(using: String?.arbitrary),
                tokenType: "Bearer"
            )
        }
    }
}

// MARK: - Property Tests

/// Property-based tests for token persistence round-trip through the keychain.
///
/// **Property 1**: For any valid `AuthToken`, encoding to `Data`, saving to the
/// keychain, loading back, and decoding should produce an `AuthToken` equal to
/// the original.
///
/// Validates: FR-1.1.3 (secure token storage), FR-1.1.4 (token retrieval).
final class KeychainPropertyTests: XCTestCase {

    /// Feature: AppleTVRing, Property 1: Token persistence round-trip
    func testTokenPersistenceRoundTrip() {
        let backend = InMemoryKeychainBackend()
        let keychain = DefaultKeychainService(serviceID: "com.ringappletv.pbt", backend: backend)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        property("Feature: AppleTVRing, Property 1: Token persistence round-trip")
            <- forAll { (token: AuthToken) in
                // Encode
                guard let data = try? encoder.encode(token) else {
                    return false
                }
                // Save
                guard (try? keychain.save(data, for: "auth_token")) != nil else {
                    return false
                }
                // Load
                guard let loaded = try? keychain.load(for: "auth_token"),
                      let loadedData = loaded else {
                    return false
                }
                // Decode
                guard let decoded = try? decoder.decode(AuthToken.self, from: loadedData) else {
                    return false
                }
                return decoded == token
            }
    }

    /// Verifies that saving a token and then deleting it results in nil on load.
    func testTokenDeleteAfterSave() {
        let backend = InMemoryKeychainBackend()
        let keychain = DefaultKeychainService(serviceID: "com.ringappletv.pbt2", backend: backend)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970

        property("Feature: AppleTVRing, Property 1b: Delete clears persisted token")
            <- forAll { (token: AuthToken) in
                guard let data = try? encoder.encode(token),
                      (try? keychain.save(data, for: "auth_token")) != nil,
                      (try? keychain.delete(for: "auth_token")) != nil else {
                    return false
                }
                let loaded = try? keychain.load(for: "auth_token")
                return loaded == nil || loaded! == nil
            }
    }

    /// Verifies that overwriting a token with a new one always returns the latest.
    func testTokenOverwriteReturnsLatest() {
        let backend = InMemoryKeychainBackend()
        let keychain = DefaultKeychainService(serviceID: "com.ringappletv.pbt3", backend: backend)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        property("Feature: AppleTVRing, Property 1c: Overwrite returns latest token")
            <- forAll { (first: AuthToken, second: AuthToken) in
                guard let d1 = try? encoder.encode(first),
                      let d2 = try? encoder.encode(second),
                      (try? keychain.save(d1, for: "auth_token")) != nil,
                      (try? keychain.save(d2, for: "auth_token")) != nil,
                      let loaded = try? keychain.load(for: "auth_token"),
                      let loadedData = loaded,
                      let decoded = try? decoder.decode(AuthToken.self, from: loadedData) else {
                    return false
                }
                return decoded == second
            }
    }
}
