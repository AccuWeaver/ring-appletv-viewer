import XCTest
@testable import RingAppleTV

// MARK: - In-Memory Keychain Backend

/// A fully in-memory `KeychainBackend` that mimics the Security framework's
/// behaviour without touching the real Keychain. Suitable for SPM test targets
/// where `SecItemAdd` / `SecItemCopyMatching` may not be available.
final class InMemoryKeychainBackend: KeychainBackend {

    /// Storage keyed by "service:account".
    private var store: [String: Data] = [:]

    /// Optional status to force on the next `add` call (for error injection).
    var nextAddStatus: OSStatus?
    /// Optional status to force on the next `copyMatching` call.
    var nextCopyStatus: OSStatus?
    /// Optional status to force on the next `delete` call.
    var nextDeleteStatus: OSStatus?
    /// When true, `copyMatching` returns a non-Data CFTypeRef to trigger dataConversionFailed.
    var returnBadType = false

    // MARK: - KeychainBackend

    func add(_ query: CFDictionary) -> OSStatus {
        if let forced = nextAddStatus {
            nextAddStatus = nil
            return forced
        }
        let dict = query as! [String: Any]
        let key = storageKey(from: dict)
        guard store[key] == nil else { return errSecDuplicateItem }
        guard let data = dict[kSecValueData as String] as? Data else { return errSecParam }
        store[key] = data
        return errSecSuccess
    }

    func copyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>) -> OSStatus {
        if let forced = nextCopyStatus {
            nextCopyStatus = nil
            return forced
        }
        let dict = query as! [String: Any]
        let key = storageKey(from: dict)
        guard let data = store[key] else { return errSecItemNotFound }
        if returnBadType {
            returnBadType = false
            result.pointee = NSString(string: "not-data")
            return errSecSuccess
        }
        result.pointee = data as CFTypeRef
        return errSecSuccess
    }

    func delete(_ query: CFDictionary) -> OSStatus {
        if let forced = nextDeleteStatus {
            nextDeleteStatus = nil
            return forced
        }
        let dict = query as! [String: Any]
        let key = storageKey(from: dict)
        if store.removeValue(forKey: key) != nil {
            return errSecSuccess
        }
        return errSecItemNotFound
    }

    // MARK: - Helpers

    private func storageKey(from dict: [String: Any]) -> String {
        let service = dict[kSecAttrService as String] as? String ?? ""
        let account = dict[kSecAttrAccount as String] as? String ?? ""
        return "\(service):\(account)"
    }
}

// MARK: - Unit Tests

final class KeychainServiceTests: XCTestCase {

    private var backend: InMemoryKeychainBackend!
    private var sut: DefaultKeychainService!

    override func setUp() {
        super.setUp()
        backend = InMemoryKeychainBackend()
        sut = DefaultKeychainService(serviceID: "com.ringappletv.test", backend: backend)
    }

    override func tearDown() {
        sut = nil
        backend = nil
        super.tearDown()
    }

    // MARK: - Save / Load Round-Trip

    func testSaveAndLoadRoundTrip() throws {
        let data = "hello-keychain".data(using: .utf8)!
        try sut.save(data, for: "token")

        let loaded = try sut.load(for: "token")
        XCTAssertEqual(loaded, data)
    }

    func testSaveOverwritesExistingKey() throws {
        let first = "first".data(using: .utf8)!
        let second = "second".data(using: .utf8)!

        try sut.save(first, for: "key")
        try sut.save(second, for: "key")

        let loaded = try sut.load(for: "key")
        XCTAssertEqual(loaded, second)
    }

    func testSaveMultipleKeys() throws {
        let a = "aaa".data(using: .utf8)!
        let b = "bbb".data(using: .utf8)!

        try sut.save(a, for: "keyA")
        try sut.save(b, for: "keyB")

        XCTAssertEqual(try sut.load(for: "keyA"), a)
        XCTAssertEqual(try sut.load(for: "keyB"), b)
    }

    // MARK: - Load Non-Existent Key

    func testLoadNonExistentKeyReturnsNil() throws {
        let result = try sut.load(for: "missing")
        XCTAssertNil(result)
    }

    // MARK: - Delete

    func testDeleteRemovesItem() throws {
        let data = "delete-me".data(using: .utf8)!
        try sut.save(data, for: "key")
        try sut.delete(for: "key")

        let loaded = try sut.load(for: "key")
        XCTAssertNil(loaded)
    }

    func testDeleteNonExistentKeyDoesNotThrow() throws {
        XCTAssertNoThrow(try sut.delete(for: "nonexistent"))
    }

    // MARK: - AuthToken Persistence

    func testAuthTokenRoundTrip() throws {
        let token = AuthToken(
            accessToken: "access_abc",
            refreshToken: "refresh_xyz",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000),
            scope: "client",
            tokenType: "Bearer"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(token)
        try sut.save(data, for: "auth_token")

        let loaded = try sut.load(for: "auth_token")
        XCTAssertNotNil(loaded)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(AuthToken.self, from: loaded!)
        XCTAssertEqual(decoded, token)
    }

    // MARK: - Error Cases

    func testSaveFailedThrowsKeychainError() {
        backend.nextAddStatus = errSecIO
        // Pre-delete so the save path actually calls add (no existing item).
        XCTAssertThrowsError(try sut.save(Data([1]), for: "key")) { error in
            guard let keychainError = error as? KeychainError else {
                return XCTFail("Expected KeychainError, got \(error)")
            }
            XCTAssertEqual(keychainError, .saveFailed(errSecIO))
        }
    }

    func testLoadFailedThrowsKeychainError() {
        backend.nextCopyStatus = errSecIO
        XCTAssertThrowsError(try sut.load(for: "key")) { error in
            guard let keychainError = error as? KeychainError else {
                return XCTFail("Expected KeychainError, got \(error)")
            }
            XCTAssertEqual(keychainError, .loadFailed(errSecIO))
        }
    }

    func testLoadBadTypeThrowsDataConversionFailed() throws {
        // First save a real item so the key exists.
        try sut.save(Data([1, 2, 3]), for: "key")
        // Now force the backend to return a non-Data type.
        backend.returnBadType = true

        XCTAssertThrowsError(try sut.load(for: "key")) { error in
            guard let keychainError = error as? KeychainError else {
                return XCTFail("Expected KeychainError, got \(error)")
            }
            XCTAssertEqual(keychainError, .dataConversionFailed)
        }
    }

    func testDeleteFailedThrowsKeychainError() {
        backend.nextDeleteStatus = errSecIO
        XCTAssertThrowsError(try sut.delete(for: "key")) { error in
            guard let keychainError = error as? KeychainError else {
                return XCTFail("Expected KeychainError, got \(error)")
            }
            XCTAssertEqual(keychainError, .deleteFailed(errSecIO))
        }
    }

    // MARK: - Service ID Isolation

    func testDifferentServiceIDsAreIsolated() throws {
        let other = DefaultKeychainService(serviceID: "com.other", backend: backend)
        let data = "isolated".data(using: .utf8)!

        try sut.save(data, for: "shared_key")
        let otherResult = try other.load(for: "shared_key")
        XCTAssertNil(otherResult)
    }

    // MARK: - Empty Data

    func testSaveAndLoadEmptyData() throws {
        let empty = Data()
        try sut.save(empty, for: "empty")
        let loaded = try sut.load(for: "empty")
        XCTAssertEqual(loaded, empty)
    }
}
