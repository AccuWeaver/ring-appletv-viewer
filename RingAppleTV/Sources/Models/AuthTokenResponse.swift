import Foundation

/// DTO for the JSON response from Ring's OAuth token endpoint.
/// Maps snake_case JSON keys to Swift properties and converts to the domain `AuthToken`.
struct AuthTokenResponse: Codable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int
    let scope: String?
    let tokenType: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    /// Converts the API response into a domain `AuthToken`, computing `expiresAt` from `expiresIn`.
    func toDomain() -> AuthToken {
        AuthToken(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expiresAt: Date().addingTimeInterval(TimeInterval(expiresIn)),
            scope: scope,
            tokenType: tokenType
        )
    }
}
