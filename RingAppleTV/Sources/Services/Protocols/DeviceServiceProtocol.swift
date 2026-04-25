import Foundation

/// Fetches, filters, and sorts Ring devices from the API with optional caching.
protocol DeviceService {
    func fetchDevices() async throws -> [RingDevice]
    func filterDevices(_ devices: [RingDevice], by filter: DeviceFilter) -> [RingDevice]
    func sortDevices(_ devices: [RingDevice], by sort: DeviceSort) -> [RingDevice]
    func refreshDevices() async throws -> [RingDevice]
}
