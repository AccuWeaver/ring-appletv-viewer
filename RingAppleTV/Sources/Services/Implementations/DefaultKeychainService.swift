import Foundation
import Security

/// Abstraction over the Security framework's keychain operations.
/// Enables in-memory substitution for unit and property tests.
protocol KeychainBackend {
    func add(_ query: CFDictionary) -> OSStatus
    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus
    func delete(_ query: CFDictionary) -> OSStatus
}

/// Default backend that delegates to the real Security framework.
struct SystemKeychainBackend: KeychainBackend {
    func add(_ query: CFDictionary) -> OSStatus {
        SecItemAdd(query, nil)
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        SecItemCopyMatching(query, result)
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        SecItemDelete(query)
    }
}

/// Production implementation of `KeychainService` backed by the tvOS Keychain.
///
/// Uses `kSecClassGenericPassword` with a fixed service identifier
/// (`com.ringappletv`) so all items are scoped to this application.
final class DefaultKeychainService: KeychainService {

    private let serviceID: String
    private let backend: KeychainBackend

    /// Creates a keychain service.
    /// - Parameters:
    ///   - serviceID: The `kSecAttrService` value. Defaults to `"com.ringappletv"`.
    ///   - backend: The keychain backend to use. Defaults to the real Security framework.
    init(serviceID: String = "com.ringappletv", backend: KeychainBackend = SystemKeychainBackend()) {
        self.serviceID = serviceID
        self.backend = backend
    }

    // MARK: - KeychainService

    func save(_ data: Data, for key: String) throws {
        // Delete any existing item first to avoid errSecDuplicateItem.
        let deleteQuery = baseQuery(for: key)
        _ = backend.delete(deleteQuery as CFDictionary)

        var query = baseQuery(for: key)
        query[kSecValueData as String] = data

        let status = backend.add(query as CFDictionary)
        guard status == errSecSuccess else {
            throw KeychainError.saveFailed(status)
        }
    }

    func load(for key: String) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = backend.copyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw KeychainError.dataConversionFailed
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.loadFailed(status)
        }
    }

    func delete(for key: String) throws {
        let query = baseQuery(for: key)
        let status = backend.delete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.deleteFailed(status)
        }
    }

    // MARK: - Helpers

    private func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceID,
            kSecAttrAccount as String: key
        ]
    }
}
