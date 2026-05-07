import Foundation

/// Determines whether a failed request should be retried and computes
/// exponential-backoff delays.
///
/// - Max retries: 3
/// - Delay formula: `2^attempt` seconds (1 s, 2 s, 4 s, …)
/// - Max delay cap: 60 seconds
struct RetryStrategy {

    /// Maximum number of retry attempts before giving up.
    static let maxRetries: Int = 3

    /// Upper bound on the backoff delay (seconds).
    static let maxDelay: TimeInterval = 60

    /// Returns `true` when the error is transient and the attempt count
    /// has not been exhausted.
    ///
    /// Retryable errors: `.networkError`, `.serverError`, `.rateLimited`.
    /// Non-retryable: `.invalidCredentials`, `.twoFactorRequired`,
    /// `.twoFactorInvalid`, `.decodingError`, and others.
    static func shouldRetry(error: RingAPIError, attempt: Int) -> Bool {
        guard attempt < maxRetries else { return false }

        switch error {
        case .networkError, .serverError, .rateLimited:
            return true
        case .invalidCredentials,
             .twoFactorRequired,
             .twoFactorInvalid,
             .tokenExpired,
             .tokenRefreshFailed,
             .decodingError,
             .deviceOffline,
             .streamUnavailable,
             .noSnapshotAvailable,
             .invalidURL,
             .unknown:
            return false
        }
    }

    /// Computes the backoff delay for the given attempt number.
    ///
    /// Formula: `min(2^attempt, maxDelay)`.
    /// - Parameter attempt: Zero-based attempt index (0 → 1 s, 1 → 2 s, …).
    static func delay(for attempt: Int) -> TimeInterval {
        let raw = pow(2.0, Double(attempt))
        return min(raw, maxDelay)
    }
}
