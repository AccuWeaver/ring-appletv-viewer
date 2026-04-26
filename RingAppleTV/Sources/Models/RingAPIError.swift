import Foundation

/// The type of two-factor authentication configured on the user's account.
enum TwoFactorMethod: Equatable {
    case sms
    case authenticator
    case email
    case unknown
}

/// Errors originating from Ring API interactions.
enum RingAPIError: Error, Equatable {
    case invalidCredentials
    case twoFactorRequired(method: TwoFactorMethod)
    case twoFactorInvalid
    case tokenExpired
    case tokenRefreshFailed
    case networkError(String)
    case serverError(Int)
    case decodingError(String)
    case deviceOffline
    case streamUnavailable
    case rateLimited
    case noSnapshotAvailable
    case unknown(String)

    /// A user-friendly message suitable for display in the UI.
    var userMessage: String {
        switch self {
        case .invalidCredentials:
            return "Invalid email or password. Please try again."
        case .twoFactorRequired(let method):
            switch method {
            case .authenticator:
                return "Enter the verification code from your authenticator app."
            case .sms:
                return "A verification code has been sent via SMS."
            case .email:
                return "A verification code has been sent to your email."
            case .unknown:
                return "Two-factor authentication code required."
            }
        case .twoFactorInvalid:
            return "Invalid verification code. Please try again."
        case .tokenExpired:
            return "Your session has expired. Please log in again."
        case .tokenRefreshFailed:
            return "Unable to refresh session. Please log in again."
        case .networkError:
            return "Network connection error. Please check your connection."
        case .serverError:
            return "Ring servers are temporarily unavailable. Please try later."
        case .decodingError:
            return "Unexpected response from Ring. Please try again."
        case .deviceOffline:
            return "This device is currently offline."
        case .streamUnavailable:
            return "Live stream is not available for this device."
        case .rateLimited:
            return "Too many requests. Please wait a moment."
        case .noSnapshotAvailable:
            return "No snapshot is available for this device."
        case .unknown:
            return "An unexpected error occurred. Please try again."
        }
    }
}
