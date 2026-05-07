import Foundation

/// Errors originating from Ring Partner API interactions.
enum PartnerAPIError: Error, Equatable {
    case unauthorized
    case forbidden
    case notFound
    case rateLimited(retryAfter: TimeInterval)
    case serverError(Int)
    case networkError(String)
    case decodingError(String)
    case authorizationPending
    case slowDown
    case expiredDeviceCode

    /// A user-friendly message suitable for display in the tvOS UI.
    /// Does not expose HTTP status codes, technical jargon, or stack traces.
    var userMessage: String {
        switch self {
        case .unauthorized:
            return "Your session has expired. Please re-link your Ring account."
        case .forbidden:
            return "Access denied. Please check your account permissions."
        case .notFound:
            return "The requested resource was not found."
        case .rateLimited:
            return "Too many requests. Please wait a moment."
        case .serverError:
            return "Ring servers are temporarily unavailable. Please try later."
        case .networkError:
            return "Network connection error. Please check your connection."
        case .decodingError:
            return "Unexpected response from Ring. Please try again."
        case .authorizationPending:
            return "Waiting for authorization. Please complete sign-in on your phone."
        case .slowDown:
            return "Please wait a moment before trying again."
        case .expiredDeviceCode:
            return "Authorization code expired. Please start the sign-in process again."
        }
    }
}

/// The error body returned by the Partner API in JSON error responses.
struct PartnerAPIErrorBody: Codable, Equatable {
    let code: String?
    let message: String?
}
