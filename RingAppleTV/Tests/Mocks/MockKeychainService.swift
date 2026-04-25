import Foundation
@testable import RingAppleTV

/// In-memory mock `KeychainService` with error injection support.
final class MockKeychainService: KeychainService {

    /// In-memory storage.
    private var store: [String: Data] = [:]

    /// When set, the next `save` call throws this error.
    var saveError: Error?
    /// When set, the next `load` call throws this error.
    var loadError: Error?
    /// When set, the next `delete` call throws this error.
    var deleteError: Error?

    /// Tracks save calls: (data, key).
    var saveCalls: [(data: Data, key: String)] = []
    /// Tracks load calls.
    var loadCalls: [String] = []
    /// Tracks delete calls.
    var deleteCalls: [String] = []

    func save(_ data: Data, for key: String) throws {
        saveCalls.append((data: data, key: key))
        if let error = saveError {
            saveError = nil
            throw error
        }
        store[key] = data
    }

    func load(for key: String) throws -> Data? {
        loadCalls.append(key)
        if let error = loadError {
            loadError = nil
            throw error
        }
        return store[key]
    }

    func delete(for key: String) throws {
        deleteCalls.append(key)
        if let error = deleteError {
            deleteError = nil
            throw error
        }
        store.removeValue(forKey: key)
    }
}
