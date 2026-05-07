import XCTest
@testable import RingAppleTV

@MainActor
final class DashboardViewModelTests: XCTestCase {

    // MARK: - Helpers

    private func makeSUT(
        deviceService: MockDeviceService = MockDeviceService(),
        snapshotService: MockSnapshotService = MockSnapshotService(),
        refreshInterval: TimeInterval = 60
    ) -> (DashboardViewModel, MockDeviceService) {
        let vm = DashboardViewModel(deviceService: deviceService, snapshotService: snapshotService, refreshInterval: refreshInterval)
        return (vm, deviceService)
    }

    private func makeSampleDevices() -> [RingDevice] {
        [
            RingDevice(
                id: 1,
                description: "Front Door",
                deviceType: .doorbell,
                firmwareVersion: "1.0",
                address: nil,
                batteryLife: 80,
                features: nil,
                isOnline: true
            ),
            RingDevice(
                id: 2,
                description: "Backyard",
                deviceType: .stickupCam,
                firmwareVersion: "2.0",
                address: nil,
                batteryLife: 60,
                features: nil,
                isOnline: false
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
        mock.fetchDevicesResult = .failure(RingAPIError.networkError("offline"))

        await sut.loadDevices()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.networkError("offline").userMessage)
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
        mock.refreshDevicesResult = .failure(RingAPIError.serverError(500))

        await sut.refresh()

        guard case .error(let message) = sut.state else {
            XCTFail("Expected .error state, got \(sut.state)")
            return
        }
        XCTAssertEqual(message, RingAPIError.serverError(500).userMessage)
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
        XCTAssertEqual(filtered.first?.description, "Front Door")
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
                return devices.sorted { $0.description > $1.description }
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
        XCTAssertEqual(sorted.first?.description, "Front Door")
        sut.stopBackgroundRefresh()
    }

    // MARK: - Stop Background Refresh

    func testStopBackgroundRefresh_cancelsTask() async {
        let (sut, mock) = makeSUT()
        mock.fetchDevicesResult = .success(makeSampleDevices())

        await sut.loadDevices()
        sut.stopBackgroundRefresh()

        // No crash or hang means the task was properly cancelled
        XCTAssertEqual(mock.fetchDevicesCalls, 1)
    }

    // MARK: - 8.9 Snapshots populated after device load

    func testLoadDevices_populatesSnapshotsAfterDeviceLoad() async {
        let devices = makeSampleDevices()
        let mockDevice = MockDeviceService()
        mockDevice.fetchDevicesResult = .success(devices)

        let mockSnapshot = MockSnapshotService()
        mockSnapshot.getSnapshotResult = .success(MockData.sampleJPEGData)

        let (sut, _) = makeSUT(deviceService: mockDevice, snapshotService: mockSnapshot)
        await sut.loadDevices()

        // Snapshots should be populated for both devices
        XCTAssertEqual(sut.snapshots.count, 2)
        XCTAssertEqual(sut.snapshots[1], MockData.sampleJPEGData)
        XCTAssertEqual(sut.snapshots[2], MockData.sampleJPEGData)
        // getSnapshot should have been called for each device
        XCTAssertEqual(mockSnapshot.getSnapshotCalls.count, 2)
        sut.stopBackgroundRefresh()
    }

    // MARK: - 8.10 Individual snapshot failure doesn't block other devices

    func testLoadDevices_snapshotFailure_doesNotBlockOtherDevices() async {
        let devices = makeSampleDevices()
        let mockDevice = MockDeviceService()
        mockDevice.fetchDevicesResult = .success(devices)

        // Use a snapshot service that fails for device 1 but succeeds for device 2
        let mockSnapshot = PerDeviceSnapshotService()
        mockSnapshot.results[1] = .failure(RingAPIError.noSnapshotAvailable)
        mockSnapshot.results[2] = .success(MockData.sampleJPEGData)

        let sut = DashboardViewModel(deviceService: mockDevice, snapshotService: mockSnapshot, refreshInterval: 60)
        await sut.loadDevices()

        // Device 1 failed — should not be in snapshots
        XCTAssertNil(sut.snapshots[1])
        // Device 2 succeeded — should be present
        XCTAssertEqual(sut.snapshots[2], MockData.sampleJPEGData)
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

// MARK: - Per-Device Snapshot Service Helper

/// A mock snapshot service that returns different results per device ID.
private final class PerDeviceSnapshotService: SnapshotService, @unchecked Sendable {
    var results: [Int: Result<Data, Error>] = [:]

    func getSnapshot(for deviceId: Int) async throws -> Data {
        guard let result = results[deviceId] else {
            throw RingAPIError.noSnapshotAvailable
        }
        return try result.get()
    }

    func requestNewSnapshot(for deviceId: Int) async throws {}
    func clearCache() {}
}
