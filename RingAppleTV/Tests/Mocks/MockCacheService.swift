import Foundation
@testable import RingAppleTV

/// In-memory mock `CacheService` with TTL simulation and error injection.
final class MockCacheService: CacheService {

    // MARK: - Storage

    private var store: [String: (data: Data, expiresAt: Date)] = [:]
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Error Injection

    var saveError: Error?
    var loadError: Error?
    var removeError: Error?
    var clearError: Error?

    // MARK: - Call Tracking

    var saveCalls: [(key: String, ttl: TimeInterval)] = []
    var loadCalls: [String] = []
    var removeCalls: [String] = []
    var clearCalls: Int = 0

    // MARK: - CacheService

    func save<T: Codable>(_ value: T, for key: String, ttl: TimeInterval) throws {
        saveCalls.append((key: key, ttl: ttl))
        if let error = saveError { throw error }
        let data = try encoder.encode(value)
        store[key] = (data: data, expiresAt: Date().addingTimeInterval(ttl))
    }

    func load<T: Codable>(for key: String, as type: T.Type) throws -> T? {
        loadCalls.append(key)
        if let error = loadError { throw error }
        guard let entry = store[key] else { return nil }
        if Date() >= entry.expiresAt { return nil }
        return try decoder.decode(T.self, from: entry.data)
    }

    func remove(for key: String) throws {
        removeCalls.append(key)
        if let error = removeError { throw error }
        store.removeValue(forKey: key)
    }

    func clear() throws {
        clearCalls += 1
        if let error = clearError { throw error }
        store.removeAll()
    }

    func isExpired(for key: String) -> Bool {
        guard let entry = store[key] else { return true }
        return Date() >= entry.expiresAt
    }
}
