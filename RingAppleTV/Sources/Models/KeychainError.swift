import Foundation

/// Errors related to Keychain operations for secure credential storage.
enum KeychainError: Error, Equatable {
    case saveFailed(OSStatus)
    case loadFailed(OSStatus)
    case deleteFailed(OSStatus)
    case dataConversionFailed
    case itemNotFound

    /// A user-friendly message suitable for display in the UI.
    var userMessage: String {
        switch self {
        case .saveFailed:
            return "Unable to save credentials securely."
        case .loadFailed:
            return "Unable to retrieve stored credentials."
        case .deleteFailed:
            return "Unable to remove stored credentials."
        case .dataConversionFailed:
            return "Credential data is corrupted."
        case .itemNotFound:
            return "No stored credentials found."
        }
    }
}
