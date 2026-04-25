import XCTest
@testable import RingAppleTV

// MARK: - RingAPIError Tests

final class RingAPIErrorTests: XCTestCase {

    /// All RingAPIError cases for exhaustive testing.
    private let allCases: [RingAPIError] = [
        .invalidCredentials,
        .twoFactorRequired,
        .twoFactorInvalid,
        .tokenExpired,
        .tokenRefreshFailed,
        .networkError("timeout"),
        .serverError(500),
        .decodingError("missing key"),
        .deviceOffline,
        .streamUnavailable,
        .rateLimited,
        .unknown("something went wrong")
    ]

    // MARK: - userMessage

    func testAllCasesHaveNonEmptyUserMessage() {
        for error in allCases {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error) has empty userMessage")
        }
    }

    func testUserMessagesDoNotContainTechnicalIdentifiers() {
        let technicalPatterns = [
            "HTTP", "OSStatus", "NSError", "Error:", "Exception",
            "nil", "null", "500", "401", "403", "404", "429"
        ]
        for error in allCases {
            let message = error.userMessage
            for pattern in technicalPatterns {
                XCTAssertFalse(
                    message.contains(pattern),
                    "\(error).userMessage contains technical identifier '\(pattern)': \(message)"
                )
            }
        }
    }

    func testSpecificUserMessages() {
        XCTAssertEqual(
            RingAPIError.invalidCredentials.userMessage,
            "Invalid email or password. Please try again."
        )
        XCTAssertEqual(
            RingAPIError.twoFactorRequired.userMessage,
            "Two-factor authentication code required."
        )
        XCTAssertEqual(
            RingAPIError.deviceOffline.userMessage,
            "This device is currently offline."
        )
        XCTAssertEqual(
            RingAPIError.rateLimited.userMessage,
            "Too many requests. Please wait a moment."
        )
    }

    func testAssociatedValueCasesUserMessages() {
        // networkError with different associated values should produce the same user message
        XCTAssertEqual(
            RingAPIError.networkError("timeout").userMessage,
            RingAPIError.networkError("dns failure").userMessage
        )
        // serverError with different status codes should produce the same user message
        XCTAssertEqual(
            RingAPIError.serverError(500).userMessage,
            RingAPIError.serverError(503).userMessage
        )
        // decodingError with different descriptions should produce the same user message
        XCTAssertEqual(
            RingAPIError.decodingError("key missing").userMessage,
            RingAPIError.decodingError("type mismatch").userMessage
        )
        // unknown with different descriptions should produce the same user message
        XCTAssertEqual(
            RingAPIError.unknown("a").userMessage,
            RingAPIError.unknown("b").userMessage
        )
    }

    // MARK: - Equatable

    func testEquatableSimpleCases() {
        XCTAssertEqual(RingAPIError.invalidCredentials, RingAPIError.invalidCredentials)
        XCTAssertEqual(RingAPIError.twoFactorRequired, RingAPIError.twoFactorRequired)
        XCTAssertEqual(RingAPIError.deviceOffline, RingAPIError.deviceOffline)
        XCTAssertEqual(RingAPIError.streamUnavailable, RingAPIError.streamUnavailable)
        XCTAssertEqual(RingAPIError.rateLimited, RingAPIError.rateLimited)
        XCTAssertEqual(RingAPIError.tokenExpired, RingAPIError.tokenExpired)
        XCTAssertEqual(RingAPIError.tokenRefreshFailed, RingAPIError.tokenRefreshFailed)
        XCTAssertEqual(RingAPIError.twoFactorInvalid, RingAPIError.twoFactorInvalid)
    }

    func testEquatableAssociatedValueCases() {
        XCTAssertEqual(RingAPIError.networkError("a"), RingAPIError.networkError("a"))
        XCTAssertNotEqual(RingAPIError.networkError("a"), RingAPIError.networkError("b"))

        XCTAssertEqual(RingAPIError.serverError(500), RingAPIError.serverError(500))
        XCTAssertNotEqual(RingAPIError.serverError(500), RingAPIError.serverError(503))

        XCTAssertEqual(RingAPIError.decodingError("x"), RingAPIError.decodingError("x"))
        XCTAssertNotEqual(RingAPIError.decodingError("x"), RingAPIError.decodingError("y"))

        XCTAssertEqual(RingAPIError.unknown("z"), RingAPIError.unknown("z"))
        XCTAssertNotEqual(RingAPIError.unknown("z"), RingAPIError.unknown("w"))
    }

    func testDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(RingAPIError.invalidCredentials, RingAPIError.tokenExpired)
        XCTAssertNotEqual(RingAPIError.deviceOffline, RingAPIError.streamUnavailable)
        XCTAssertNotEqual(RingAPIError.rateLimited, RingAPIError.unknown("rate"))
    }

    // MARK: - Error conformance

    func testConformsToError() {
        let error: Error = RingAPIError.invalidCredentials
        XCTAssertNotNil(error)
    }
}


