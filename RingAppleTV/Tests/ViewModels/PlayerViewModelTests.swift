import XCTest
@testable import RingAppleTV

@MainActor
final class PlayerViewModelTests: XCTestCase {

    private func makeSUT(
        streamSessionManager: MockStreamSessionManager = MockStreamSessionManager()
    ) -> (PlayerViewModel, MockStreamSessionManager) {
        let vm = PlayerViewModel(streamSessionManager: streamSessionManager)
        return (vm, streamSessionManager)
    }

    func testRequestStream_success_transitionsToLoaded() async {
        let (sut, mock) = makeSUT()
        mock.autoTransitionStates = [.connecting, .connected]

        await sut.requestStream(for: "42", powerSource: .line)

        guard case .loaded(let loadedSession) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedSession.deviceId, "42")
        XCTAssertTrue(sut.isPlaying)
        XCTAssertEqual(mock.startStreamCalls.count, 1)
        XCTAssertEqual(mock.startStreamCalls.first?.deviceId, "42")
        XCTAssertEqual(mock.startStreamCalls.first?.powerSource, .line)
    }

    func testRequestStream_failure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.startStreamError = PartnerAPIError.notFound

        await sut.requestStream(for: "42", powerSource: .line)

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, PartnerAPIError.notFound.userMessage)
        XCTAssertFalse(sut.isPlaying)
    }

    func testTogglePlayPause_whenLoaded_togglesState() async {
        let (sut, mock) = makeSUT()
        mock.autoTransitionStates = [.connecting, .connected]

        await sut.requestStream(for: "42", powerSource: .line)
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

    func testRetry_retriesLastDeviceId() async {
        let (sut, mock) = makeSUT()
        mock.startStreamError = PartnerAPIError.notFound

        await sut.requestStream(for: "42", powerSource: .battery)
        guard case .error = sut.state else {
            XCTFail("Expected .error state")
            return
        }

        mock.startStreamError = nil
        mock.autoTransitionStates = [.connecting, .connected]
        await sut.retry()

        guard case .loaded(let loadedSession) = sut.state else {
            XCTFail("Expected .loaded state after retry, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedSession.deviceId, "42")
        XCTAssertEqual(mock.startStreamCalls.count, 2)
    }

    func testRetry_withNoLastDevice_doesNothing() async {
        let (sut, mock) = makeSUT()
        await sut.retry()
        guard case .idle = sut.state else {
            XCTFail("Expected .idle state, got \(sut.state)")
            return
        }
        XCTAssertTrue(mock.startStreamCalls.isEmpty)
    }

    func testStopStream_callsStopOnManager() async {
        let (sut, mock) = makeSUT()
        sut.stopStream()
        // Give the Task a moment to execute
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.stopStreamCalls, 1)
    }

    func testStopStream_withoutManager_doesNotCrash() {
        let vm = PlayerViewModel(streamSessionManager: nil)
        vm.stopStream()
    }

    func testRequestStream_withoutManager_showsError() async {
        let vm = PlayerViewModel(streamSessionManager: nil)
        await vm.requestStream(for: "42", powerSource: .line)

        guard case .error(let message) = vm.state else {
            XCTFail("Expected .error state, got \(vm.state)")
            return
        }
        XCTAssertEqual(message, "Live streaming is not available on this platform.")
    }
}
