import XCTest
@testable import RingAppleTV

extension XCTestCase {

    // MARK: - Async Helpers

    /// Runs an async throwing closure with a configurable timeout.
    /// Fails the test if the closure doesn't complete within the timeout.
    func runAsync(
        timeout: TimeInterval = 5,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: @escaping () async throws -> Void
    ) {
        let expectation = expectation(description: "async operation")
        Task {
            do {
                try await block()
            } catch {
                XCTFail("Async block threw: \(error)", file: file, line: line)
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: timeout)
    }

    /// Asserts that an async throwing expression throws an error of the expected type.
    func assertAsyncThrows<E: Error & Equatable>(
        _ expectedError: E,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () async throws -> some Any
    ) async {
        do {
            _ = try await block()
            XCTFail("Expected error \(expectedError) but no error was thrown", file: file, line: line)
        } catch let error as E {
            XCTAssertEqual(error, expectedError, file: file, line: line)
        } catch {
            XCTFail("Expected \(E.self) but got \(type(of: error)): \(error)", file: file, line: line)
        }
    }

    // MARK: - ViewState Assertions

    /// Asserts that a `ViewState` is `.loaded` and returns the loaded value.
    @discardableResult
    func assertLoaded<T>(
        _ state: ViewState<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> T? {
        if case .loaded(let value) = state {
            return value
        }
        XCTFail("Expected .loaded but got \(state)", file: file, line: line)
        return nil
    }

    /// Asserts that a `ViewState` is `.error` and optionally checks the message.
    func assertError<T>(
        _ state: ViewState<T>,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .error(let msg) = state {
            if let expected = message {
                XCTAssertEqual(msg, expected, file: file, line: line)
            }
        } else {
            XCTFail("Expected .error but got \(state)", file: file, line: line)
        }
    }

    /// Asserts that a `ViewState` is `.loading`.
    func assertLoading<T>(
        _ state: ViewState<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .loading = state { return }
        XCTFail("Expected .loading but got \(state)", file: file, line: line)
    }

    /// Asserts that a `ViewState` is `.empty` and optionally checks the message.
    func assertEmpty<T>(
        _ state: ViewState<T>,
        message: String? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .empty(let msg) = state {
            if let expected = message {
                XCTAssertEqual(msg, expected, file: file, line: line)
            }
        } else {
            XCTFail("Expected .empty but got \(state)", file: file, line: line)
        }
    }

    /// Asserts that a `ViewState` is `.idle`.
    func assertIdle<T>(
        _ state: ViewState<T>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        if case .idle = state { return }
        XCTFail("Expected .idle but got \(state)", file: file, line: line)
    }
}