// MARK: - KeychainError Tests

final class KeychainErrorTests: XCTestCase {

    /// All KeychainError cases for exhaustive testing.
    private let allCases: [KeychainError] = [
        .saveFailed(errSecDuplicateItem),
        .loadFailed(errSecItemNotFound),
        .deleteFailed(errSecParam),
        .dataConversionFailed,
        .itemNotFound
    ]

    // MARK: - userMessage

    func testAllCasesHaveNonEmptyUserMessage() {
        for error in allCases {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error) has empty userMessage")
        }
    }

    func testUserMessagesDoNotContainTechnicalIdentifiers() {
        let technicalPatterns = [
            "OSStatus", "errSec", "NSError", "Error:", "Exception",
            "nil", "null", "kSec", "SecItem"
        ]
        for error in allCases {
            let message = error.userMessage
            for pattern in technicalPatterns {
                XCTAssertFalse(
                    message.contains(pattern),
                    "\(error).userMessage contains technical identifier '\(pattern)': \(message)"
                )
            }
        }
    }

    func testSpecificUserMessages() {
        XCTAssertEqual(
            KeychainError.saveFailed(0).userMessage,
            "Unable to save credentials securely."
        )
        XCTAssertEqual(
            KeychainError.loadFailed(0).userMessage,
            "Unable to retrieve stored credentials."
        )
        XCTAssertEqual(
            KeychainError.deleteFailed(0).userMessage,
            "Unable to remove stored credentials."
        )
        XCTAssertEqual(
            KeychainError.dataConversionFailed.userMessage,
            "Credential data is corrupted."
        )
        XCTAssertEqual(
            KeychainError.itemNotFound.userMessage,
            "No stored credentials found."
        )
    }

    func testAssociatedValueCasesUserMessages() {
        // Different OSStatus values should produce the same user message
        XCTAssertEqual(
            KeychainError.saveFailed(-25299).userMessage,
            KeychainError.saveFailed(-25300).userMessage
        )
        XCTAssertEqual(
            KeychainError.loadFailed(-25300).userMessage,
            KeychainError.loadFailed(-25308).userMessage
        )
        XCTAssertEqual(
            KeychainError.deleteFailed(-25300).userMessage,
            KeychainError.deleteFailed(-25299).userMessage
        )
    }

    // MARK: - Equatable

    func testEquatableSimpleCases() {
        XCTAssertEqual(KeychainError.dataConversionFailed, KeychainError.dataConversionFailed)
        XCTAssertEqual(KeychainError.itemNotFound, KeychainError.itemNotFound)
    }

    func testEquatableAssociatedValueCases() {
        XCTAssertEqual(KeychainError.saveFailed(-25299), KeychainError.saveFailed(-25299))
        XCTAssertNotEqual(KeychainError.saveFailed(-25299), KeychainError.saveFailed(-25300))

        XCTAssertEqual(KeychainError.loadFailed(-25300), KeychainError.loadFailed(-25300))
        XCTAssertNotEqual(KeychainError.loadFailed(-25300), KeychainError.loadFailed(-25308))

        XCTAssertEqual(KeychainError.deleteFailed(0), KeychainError.deleteFailed(0))
        XCTAssertNotEqual(KeychainError.deleteFailed(0), KeychainError.deleteFailed(-1))
    }

    func testDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(KeychainError.saveFailed(0), KeychainError.loadFailed(0))
        XCTAssertNotEqual(KeychainError.dataConversionFailed, KeychainError.itemNotFound)
    }

    // MARK: - Error conformance

    func testConformsToError() {
        let error: Error = KeychainError.itemNotFound
        XCTAssertNotNil(error)
    }
}

