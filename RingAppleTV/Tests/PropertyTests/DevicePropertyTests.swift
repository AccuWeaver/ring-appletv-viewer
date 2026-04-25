import XCTest
import SwiftCheck
@testable import RingAppleTV

// MARK: - Generators

private let deviceTypeGen: Gen<RingDevice.DeviceType> = Gen<RingDevice.DeviceType>.fromElements(of: RingDevice.DeviceType.allCases)

private let deviceGen: Gen<RingDevice> = Gen<RingDevice>.compose { c in
    RingDevice(
        id: c.generate(using: Int.arbitrary.suchThat { $0 > 0 }),
        description: c.generate(using: String.arbitrary.suchThat { !$0.isEmpty }),
        deviceType: c.generate(using: deviceTypeGen),
        firmwareVersion: c.generate(using: String?.arbitrary),
        address: c.generate(using: String?.arbitrary),
        batteryLife: c.generate(using: Int?.arbitrary),
        features: nil,
        isOnline: c.generate(using: Bool.arbitrary),
        snapshotURL: nil
    )
}

private let deviceListGen: Gen<[RingDevice]> = deviceGen.proliferate

private let deviceFilterGen: Gen<DeviceFilter> = Gen<Int>.fromElements(in: 0...3).flatMap { tag in
    switch tag {
    case 0:
        return Gen.pure(.all)
    case 1:
        return String.arbitrary.suchThat { !$0.isEmpty }.map { DeviceFilter.name($0) }
    case 2:
        return deviceTypeGen.map { DeviceFilter.type($0) }
    default:
        return Bool.arbitrary.map { $0 ? DeviceFilter.status(.online) : DeviceFilter.status(.offline) }
    }
}

private let deviceSortGen: Gen<DeviceSort> = Gen<DeviceSort>.fromElements(of: [
    .nameAscending, .nameDescending, .type, .status
])

// MARK: - Property Tests

/// Property-based tests for device filtering and sorting.
///
/// **Property 4**: Filtered result is a subset of the original list.
/// **Property 5**: Sorted result has the same elements and maintains order.
final class DevicePropertyTests: XCTestCase {

    /// Feature: AppleTVRing, Property 4: Filtered result is subset of original
    func testFilteredResultIsSubsetOfOriginal() {
        let service = DefaultDeviceService(
            authService: MockAuthService(),
            apiClient: MockRingAPIClient(),
            cacheService: MockCacheService()
        )

        property("Feature: AppleTVRing, Property 4: Filtered result is subset of original")
            <- forAll(deviceListGen, deviceFilterGen) { (devices: [RingDevice], filter: DeviceFilter) in
                let filtered = service.filterDevices(devices, by: filter)

                // Count must be <= original
                guard filtered.count <= devices.count else { return false }

                // Every filtered device must exist in the original
                for device in filtered {
                    guard devices.contains(where: { $0.id == device.id }) else { return false }
                }

                // Every filtered device must satisfy the predicate
                switch filter {
                case .all:
                    return filtered.count == devices.count
                case .name(let query):
                    let lowered = query.lowercased()
                    return filtered.allSatisfy { $0.description.lowercased().contains(lowered) }
                case .type(let deviceType):
                    return filtered.allSatisfy { $0.deviceType == deviceType }
                case .status(let status):
                    switch status {
                    case .online:
                        return filtered.allSatisfy { $0.isOnline }
                    case .offline:
                        return filtered.allSatisfy { !$0.isOnline }
                    }
                }
            }
    }

    /// Feature: AppleTVRing, Property 5: Sorted result preserves elements and maintains order
    func testSortedResultPreservesElementsAndOrder() {
        let service = DefaultDeviceService(
            authService: MockAuthService(),
            apiClient: MockRingAPIClient(),
            cacheService: MockCacheService()
        )

        property("Feature: AppleTVRing, Property 5: Sorted result preserves elements and maintains order")
            <- forAll(deviceListGen, deviceSortGen) { (devices: [RingDevice], sort: DeviceSort) in
                let sorted = service.sortDevices(devices, by: sort)

                // Same count
                guard sorted.count == devices.count else { return false }

                // Same elements (by id)
                let originalIds = Set(devices.map(\.id))
                let sortedIds = Set(sorted.map(\.id))
                guard originalIds == sortedIds else { return false }

                // Adjacent pairs satisfy comparator
                for i in 0..<max(0, sorted.count - 1) {
                    let a = sorted[i]
                    let b = sorted[i + 1]
                    switch sort {
                    case .nameAscending:
                        guard a.description.localizedCaseInsensitiveCompare(b.description) != .orderedDescending else { return false }
                    case .nameDescending:
                        guard a.description.localizedCaseInsensitiveCompare(b.description) != .orderedAscending else { return false }
                    case .type:
                        guard a.deviceType.rawValue <= b.deviceType.rawValue else { return false }
                    case .status:
                        // Online first: if a is offline, b must also be offline
                        if !a.isOnline && b.isOnline { return false }
                    }
                }

                return true
            }
    }
}
