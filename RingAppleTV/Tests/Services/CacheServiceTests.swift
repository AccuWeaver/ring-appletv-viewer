import XCTest
@testable import RingAppleTV

// MARK: - Test Helpers

/// A simple Codable struct used as a cache payload in tests.
private struct TestPayload: Codable, Equatable {
    let id: Int
    let name: String
}

// MARK: - Unit Tests

final class CacheServiceTests: XCTestCase {

    private var tempDir: URL!
    private var sut: DefaultCacheService!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheServiceTests-\(UUID().uuidString)")
        sut = DefaultCacheService(directory: tempDir)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        sut = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - Save / Load Round-Trip

    func testSaveAndLoadRoundTrip() throws {
        let payload = TestPayload(id: 1, name: "doorbell")
        try sut.save(payload, for: "device", ttl: 60)

        let loaded = try sut.load(for: "device", as: TestPayload.self)
        XCTAssertEqual(loaded, payload)
    }

    func testSaveOverwritesExistingKey() throws {
        let first = TestPayload(id: 1, name: "first")
        let second = TestPayload(id: 2, name: "second")

        try sut.save(first, for: "key", ttl: 60)
        try sut.save(second, for: "key", ttl: 60)

        let loaded = try sut.load(for: "key", as: TestPayload.self)
        XCTAssertEqual(loaded, second)
    }

    func testSaveMultipleKeys() throws {
        let a = TestPayload(id: 1, name: "a")
        let b = TestPayload(id: 2, name: "b")

        try sut.save(a, for: "keyA", ttl: 60)
        try sut.save(b, for: "keyB", ttl: 60)

        XCTAssertEqual(try sut.load(for: "keyA", as: TestPayload.self), a)
        XCTAssertEqual(try sut.load(for: "keyB", as: TestPayload.self), b)
    }

    func testSaveAndLoadString() throws {
        let value = "hello-cache"
        try sut.save(value, for: "greeting", ttl: 60)

        let loaded = try sut.load(for: "greeting", as: String.self)
        XCTAssertEqual(loaded, value)
    }

    func testSaveAndLoadArray() throws {
        let values = [1, 2, 3, 4, 5]
        try sut.save(values, for: "numbers", ttl: 60)

        let loaded = try sut.load(for: "numbers", as: [Int].self)
        XCTAssertEqual(loaded, values)
    }

    // MARK: - Load Non-Existent Key

    func testLoadNonExistentKeyReturnsNil() throws {
        let result = try sut.load(for: "missing", as: TestPayload.self)
        XCTAssertNil(result)
    }

    // MARK: - Expiration

    func testExpiredEntryReturnsNil() throws {
        let payload = TestPayload(id: 1, name: "ephemeral")
        // TTL of 0 means it expires immediately.
        try sut.save(payload, for: "short", ttl: 0)

        // Tiny sleep to ensure the clock has advanced past the expiration.
        Thread.sleep(forTimeInterval: 0.05)

        let loaded = try sut.load(for: "short", as: TestPayload.self)
        XCTAssertNil(loaded)
    }

    func testIsExpiredReturnsTrueForExpiredEntry() throws {
        let payload = TestPayload(id: 1, name: "old")
        try sut.save(payload, for: "old", ttl: 0)
        Thread.sleep(forTimeInterval: 0.05)

        XCTAssertTrue(sut.isExpired(for: "old"))
    }

    func testIsExpiredReturnsFalseForValidEntry() throws {
        let payload = TestPayload(id: 1, name: "fresh")
        try sut.save(payload, for: "fresh", ttl: 3600)

        XCTAssertFalse(sut.isExpired(for: "fresh"))
    }

    func testIsExpiredReturnsTrueForNonExistentKey() {
        XCTAssertTrue(sut.isExpired(for: "nonexistent"))
    }

    // MARK: - Remove

    func testRemoveDeletesEntry() throws {
        let payload = TestPayload(id: 1, name: "remove-me")
        try sut.save(payload, for: "key", ttl: 60)
        try sut.remove(for: "key")

        let loaded = try sut.load(for: "key", as: TestPayload.self)
        XCTAssertNil(loaded)
    }

