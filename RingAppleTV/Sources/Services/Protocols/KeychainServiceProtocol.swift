import Foundation

/// Secure storage for sensitive data (tokens, credentials) using the tvOS Keychain.
protocol KeychainService {
    /// Store `data` under `key`, replacing any existing item.
    func save(_ data: Data, for key: String) throws
    /// Retrieve data for `key`, or `nil` if not found.
    func load(for key: String) throws -> Data?
    /// Remove the item for `key`. No-op if the item doesn't exist.
    func delete(for key: String) throws
}