// MARK: - CacheError Tests

final class CacheErrorTests: XCTestCase {

    /// All CacheError cases for exhaustive testing.
    private let allCases: [CacheError] = [
        .saveFailed("disk full"),
        .loadFailed("file missing"),
        .expired,
        .notFound,
        .invalidData
    ]

    // MARK: - userMessage

    func testAllCasesHaveNonEmptyUserMessage() {
        for error in allCases {
            XCTAssertFalse(error.userMessage.isEmpty, "\(error) has empty userMessage")
        }
    }

    func testUserMessagesDoNotContainTechnicalIdentifiers() {
        let technicalPatterns = [
            "NSError", "Error:", "Exception", "nil", "null",
            "FileManager", "NSCoding", "JSON"
        ]
        for error in allCases {
            let message = error.userMessage
            for pattern in technicalPatterns {
                XCTAssertFalse(
                    message.contains(pattern),
                    "\(error).userMessage contains technical identifier '\(pattern)': \(message)"
                )
            }
        }
    }

    func testSpecificUserMessages() {
        XCTAssertEqual(
            CacheError.saveFailed("reason").userMessage,
            "Unable to save data to cache."
        )
        XCTAssertEqual(
            CacheError.loadFailed("reason").userMessage,
            "Unable to load cached data."
        )
        XCTAssertEqual(
            CacheError.expired.userMessage,
            "Cached data has expired."
        )
        XCTAssertEqual(
            CacheError.notFound.userMessage,
            "No cached data found."
        )
        XCTAssertEqual(
            CacheError.invalidData.userMessage,
            "Cached data is invalid or corrupted."
        )
    }

    func testAssociatedValueCasesUserMessages() {
        // Different associated values should produce the same user message
        XCTAssertEqual(
            CacheError.saveFailed("disk full").userMessage,
            CacheError.saveFailed("permission denied").userMessage
        )
        XCTAssertEqual(
            CacheError.loadFailed("file missing").userMessage,
            CacheError.loadFailed("read error").userMessage
        )
    }

    // MARK: - Equatable

    func testEquatableSimpleCases() {
        XCTAssertEqual(CacheError.expired, CacheError.expired)
        XCTAssertEqual(CacheError.notFound, CacheError.notFound)
        XCTAssertEqual(CacheError.invalidData, CacheError.invalidData)
    }

    func testEquatableAssociatedValueCases() {
        XCTAssertEqual(CacheError.saveFailed("a"), CacheError.saveFailed("a"))
        XCTAssertNotEqual(CacheError.saveFailed("a"), CacheError.saveFailed("b"))

        XCTAssertEqual(CacheError.loadFailed("x"), CacheError.loadFailed("x"))
        XCTAssertNotEqual(CacheError.loadFailed("x"), CacheError.loadFailed("y"))
    }

    func testDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(CacheError.expired, CacheError.notFound)
        XCTAssertNotEqual(CacheError.notFound, CacheError.invalidData)
        XCTAssertNotEqual(CacheError.saveFailed("a"), CacheError.loadFailed("a"))
    }

    // MARK: - Error conformance

    func testConformsToError() {
        let error: Error = CacheError.expired
        XCTAssertNotNil(error)
    }
}
