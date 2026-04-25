import Foundation

/// A wrapper that pairs a cached value's JSON data with its expiration date.
struct CacheEntry: Codable {
    let data: Data
    let expiresAt: Date
}

/// Production implementation of `CacheService` backed by JSON files in the
/// app's Documents/Cache directory.
///
/// Each key maps to a single JSON file containing a `CacheEntry` (the encoded
/// value plus an expiration timestamp). All file I/O is serialised on a
/// dedicated `DispatchQueue` to guarantee thread safety.
final class DefaultCacheService: CacheService {

    private let cacheDirectory: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(label: "com.ringappletv.cache")

    /// Creates a cache service.
    /// - Parameters:
    ///   - directory: Root directory for cache files. Defaults to
    ///     `Documents/Cache` inside the app sandbox.
    ///   - fileManager: The file manager to use. Defaults to `.default`.
    init(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        if let directory = directory {
            self.cacheDirectory = directory
        } else {
            let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
            self.cacheDirectory = docs.appendingPathComponent("Cache")
        }
    }

    // MARK: - CacheService

    func save<T: Codable>(_ value: T, for key: String, ttl: TimeInterval) throws {
        try queue.sync {
            try ensureCacheDirectory()

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            let valueData: Data
            do {
                valueData = try encoder.encode(value)
            } catch {
                throw CacheError.saveFailed(error.localizedDescription)
            }

            let entry = CacheEntry(
                data: valueData,
                expiresAt: Date().addingTimeInterval(ttl)
            )

            let entryData: Data
            do {
                entryData = try encoder.encode(entry)
            } catch {
                throw CacheError.saveFailed(error.localizedDescription)
            }

            let fileURL = self.fileURL(for: key)
            do {
                try entryData.write(to: fileURL, options: .atomic)
            } catch {
                throw CacheError.saveFailed(error.localizedDescription)
            }
        }
    }

    func load<T: Codable>(for key: String, as type: T.Type) throws -> T? {
        try queue.sync {
            let fileURL = self.fileURL(for: key)

            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }

            let entryData: Data
            do {
                entryData = try Data(contentsOf: fileURL)
            } catch {
                throw CacheError.loadFailed(error.localizedDescription)
            }

            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let entry: CacheEntry
            do {
                entry = try decoder.decode(CacheEntry.self, from: entryData)
            } catch {
                throw CacheError.invalidData
            }

            if Date() >= entry.expiresAt {
                return nil
            }

            do {
                return try decoder.decode(T.self, from: entry.data)
            } catch {
                throw CacheError.invalidData
            }
        }
    }

    func remove(for key: String) throws {
        try queue.sync {
            let fileURL = self.fileURL(for: key)
            guard fileManager.fileExists(atPath: fileURL.path) else { return }
            do {
                try fileManager.removeItem(at: fileURL)
            } catch {
                throw CacheError.loadFailed(error.localizedDescription)
            }
        }
    }

    func clear() throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: cacheDirectory.path) else { return }
            do {
                let contents = try fileManager.contentsOfDirectory(
                    at: cacheDirectory,
                    includingPropertiesForKeys: nil
                )
                for file in contents {
                    try fileManager.removeItem(at: file)
                }
            } catch {
                throw CacheError.saveFailed(error.localizedDescription)
            }
        }
    }

    func isExpired(for key: String) -> Bool {
        queue.sync {
            let fileURL = self.fileURL(for: key)
            guard fileManager.fileExists(atPath: fileURL.path),
                  let entryData = try? Data(contentsOf: fileURL) else {
                return true
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            guard let entry = try? decoder.decode(CacheEntry.self, from: entryData) else {
                return true
            }
            return Date() >= entry.expiresAt
        }
    }

    // MARK: - Helpers

    private func fileURL(for key: String) -> URL {
        let safeName = key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
        return cacheDirectory.appendingPathComponent(safeName).appendingPathExtension("json")
    }

    private func ensureCacheDirectory() throws {
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            do {
                try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            } catch {
                throw CacheError.saveFailed(error.localizedDescription)
            }
        }
    }
}
