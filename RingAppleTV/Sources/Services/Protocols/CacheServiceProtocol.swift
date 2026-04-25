import Foundation

/// File-based cache with TTL expiration for non-sensitive data (devices, events).
protocol CacheService {
    func save<T: Codable>(_ value: T, for key: String, ttl: TimeInterval) throws
    func load<T: Codable>(for key: String, as type: T.Type) throws -> T?
    func remove(for key: String) throws
    func clear() throws
    func isExpired(for key: String) -> Bool
}
