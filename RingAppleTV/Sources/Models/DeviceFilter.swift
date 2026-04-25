import Foundation

/// Filter criteria for narrowing down the device list.
enum DeviceFilter {
    case all
    case name(String)
    case type(RingDevice.DeviceType)
    case status(DeviceStatus)
}

/// Sort criteria for ordering the device list.
enum DeviceSort {
    case nameAscending
    case nameDescending
    case type
    case status
}

/// Online/offline status of a Ring device.
enum DeviceStatus {
    case online
    case offline
}
