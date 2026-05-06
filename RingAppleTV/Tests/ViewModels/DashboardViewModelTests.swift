import XCTest
@testable import RingAppleTV

@MainActor
final class DashboardViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        deviceService: MockDeviceService = MockDeviceService(),
        mediaService: MockMediaService = MockMediaService(),
        refreshInterval: TimeInterval = 60
    ) -> (DashboardViewModel, MockDeviceService) {
        let vm = DashboardViewModel(deviceService: deviceService, mediaService: mediaService, refreshInterval: refreshInterval)
        return (vm, deviceService)
    }

    private func makeSampleDevices() -> [RingDevice] {
        [
            RingDevice(
                id: "1", name: "Front Door", model: "doorbell",
                deviceType: .doorbell, firmwareVersion: "1.0",
                powerSource: .line, isOnline: true
            ),
            RingDevice(
                id: "2", name: "Backyard", model: "stickup_cam",
                deviceType: .stickupCam, firmwareVersion: "2.0",
                powerSource: .battery, isOnline: false
            )
        ]
    }

    // MARK: - Load Devices Success

    func testLoadDevices_success_transitionsToLoaded() async {
        let devices = makeSampleDevices()
        let (sut, mock) = makeSUT()
        mock.fetchDevicesResult = .success(devices)

        await sut.loadDevices()

        guard case .loaded(let loadedDevices) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedDevices.count, 2)
        XCTAssertEqual(mock.fetchDevicesCalls, 1)
        sut.stopBackgroundRefresh()
    }

    // MARK: - Load Devices Failure

    func testLoadDevices_failure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.fetchDevicesResult = .failure(PartnerAPIError.networkError("offline"))

        await sut.loadDevices()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, PartnerAPIError.networkError("offline").userMessage)
    }

    // MARK: - Load Devices Empty

    func testLoadDevices_empty_transitionsToEmpty() async {
        let (sut, mock) = makeSUT()
        mock.fetchDevicesResult = .success([])

        await sut.loadDevices()

        guard case .empty(let message) = sut.state else {
            XCTFail("Expected .empty state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "No devices found.")
        sut.stopBackgroundRefresh()
    }

    // MARK: - Refresh

    func testRefresh_success_updatesState() async {
        let devices = makeSampleDevices()
        let (sut, mock) = makeSUT()
        mock.refreshDevicesResult = .success(devices)

        await sut.refresh()

        guard case .loaded(let loadedDevices) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(loadedDevices.count, 2)
        XCTAssertEqual(mock.refreshDevicesCalls, 1)
    }

    func testRefresh_failure_transitionsToError() async {
        let (sut, mock) = makeSUT()
        mock.refreshDevicesResult = .failure(PartnerAPIError.serverError(500))

        await sut.refresh()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, PartnerAPIError.serverError(500).userMessage)
    }

    // MARK: - Filter

    func testApplyFilter_updatesFilterAndReapplies() async {
        let devices = makeSampleDevices()
        let mock = MockDeviceService()
        mock.fetchDevicesResult = .success(devices)
        mock.filterDevicesHandler = { devices, filter in
            if case .status(.online) = filter {
                return devices.filter { $0.isOnline }
            }
            return devices
        }

        let (sut, _) = makeSUT(deviceService: mock)
        await sut.loadDevices()

        sut.applyFilter(.status(.online))

        guard case .loaded(let filtered) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.name, "Front Door")
        sut.stopBackgroundRefresh()
    }

    func testApplyFilter_emptyResult_transitionsToEmpty() async {
        let devices = makeSampleDevices()
        let mock = MockDeviceService()
        mock.fetchDevicesResult = .success(devices)
        mock.filterDevicesHandler = { _, _ in [] }

        let (sut, _) = makeSUT(deviceService: mock)
        await sut.loadDevices()

        sut.applyFilter(.name("nonexistent"))

        guard case .empty = sut.state else {
            XCTFail("Expected .empty state, got \(sut.state)")
            return
        }
        sut.stopBackgroundRefresh()
    }

    // MARK: - Sort

    func testApplySort_updatesSortAndReapplies() async {
        let devices = makeSampleDevices()
        let mock = MockDeviceService()
        mock.fetchDevicesResult = .success(devices)
        mock.sortDevicesHandler = { devices, sort in
            if case .nameDescending = sort {
                return devices.sorted { $0.name > $1.name }
            }
            return devices
        }

        let (sut, _) = makeSUT(deviceService: mock)
        await sut.loadDevices()

        sut.applySort(.nameDescending)

        guard case .loaded(let sorted) = sut.state else {
            XCTFail("Expected .loaded state, got \(sut.state)")
            return
        }
        XCTAssertEqual(sorted.first?.name, "Front Door")
        sut.stopBackgroundRefresh()
    }

    // MARK: - Stop Background Refresh

    func testStopBackgroundRefresh_cancelsTask() async {
        let (sut, mock) = makeSUT()
        mock.fetchDevicesResult = .success(makeSampleDevices())

        await sut.loadDevices()
        sut.stopBackgroundRefresh()

        XCTAssertEqual(mock.fetchDevicesCalls, 1)
    }

    // MARK: - Snapshots populated after device load

    func testLoadDevices_populatesSnapshotsAfterDeviceLoad() async {
        let devices = makeSampleDevices()
        let mockDevice = MockDeviceService()
        mockDevice.fetchDevicesResult = .success(devices)

        let mockMedia = MockMediaService()
        mockMedia.downloadSnapshotResult = .success(MockData.sampleJPEGData)

        let (sut, _) = makeSUT(deviceService: mockDevice, mediaService: mockMedia)
        await sut.loadDevices()

        XCTAssertEqual(sut.snapshots.count, 2)
        XCTAssertEqual(sut.snapshots["1"], MockData.sampleJPEGData)
        XCTAssertEqual(sut.snapshots["2"], MockData.sampleJPEGData)
        XCTAssertEqual(mockMedia.downloadSnapshotCalls.count, 2)
        sut.stopBackgroundRefresh()
    }

    // MARK: - Individual snapshot failure doesn't block other devices

    func testLoadDevices_snapshotFailure_doesNotBlockOtherDevices() async {
        let devices = makeSampleDevices()
        let mockDevice = MockDeviceService()
        mockDevice.fetchDevicesResult = .success(devices)

        let mockMedia = MockMediaService()
        mockMedia.perDeviceSnapshotResults["1"] = .failure(PartnerAPIError.notFound)
        mockMedia.perDeviceSnapshotResults["2"] = .success(MockData.sampleJPEGData)

        let sut = DashboardViewModel(deviceService: mockDevice, mediaService: mockMedia, refreshInterval: 60)
        await sut.loadDevices()

        XCTAssertNil(sut.snapshots["1"])
        XCTAssertEqual(sut.snapshots["2"], MockData.sampleJPEGData)
        sut.stopBackgroundRefresh()
    }

    // MARK: - Generic Error

    func testLoadDevices_genericError_usesLocalizedDescription() async {
        let (sut, mock) = makeSUT()
        let genericError = NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Generic failure"])
        mock.fetchDevicesResult = .failure(genericError)

        await sut.loadDevices()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, "Generic failure")
    }
}
