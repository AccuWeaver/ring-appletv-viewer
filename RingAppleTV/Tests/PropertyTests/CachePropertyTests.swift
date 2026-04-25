import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Arbitrary Conformances

/// A simple Codable payload used for cache property tests.
private struct CacheTestValue: Codable, Equatable {
    let id: Int
    let label: String
}

extension CacheTestValue: Arbitrary {
    static var arbitrary: Gen<CacheTestValue> {
        Gen<CacheTestValue>.compose { c in
            CacheTestValue(
                id: c.generate(using: Int.arbitrary),
                label: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty })
            )
        }
    }
}

// MARK: - Property Tests

/// Property-based tests for cache persistence.
///
/// Validates that the file-based cache correctly round-trips Codable values
/// and respects TTL expiration semantics.
final class CachePropertyTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CachePropertyTests-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        tempDir = nil
        super.tearDown()
    }

    /// Feature: AppleTVRing, Property: Cache persistence round-trip
    ///
    /// For any Codable value, saving it to the cache and immediately loading
    /// it back should produce a value equal to the original.
    func testCachePersistenceRoundTrip() {
        let cache = DefaultCacheService(directory: tempDir)

        property("Feature: AppleTVRing, Property: Cache persistence round-trip")
            <- forAll { (value: CacheTestValue) in
                let key = "prop-\(abs(value.id))"
                guard (try? cache.save(value, for: key, ttl: 3600)) != nil else {
                    return false
                }
                guard let loaded = try? cache.load(for: key, as: CacheTestValue.self) else {
                    return false
                }
                return loaded == value
            }
    }

    /// Feature: AppleTVRing, Property: Expired entries are not returned
    ///
    /// For any Codable value saved with a TTL of 0, loading it after a brief
    /// delay should return nil (the entry is expired).
    func testExpiredEntriesAreNotReturned() {
        let cache = DefaultCacheService(directory: tempDir)

        property("Feature: AppleTVRing, Property: Expired entries return nil")
            <- forAll { (value: CacheTestValue) in
                let key = "expired-\(abs(value.id))"
                guard (try? cache.save(value, for: key, ttl: 0)) != nil else {
                    return false
                }
                // Small sleep to ensure clock advances past expiration.
                Thread.sleep(forTimeInterval: 0.01)
                let loaded = try? cache.load(for: key, as: CacheTestValue.self)
                // loaded should be nil (expired) or the call itself returns nil.
                return loaded == nil
            }
    }

    /// Feature: AppleTVRing, Property: isExpired consistent with load
    ///
    /// For any value saved with TTL 0, `isExpired` should return true after
    /// the entry has expired, consistent with `load` returning nil.
    func testIsExpiredConsistentWithLoad() {
        let cache = DefaultCacheService(directory: tempDir)

        property("Feature: AppleTVRing, Property: isExpired consistent with load")
            <- forAll { (value: CacheTestValue) in
                let key = "consistency-\(abs(value.id))"
                guard (try? cache.save(value, for: key, ttl: 0)) != nil else {
                    return false
                }
                Thread.sleep(forTimeInterval: 0.01)
                let expired = cache.isExpired(for: key)
                let loaded = try? cache.load(for: key, as: CacheTestValue.self)
                // Both should agree: expired == true and loaded == nil.
                return expired && loaded == nil
            }
    }
}
