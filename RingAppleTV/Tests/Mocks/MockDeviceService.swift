import Foundation
@testable import RingAppleTV

/// Mock `DeviceService` with configurable return values and call tracking.
final class MockDeviceService: DeviceService {

    // MARK: - fetchDevices

    var fetchDevicesResult: Result<[RingDevice], Error> = .success([])
    var fetchDevicesCalls: Int = 0

    func fetchDevices() async throws -> [RingDevice] {
        fetchDevicesCalls += 1
        return try fetchDevicesResult.get()
    }

    // MARK: - filterDevices

    var filterDevicesCalls: [(devices: [RingDevice], filter: DeviceFilter)] = []
    var filterDevicesHandler: (([RingDevice], DeviceFilter) -> [RingDevice])?

    func filterDevices(_ devices: [RingDevice], by filter: DeviceFilter) -> [RingDevice] {
        filterDevicesCalls.append((devices: devices, filter: filter))
        if let handler = filterDevicesHandler {
            return handler(devices, filter)
        }
        // Default: return all for .all, otherwise return as-is
        return devices
    }

    // MARK: - sortDevices

    var sortDevicesCalls: [(devices: [RingDevice], sort: DeviceSort)] = []
    var sortDevicesHandler: (([RingDevice], DeviceSort) -> [RingDevice])?

    func sortDevices(_ devices: [RingDevice], by sort: DeviceSort) -> [RingDevice] {
        sortDevicesCalls.append((devices: devices, sort: sort))
        if let handler = sortDevicesHandler {
            return handler(devices, sort)
        }
        return devices
    }

    // MARK: - refreshDevices

    var refreshDevicesResult: Result<[RingDevice], Error> = .success([])
    var refreshDevicesCalls: Int = 0

    func refreshDevices() async throws -> [RingDevice] {
        refreshDevicesCalls += 1
        return try refreshDevicesResult.get()
    }
}
