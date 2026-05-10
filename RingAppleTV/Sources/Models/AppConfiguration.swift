import Foundation

/// Application-wide configuration with sensible defaults.
/// All properties are mutable and `Codable`, allowing persistence via JSON
/// while gracefully falling back to defaults for missing keys.
struct AppConfiguration: Codable, Equatable {
    /// Use mock services instead of real Ring API calls.
    var useMocks: Bool
    /// Enable verbose debug logging.
    var enableDebugLogging: Bool
    /// Timeout in seconds before a live-stream request is considered failed.
    var streamTimeoutSeconds: TimeInterval
    /// Interval in seconds between automatic device-list refreshes.
    var deviceRefreshInterval: TimeInterval
    /// Number of hours of event history to fetch.
    var eventHistoryHours: Int
    /// Maximum number of events to display.
    var maxEventCount: Int
    /// Time-to-live in seconds for cached data.
    var cacheExpirationSeconds: TimeInterval
    /// Whether to log crashes locally.
    var enableCrashReporting: Bool
    /// Whether to collect anonymous local analytics.
    var enableLocalAnalytics: Bool
    /// Base URL of the partner auth backend service.
    var authBackendBaseURL: String
    /// API key for authenticating with the auth backend.
    var authBackendAPIKey: String
    /// User identifier for token retrieval from the auth backend.
    var authBackendUserId: String

    init(
        useMocks: Bool = true,
        enableDebugLogging: Bool = false,
        streamTimeoutSeconds: TimeInterval = 600,
        deviceRefreshInterval: TimeInterval = 60,
        eventHistoryHours: Int = 48,
        maxEventCount: Int = 50,
        cacheExpirationSeconds: TimeInterval = 300,
        enableCrashReporting: Bool = true,
        enableLocalAnalytics: Bool = false,
        authBackendBaseURL: String = "http://192.168.4.34:8000",
        authBackendAPIKey: String = "local-dev-api-key",
        authBackendUserId: String = "default"
    ) {
        self.useMocks = useMocks
        self.enableDebugLogging = enableDebugLogging
        self.streamTimeoutSeconds = streamTimeoutSeconds
        self.deviceRefreshInterval = deviceRefreshInterval
        self.eventHistoryHours = eventHistoryHours
        self.maxEventCount = maxEventCount
        self.cacheExpirationSeconds = cacheExpirationSeconds
        self.enableCrashReporting = enableCrashReporting
        self.enableLocalAnalytics = enableLocalAnalytics
        self.authBackendBaseURL = authBackendBaseURL
        self.authBackendAPIKey = authBackendAPIKey
        self.authBackendUserId = authBackendUserId
    }

    // MARK: - Codable (defaults for missing keys)

    init(from decoder: Decoder) throws {
        let defaults = AppConfiguration()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useMocks = try container.decodeIfPresent(Bool.self, forKey: .useMocks)
            ?? defaults.useMocks
        enableDebugLogging = try container.decodeIfPresent(Bool.self, forKey: .enableDebugLogging)
            ?? defaults.enableDebugLogging
        streamTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .streamTimeoutSeconds)
            ?? defaults.streamTimeoutSeconds
        deviceRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .deviceRefreshInterval)
            ?? defaults.deviceRefreshInterval
        eventHistoryHours = try container.decodeIfPresent(Int.self, forKey: .eventHistoryHours)
            ?? defaults.eventHistoryHours
        maxEventCount = try container.decodeIfPresent(Int.self, forKey: .maxEventCount)
            ?? defaults.maxEventCount
        cacheExpirationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .cacheExpirationSeconds)
            ?? defaults.cacheExpirationSeconds
        enableCrashReporting = try container.decodeIfPresent(Bool.self, forKey: .enableCrashReporting)
            ?? defaults.enableCrashReporting
        enableLocalAnalytics = try container.decodeIfPresent(Bool.self, forKey: .enableLocalAnalytics)
            ?? defaults.enableLocalAnalytics
        authBackendBaseURL = try container.decodeIfPresent(String.self, forKey: .authBackendBaseURL)
            ?? defaults.authBackendBaseURL
        authBackendAPIKey = try container.decodeIfPresent(String.self, forKey: .authBackendAPIKey)
            ?? defaults.authBackendAPIKey
        authBackendUserId = try container.decodeIfPresent(String.self, forKey: .authBackendUserId)
            ?? defaults.authBackendUserId
    }
}
