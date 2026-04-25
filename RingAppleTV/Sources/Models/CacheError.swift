import Foundation

/// Errors related to the file-based cache service.
enum CacheError: Error, Equatable {
    case saveFailed(String)
    case loadFailed(String)
    case expired
    case notFound
    case invalidData

    /// A user-friendly message suitable for display in the UI.
    var userMessage: String {
        switch self {
        case .saveFailed:
            return "Unable to save data to cache."
        case .loadFailed:
            return "Unable to load cached data."
        case .expired:
            return "Cached data has expired."
        case .notFound:
            return "No cached data found."
        case .invalidData:
            return "Cached data is invalid or corrupted."
        }
    }
}
