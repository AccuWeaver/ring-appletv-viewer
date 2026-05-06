import Foundation

/// Domain model representing an authenticated session with Ring's OAuth API.
struct AuthToken: Codable, Equatable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let scope: String?
    let tokenType: String
    let clientId: String?

    /// Whether the token has already expired.
    var isExpired: Bool {
        Date() >= expiresAt
    }

    /// Whether the token should be proactively refreshed (within 60 seconds of expiry).
    var needsRefresh: Bool {
        Date() >= expiresAt.addingTimeInterval(-60)
    }
}
