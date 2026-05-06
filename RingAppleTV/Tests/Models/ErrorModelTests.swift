import XCTest
@testable import RingAppleTV

// MARK: - PartnerAPIError Tests

final class PartnerAPIErrorTests: XCTestCase {

    /// All PartnerAPIError cases for exhaustive testing.
    private let allCases: [PartnerAPIError] = [
        .unauthorized,
        .forbidden,
        .notFound,
        .rateLimited(retryAfter: 5.0),
        .serverError(500),
        .networkError("timeout"),
        .decodingError("missing key"),
        .authorizationPending,
        .slowDown,
        .expiredDeviceCode
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
            PartnerAPIError.unauthorized.userMessage,
            "Your session has expired. Please re-link your Ring account."
        )
        XCTAssertEqual(
            PartnerAPIError.forbidden.userMessage,
            "Access denied. Please check your account permissions."
        )
        XCTAssertEqual(
            PartnerAPIError.notFound.userMessage,
            "The requested resource was not found."
        )
        XCTAssertEqual(
            PartnerAPIError.rateLimited(retryAfter: 10).userMessage,
            "Too many requests. Please wait a moment."
        )
        XCTAssertEqual(
            PartnerAPIError.authorizationPending.userMessage,
            "Waiting for authorization. Please complete sign-in on your phone."
        )
        XCTAssertEqual(
            PartnerAPIError.expiredDeviceCode.userMessage,
            "Authorization code expired. Please start the sign-in process again."
        )
    }

    func testAssociatedValueCasesUserMessages() {
        // networkError with different associated values should produce the same user message
        XCTAssertEqual(
            PartnerAPIError.networkError("timeout").userMessage,
            PartnerAPIError.networkError("dns failure").userMessage
        )
        // serverError with different status codes should produce the same user message
        XCTAssertEqual(
            PartnerAPIError.serverError(500).userMessage,
            PartnerAPIError.serverError(503).userMessage
        )
        // decodingError with different descriptions should produce the same user message
        XCTAssertEqual(
            PartnerAPIError.decodingError("key missing").userMessage,
            PartnerAPIError.decodingError("type mismatch").userMessage
        )
        // rateLimited with different retryAfter values should produce the same user message
        XCTAssertEqual(
            PartnerAPIError.rateLimited(retryAfter: 1).userMessage,
            PartnerAPIError.rateLimited(retryAfter: 30).userMessage
        )
    }

    // MARK: - Equatable

    func testEquatableSimpleCases() {
        XCTAssertEqual(PartnerAPIError.unauthorized, PartnerAPIError.unauthorized)
        XCTAssertEqual(PartnerAPIError.forbidden, PartnerAPIError.forbidden)
        XCTAssertEqual(PartnerAPIError.notFound, PartnerAPIError.notFound)
        XCTAssertEqual(PartnerAPIError.authorizationPending, PartnerAPIError.authorizationPending)
        XCTAssertEqual(PartnerAPIError.slowDown, PartnerAPIError.slowDown)
        XCTAssertEqual(PartnerAPIError.expiredDeviceCode, PartnerAPIError.expiredDeviceCode)
    }

    func testEquatableAssociatedValueCases() {
        XCTAssertEqual(PartnerAPIError.networkError("a"), PartnerAPIError.networkError("a"))
        XCTAssertNotEqual(PartnerAPIError.networkError("a"), PartnerAPIError.networkError("b"))

        XCTAssertEqual(PartnerAPIError.serverError(500), PartnerAPIError.serverError(500))
        XCTAssertNotEqual(PartnerAPIError.serverError(500), PartnerAPIError.serverError(503))

        XCTAssertEqual(PartnerAPIError.decodingError("x"), PartnerAPIError.decodingError("x"))
        XCTAssertNotEqual(PartnerAPIError.decodingError("x"), PartnerAPIError.decodingError("y"))

        XCTAssertEqual(PartnerAPIError.rateLimited(retryAfter: 5), PartnerAPIError.rateLimited(retryAfter: 5))
        XCTAssertNotEqual(PartnerAPIError.rateLimited(retryAfter: 5), PartnerAPIError.rateLimited(retryAfter: 10))
    }

    func testDifferentCasesAreNotEqual() {
        XCTAssertNotEqual(PartnerAPIError.unauthorized, PartnerAPIError.forbidden)
        XCTAssertNotEqual(PartnerAPIError.notFound, PartnerAPIError.unauthorized)
        XCTAssertNotEqual(PartnerAPIError.authorizationPending, PartnerAPIError.slowDown)
    }

    // MARK: - Error conformance

    func testConformsToError() {
        let error: Error = PartnerAPIError.unauthorized
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
