import XCTest
@testable import RingAppleTV

@MainActor
final class PlayerViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(videoService: MockVideoService = MockVideoService()) -> (PlayerViewModel, MockVideoService) {
        let vm = PlayerViewModel(videoService: videoService)
        return (vm, videoService)
    }

    private func makeSession(valid: Bool = true) -> StreamSession {
        StreamSession(
            deviceId: 42,
            hlsURL: URL(string: "https://ring.com/stream/42")!,
            createdAt: valid ? Date() : Date().addingTimeInterval(-7200),
            maxDuration: 600
        )
    }

    // MARK: - Request Stream Success

    func testRequestStream_success_transitionsToLoaded() async {
        let session = makeSession()
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .success(session)

        await sut.requestStream(for: 42)

        guard case .loaded(let loadedSession) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedSession, session)
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(mock.requestLiveStreamCalls, [42])
    }

    // MARK: - Request Stream Failure

    func testRequestStream_failure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .failure(RingAPIError.deviceOffline)

        await sut.requestStream(for: 42)

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.deviceOffline.userMessage)
        XCTAssertFalse(sut.isPlaying)
    }

    func testRequestStream_streamUnavailable_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .failure(RingAPIError.streamUnavailable)

        await sut.requestStream(for: 99)

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.streamUnavailable.userMessage)
    }

    // MARK: - Toggle Play/Pause

    func testTogglePlayPause_whenLoaded_togglesState() async {
        let session = makeSession()
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .success(session)

        await sut.requestStream(for: 42)
        XCTAssertTrue(sut.isPlaying)

        sut.togglePlayPause()
        XCTAssertFalse(sut.isPlaying)

        sut.togglePlayPause()
        XCTAssertTrue(sut.isPlaying)
    }

    func testTogglePlayPause_whenNotLoaded_doesNothing() {
        let (sut, _) = makeSUT()
        XCTAssertFalse(sut.isPlaying)

        sut.togglePlayPause()
        XCTAssertFalse(sut.isPlaying)
    }

    // MARK: - Retry

    func testRetry_retriesLastDeviceId() async {
        let session = makeSession()
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .failure(RingAPIError.streamUnavailable)

        await sut.requestStream(for: 42)
        guard case .error = sut.state else {
            XCTFail("Expected .error state")
            return
        }

        mock.requestLiveStreamResult = .success(session)
        await sut.retry()

        guard case .loaded(let loadedSession) = sut.state else {
            XCTFail("Expected .loaded state after retry, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedSession, session)
        XCTAssertEqual(mock.requestLiveStreamCalls, [42, 42])
    }

    func testRetry_withNoLastDevice_doesNothing() async {
        let (sut, mock) = makeSUT()

        await sut.retry()

        guard case .idle = sut.state else {
            XCTFail("Expected .idle state, got \(sut.state)")
            return
        }
        XCTAssertTrue(mock.requestLiveStreamCalls.isEmpty)
    }

    // MARK: - Session Validity

    func testIsSessionValid_whenValid_returnsTrue() async {
        let session = makeSession(valid: true)
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .success(session)
        mock.validateStreamSessionResult = true

        await sut.requestStream(for: 42)

        XCTAssertTrue(sut.isSessionValid)
        XCTAssertEqual(mock.validateStreamSessionCalls.count, 1)
    }

    func testIsSessionValid_whenExpired_returnsFalse() async {
        let session = makeSession(valid: false)
        let (sut, mock) = makeSUT()
        mock.requestLiveStreamResult = .success(session)
        mock.validateStreamSessionResult = false

        await sut.requestStream(for: 42)

        XCTAssertFalse(sut.isSessionValid)
    }

    func testIsSessionValid_whenNoSession_returnsFalse() {
        let (sut, _) = makeSUT()
        XCTAssertFalse(sut.isSessionValid)
    }

    // MARK: - Generic Error

    func testRequestStream_genericError_usesLocalizedDescription() async {
        let (sut, mock) = makeSUT()
        let genericError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Stream broke"])
        mock.requestLiveStreamResult = .failure(genericError)

        await sut.requestStream(for: 42)

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "Stream broke")
    }
}
