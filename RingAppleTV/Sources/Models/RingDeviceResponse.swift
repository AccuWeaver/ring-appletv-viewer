import Foundation

/// DTO for the JSON response from Ring's device list endpoint.
/// Maps snake_case JSON keys to Swift properties and converts to the domain `RingDevice`.
struct RingDeviceResponse: Codable {
    let id: Int
    let description: String
    let kind: String
    let firmwareVersion: String?
    let address: String?
    let batteryLife: String?
    let features: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case id, description, kind
        case firmwareVersion = "firmware_version"
        case address
        case batteryLife = "battery_life"
        case features
    }

    /// Converts the API response into a domain `RingDevice`.
    func toDomain() -> RingDevice {
        RingDevice(
            id: id,
            description: description,
            deviceType: RingDevice.DeviceType(rawValue: kind) ?? .unknown,
            firmwareVersion: firmwareVersion,
            address: address,
            batteryLife: batteryLife.flatMap { Int($0) },
            features: nil,
            isOnline: true,
            snapshotURL: nil
        )
    }
}
