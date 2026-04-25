import Foundation

/// Manages per-endpoint rate limiting to avoid hitting Ring API throttles.
///
/// Thread-safe via a dedicated serial queue. Default policy: max 10 requests
/// per 60-second sliding window per endpoint.
final class RateLimitManager {

    /// Configuration for the rate limiter.
    struct Config {
        let maxRequests: Int
        let windowInterval: TimeInterval

        static let `default` = Config(maxRequests: 10, windowInterval: 60)
    }

    private let config: Config
    private let queue = DispatchQueue(label: "com.ringappletv.ratelimit")
    private var requestLog: [String: [Date]] = [:]

    init(config: Config = .default) {
        self.config = config
    }

    /// Returns `true` if the endpoint has not exceeded its request quota
    /// within the current sliding window.
    func canMakeRequest(for endpoint: String) -> Bool {
        queue.sync {
            pruneExpired(for: endpoint)
            let count = requestLog[endpoint]?.count ?? 0
            return count < config.maxRequests
        }
    }

    /// Records a request timestamp for the given endpoint.
    func recordRequest(for endpoint: String) {
        queue.sync {
            pruneExpired(for: endpoint)
            requestLog[endpoint, default: []].append(Date())
        }
    }

    /// Returns the number of remaining requests allowed for the endpoint
    /// within the current window.
    func remainingRequests(for endpoint: String) -> Int {
        queue.sync {
            pruneExpired(for: endpoint)
            let count = requestLog[endpoint]?.count ?? 0
            return max(0, config.maxRequests - count)
        }
    }

    /// Clears all recorded requests (useful for testing or reset scenarios).
    func reset() {
        queue.sync {
            requestLog.removeAll()
        }
    }

    // MARK: - Private

    /// Removes timestamps older than the sliding window. Must be called
    /// while already on `queue`.
    private func pruneExpired(for endpoint: String) {
        let cutoff = Date().addingTimeInterval(-config.windowInterval)
        requestLog[endpoint] = requestLog[endpoint]?.filter { $0 > cutoff } ?? []
    }
}
