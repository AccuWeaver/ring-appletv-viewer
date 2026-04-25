import Foundation

/// Fetches, filters, and sorts Ring devices from the API with optional caching.
protocol DeviceService {
    /// Fetch devices, returning cached results when available.
    func fetchDevices() async throws -> [RingDevice]
    /// Return the subset of `devices` matching `filter`.
    func filterDevices(_ devices: [RingDevice], by filter: DeviceFilter) -> [RingDevice]
    /// Return `devices` ordered by `sort`.
    func sortDevices(_ devices: [RingDevice], by sort: DeviceSort) -> [RingDevice]
    /// Force-fetch devices from the API, bypassing cache.
    func refreshDevices() async throws -> [RingDevice]
}
