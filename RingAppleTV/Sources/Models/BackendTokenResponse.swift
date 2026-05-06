import Foundation

/// DTO for the token response from the partner auth backend.
/// Maps snake_case JSON keys to Swift properties.
struct BackendTokenResponse: Codable, Equatable {
    let accessToken: String
    let tokenType: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresAt = "expires_at"
    }

    /// Convert the backend response to the domain `AuthToken` model.
    /// Parses the ISO 8601 `expiresAt` string into a `Date`.
    func toDomain() -> AuthToken {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let expiryDate = formatter.date(from: expiresAt)
            ?? ISO8601DateFormatter().date(from: expiresAt)
            ?? Date()

        return AuthToken(
            accessToken: accessToken,
            refreshToken: "",
            expiresAt: expiryDate,
            scope: nil,
            tokenType: tokenType,
            clientId: nil
        )
    }
}
