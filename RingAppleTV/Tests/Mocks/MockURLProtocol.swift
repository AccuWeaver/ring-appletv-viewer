import Foundation
@testable import RingAppleTV

/// A custom URLProtocol subclass that intercepts network requests for testing.
/// Configure `requestHandler` to return mock responses for specific requests.
final class MockURLProtocol: URLProtocol {

    /// Handler that receives the request and returns (response, data) or throws an error.
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    /// Tracks all requests made during a test for assertion purposes.
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }

    override func startLoading() {
        MockURLProtocol.capturedRequests.append(request)

        guard let handler = MockURLProtocol.requestHandler else {
            let error = NSError(domain: "MockURLProtocol", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "No request handler configured"
            ])
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        // No-op
    }

    /// Reset captured state between tests.
    static func reset() {
        requestHandler = nil
        capturedRequests = []
    }
}
