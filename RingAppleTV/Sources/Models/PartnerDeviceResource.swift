import Foundation

/// JSON:API device resource from the Ring Partner API.
/// Maps the `data` element of a JSON:API device list response to a domain `RingDevice`.
struct PartnerDeviceResource: Codable, Equatable {
    let id: String
    let type: String
    let attributes: DeviceAttributes

    struct DeviceAttributes: Codable, Equatable {
        let name: String
        let model: String
        let firmwareVersion: String?
        let powerSource: String
        let status: String?

        enum CodingKeys: String, CodingKey {
            case name, model, status
            case firmwareVersion = "firmware_version"
            case powerSource = "power_source"
        }
    }

    /// Converts the Partner API resource into a domain `RingDevice`.
    ///
    /// - Uses `DeviceType(rawValue:) ?? .unknown` for unrecognized model strings.
    /// - Defaults `isOnline` to `true` when the `status` attribute is absent.
    func toDomain() -> RingDevice {
        RingDevice(
            id: id,
            name: attributes.name,
            model: attributes.model,
            deviceType: RingDevice.DeviceType(rawValue: attributes.model) ?? .unknown,
            firmwareVersion: attributes.firmwareVersion,
            powerSource: PowerSource(rawValue: attributes.powerSource) ?? .battery,
            isOnline: attributes.status.map { $0 == "online" } ?? true
        )
    }
}

/// JSON:API wrapper for the Partner API device list response.
struct PartnerDeviceListResponse: Codable, Equatable {
    let data: [PartnerDeviceResource]
}