    func testRemoveNonExistentKeyDoesNotThrow() {
        XCTAssertNoThrow(try sut.remove(for: "nonexistent"))
    }

    // MARK: - Clear

    func testClearRemovesAllEntries() throws {
        try sut.save(TestPayload(id: 1, name: "a"), for: "a", ttl: 60)
        try sut.save(TestPayload(id: 2, name: "b"), for: "b", ttl: 60)
        try sut.save(TestPayload(id: 3, name: "c"), for: "c", ttl: 60)

        try sut.clear()

        XCTAssertNil(try sut.load(for: "a", as: TestPayload.self))
        XCTAssertNil(try sut.load(for: "b", as: TestPayload.self))
        XCTAssertNil(try sut.load(for: "c", as: TestPayload.self))
    }

    func testClearOnEmptyCacheDoesNotThrow() {
        XCTAssertNoThrow(try sut.clear())
    }

    // MARK: - Invalid Data

    func testLoadWithWrongTypeReturnsInvalidDataError() throws {
        // Save a String, try to load as TestPayload.
        try sut.save("not-a-payload", for: "bad", ttl: 60)

        XCTAssertThrowsError(try sut.load(for: "bad", as: TestPayload.self)) { error in
            guard let cacheError = error as? CacheError else {
                return XCTFail("Expected CacheError, got \(error)")
            }
            XCTAssertEqual(cacheError, .invalidData)
        }
    }

    // MARK: - Thread Safety

    func testConcurrentReadsAndWrites() throws {
        let iterations = 50
        let expectation = self.expectation(description: "concurrent ops")
        expectation.expectedFulfillmentCount = iterations * 2

        // Concurrent writes
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let payload = TestPayload(id: i, name: "item-\(i)")
            do {
                try self.sut.save(payload, for: "concurrent-\(i)", ttl: 60)
            } catch {
                XCTFail("Save failed for iteration \(i): \(error)")
            }
            expectation.fulfill()
        }

        // Concurrent reads
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            _ = try? self.sut.load(for: "concurrent-\(i)", as: TestPayload.self)
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)

        // Verify at least some entries persisted correctly.
        for i in 0..<iterations {
            let loaded = try sut.load(for: "concurrent-\(i)", as: TestPayload.self)
            XCTAssertNotNil(loaded)
            XCTAssertEqual(loaded?.id, i)
        }
    }

    func testConcurrentSaveAndClear() throws {
        let iterations = 20
        let expectation = self.expectation(description: "save-and-clear")
        expectation.expectedFulfillmentCount = iterations + 1

        // Concurrent saves
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let payload = TestPayload(id: i, name: "item-\(i)")
            try? self.sut.save(payload, for: "key-\(i)", ttl: 60)
            expectation.fulfill()
        }

        // Clear while saves may still be in flight
        DispatchQueue.global().async {
            try? self.sut.clear()
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 10)
        // No crash = pass. The cache should be in a consistent state.
    }

    // MARK: - Cache Directory Creation

    func testCacheDirectoryIsCreatedOnFirstSave() throws {
        // The temp directory should not exist yet.
        let freshDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CacheServiceTests-fresh-\(UUID().uuidString)")
        let freshCache = DefaultCacheService(directory: freshDir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: freshDir.path))

        try freshCache.save("hello", for: "key", ttl: 60)

        XCTAssertTrue(FileManager.default.fileExists(atPath: freshDir.path))

        // Cleanup
        try? FileManager.default.removeItem(at: freshDir)
    }

    // MARK: - Special Characters in Key

    func testKeyWithSpecialCharacters() throws {
        let payload = TestPayload(id: 99, name: "special")
        let key = "devices/all?filter=online&page=1"

        try sut.save(payload, for: key, ttl: 60)
        let loaded = try sut.load(for: key, as: TestPayload.self)
        XCTAssertEqual(loaded, payload)
    }
}
