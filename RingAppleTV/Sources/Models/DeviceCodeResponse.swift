import Foundation

/// DTO for the OAuth 2.0 Device Authorization Grant response.
/// Maps snake_case JSON keys to Swift properties.
struct DeviceCodeResponse: Codable, Equatable {
    let deviceCode: String
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: Int
    let interval: Int

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationUri = "verification_uri"
        case verificationUriComplete = "verification_uri_complete"
        case expiresIn = "expires_in"
        case interval
    }
}

/// Domain model displayed to the user during the device code flow.
struct DeviceCodeInfo: Equatable {
    let userCode: String
    let verificationUri: String
    let verificationUriComplete: String?
    let expiresIn: TimeInterval
    let pollingInterval: TimeInterval
    let deviceCode: String
}
