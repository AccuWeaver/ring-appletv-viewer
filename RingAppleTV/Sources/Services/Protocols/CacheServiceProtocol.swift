import Foundation

/// File-based cache with TTL expiration for non-sensitive data (devices, events).
protocol CacheService {
    /// Encode and persist `value` with a time-to-live of `ttl` seconds.
    func save<T: Codable>(_ value: T, for key: String, ttl: TimeInterval) throws
    /// Load and decode a previously cached value, returning `nil` if missing or expired.
    func load<T: Codable>(for key: String, as type: T.Type) throws -> T?
    /// Delete the cached entry for `key`.
    func remove(for key: String) throws
    /// Remove all cached entries.
    func clear() throws
    /// Whether the entry for `key` is missing or past its TTL.
    func isExpired(for key: String) -> Bool
}
