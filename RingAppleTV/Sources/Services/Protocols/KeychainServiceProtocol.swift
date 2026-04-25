import Foundation

/// Secure storage for sensitive data (tokens, credentials) using the tvOS Keychain.
protocol KeychainService {
    func save(_ data: Data, for key: String) throws
    func load(for key: String) throws -> Data?
    func delete(for key: String) throws
}
