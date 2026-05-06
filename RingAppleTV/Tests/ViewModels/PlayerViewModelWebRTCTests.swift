import XCTest
import Combine
@testable import RingAppleTV

@MainActor
final class PlayerViewModelWebRTCTests: XCTestCase {

    private func makeSUT(
        streamSessionManager: MockStreamSessionManager = MockStreamSessionManager()
    ) -> (PlayerViewModel, MockStreamSessionManager) {
        let vm = PlayerViewModel(streamSessionManager: streamSessionManager)
        return (vm, streamSessionManager)
    }

    func testConnectionState_startsDisconnected_thenTransitionsToConnectingAndConnected() async {
        let (sut, mock) = makeSUT()
        XCTAssertEqual(sut.connectionState, .disconnected)

        mock.simulateStateChange(.connecting)
        await Task.yield()
        XCTAssertEqual(sut.connectionState, .connecting)

        mock.simulateStateChange(.connected)
        await Task.yield()
        XCTAssertEqual(sut.connectionState, .connected)
    }

    func testConnectionState_transitionsToDisconnected_afterBeingConnected() async {
        let (sut, mock) = makeSUT()
        mock.simulateStateChange(.connecting)
        await Task.yield()
        mock.simulateStateChange(.connected)
        await Task.yield()
        XCTAssertEqual(sut.connectionState, .connected)

        mock.simulateStateChange(.disconnected)
        await Task.yield()
        XCTAssertEqual(sut.connectionState, .disconnected)
    }

    func testFullHappyPath_disconnectedToConnectingToConnectedToDisconnected() async {
        let (sut, mock) = makeSUT()

        XCTAssertEqual(sut.connectionState, .disconnected)

        mock.autoTransitionStates = [.connecting, .connected]

        await sut.requestStream(for: "42", powerSource: .line)
        await Task.yield()

        XCTAssertEqual(mock.startStreamCalls.count, 1)
        XCTAssertEqual(sut.connectionState, .connected)

        sut.stopStream()
        // Give the Task a moment to execute
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(sut.connectionState, .disconnected)
        XCTAssertEqual(mock.stopStreamCalls, 1)
    }

    func testConnectionState_reflectsFailedState() async {
        let (sut, mock) = makeSUT()
        mock.simulateStateChange(.connecting)
        await Task.yield()
        mock.simulateStateChange(.failed("ICE connection failed"))
        await Task.yield()
        XCTAssertEqual(sut.connectionState, .failed("ICE connection failed"))
    }

    func testStopStream_callsStopOnManager() async {
        let (sut, mock) = makeSUT()
        sut.stopStream()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(mock.stopStreamCalls, 1)
    }

    func testStopStream_withoutManager_doesNotCrash() {
        let vm = PlayerViewModel(streamSessionManager: nil)
        vm.stopStream()
    }
}
