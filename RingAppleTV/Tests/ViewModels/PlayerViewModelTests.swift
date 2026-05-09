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

    func testRequestStream_withoutManager_transitionsToLoadedWithPlaceholder() async {
        // When no WebRTC manager is available and no event/media service is
        // wired in either, requestStream should transition to .loaded with
        // the placeholder session URL so the view can render the HLS fallback.
        let vm = PlayerViewModel(streamSessionManager: nil)
        await vm.requestStream(for: "42", powerSource: .line)

        guard case .loaded(let session) = vm.state else {
            XCTFail("Expected .loaded state, got \(vm.state)")
            return
        }
        XCTAssertEqual(session.deviceId, "42")
        XCTAssertEqual(session.sessionURL, PlayerViewModel.placeholderMockSessionURL)
        XCTAssertTrue(vm.isPlaying)
    }

    func testRequestStream_withoutManager_withEventServiceAndClip_usesClipURL() async {
        // When no WebRTC manager is available but an EventService returns a
        // recent event and the video URL lookup succeeds, the fallback
        // session should carry the resolved clip URL.
        let eventService = MockEventService()
        let expectedEvent = RingEvent(
            id: "evt-1",
            deviceId: "42",
            eventType: .motion,
            createdAt: Date(),
            duration: 30
        )
        let expectedURL = URL(string: "https://cdn.ring.invalid/clip.m3u8")!
        eventService.fetchEventsResult = .success([expectedEvent])
        eventService.fetchEventVideoURLResult = .success(expectedURL)

        let vm = PlayerViewModel(
            streamSessionManager: nil,
            eventService: eventService,
            mediaService: MockMediaService()
        )
        await vm.requestStream(for: "42", powerSource: .line)

        guard case .loaded(let session) = vm.state else {
            XCTFail("Expected .loaded state, got \(vm.state)")
            return
        }
        XCTAssertEqual(session.sessionURL, expectedURL)
        XCTAssertEqual(eventService.fetchEventsCalls, ["42"])
        XCTAssertEqual(eventService.fetchEventVideoURLCalls.first?.id, "evt-1")
    }

    func testRequestStream_withoutManager_noEvents_fallsBackToPlaceholder() async {
        // When EventService returns no events, session URL must fall back to
        // the placeholder so the view picks the hard-coded test stream.
        let eventService = MockEventService()
        eventService.fetchEventsResult = .success([])

        let vm = PlayerViewModel(
            streamSessionManager: nil,
            eventService: eventService,
            mediaService: MockMediaService()
        )
        await vm.requestStream(for: "42", powerSource: .line)

        guard case .loaded(let session) = vm.state else {
            XCTFail("Expected .loaded state, got \(vm.state)")
            return
        }
        XCTAssertEqual(session.sessionURL, PlayerViewModel.placeholderMockSessionURL)
    }

    func testRequestStream_withoutManager_clipLookupFails_fallsBackToPlaceholder() async {
        // When fetchEventVideoURL throws (e.g., no Ring Protect), the fallback
        // session URL is the placeholder — never a crash.
        let eventService = MockEventService()
        eventService.fetchEventsResult = .success([
            RingEvent(
                id: "evt-1", deviceId: "42", eventType: .motion,
                createdAt: Date(), duration: 30
            )
        ])
        eventService.fetchEventVideoURLResult = .failure(PartnerAPIError.forbidden)

        let vm = PlayerViewModel(
            streamSessionManager: nil,
            eventService: eventService,
            mediaService: MockMediaService()
        )
        await vm.requestStream(for: "42", powerSource: .line)

        guard case .loaded(let session) = vm.state else {
            XCTFail("Expected .loaded state, got \(vm.state)")
            return
        }
        XCTAssertEqual(session.sessionURL, PlayerViewModel.placeholderMockSessionURL)
    }
}
