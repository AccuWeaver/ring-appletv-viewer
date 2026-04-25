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
    /// Maximum allowed duration for a single live-stream session.
    var maxStreamDuration: TimeInterval
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

    init(
        useMocks: Bool = false,
        enableDebugLogging: Bool = false,
        streamTimeoutSeconds: TimeInterval = 600,
        maxStreamDuration: TimeInterval = 600,
        deviceRefreshInterval: TimeInterval = 60,
        eventHistoryHours: Int = 48,
        maxEventCount: Int = 50,
        cacheExpirationSeconds: TimeInterval = 300,
        enableCrashReporting: Bool = true,
        enableLocalAnalytics: Bool = false
    ) {
        self.useMocks = useMocks
        self.enableDebugLogging = enableDebugLogging
        self.streamTimeoutSeconds = streamTimeoutSeconds
        self.maxStreamDuration = maxStreamDuration
        self.deviceRefreshInterval = deviceRefreshInterval
        self.eventHistoryHours = eventHistoryHours
        self.maxEventCount = maxEventCount
        self.cacheExpirationSeconds = cacheExpirationSeconds
        self.enableCrashReporting = enableCrashReporting
        self.enableLocalAnalytics = enableLocalAnalytics
    }

    // MARK: - Codable (defaults for missing keys)

    init(from decoder: Decoder) throws {
        let defaults = AppConfiguration()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useMocks = try container.decodeIfPresent(Bool.self, forKey: .useMocks) ?? defaults.useMocks
        enableDebugLogging = try container.decodeIfPresent(Bool.self, forKey: .enableDebugLogging) ?? defaults.enableDebugLogging
        streamTimeoutSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .streamTimeoutSeconds) ?? defaults.streamTimeoutSeconds
        maxStreamDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .maxStreamDuration) ?? defaults.maxStreamDuration
        deviceRefreshInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .deviceRefreshInterval) ?? defaults.deviceRefreshInterval
        eventHistoryHours = try container.decodeIfPresent(Int.self, forKey: .eventHistoryHours) ?? defaults.eventHistoryHours
        maxEventCount = try container.decodeIfPresent(Int.self, forKey: .maxEventCount) ?? defaults.maxEventCount
        cacheExpirationSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .cacheExpirationSeconds) ?? defaults.cacheExpirationSeconds
        enableCrashReporting = try container.decodeIfPresent(Bool.self, forKey: .enableCrashReporting) ?? defaults.enableCrashReporting
        enableLocalAnalytics = try container.decodeIfPresent(Bool.self, forKey: .enableLocalAnalytics) ?? defaults.enableLocalAnalytics
    }
}
