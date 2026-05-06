import XCTest
@testable import RingAppleTV

final class RingDeviceTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let device = RingDevice(
            id: "42", name: "Front Door", model: "doorbell_pro",
            deviceType: .doorbellPro, firmwareVersion: "1.2.3",
            powerSource: .line, isOnline: true
        )
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(RingDevice.self, from: data)
        XCTAssertEqual(decoded, device)
    }

    func testCodableRoundTripWithNilFirmware() throws {
        let device = RingDevice(
            id: "1", name: "Cam", model: "unknown",
            deviceType: .unknown, firmwareVersion: nil,
            powerSource: .battery, isOnline: false
        )
        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(RingDevice.self, from: data)
        XCTAssertEqual(decoded, device)
        XCTAssertNil(decoded.firmwareVersion)
    }

    // MARK: - Identifiable

    func testIdentifiableConformance() {
        let device = RingDevice(
            id: "99", name: "Back Yard", model: "stickup_cam",
            deviceType: .stickupCam, firmwareVersion: nil,
            powerSource: .battery, isOnline: true
        )
        XCTAssertEqual(device.id, "99")
    }

    // MARK: - Equatable

    func testEquatableForEqualDevices() {
        let a = RingDevice(
            id: "1", name: "D", model: "doorbell",
            deviceType: .doorbell, firmwareVersion: nil,
            powerSource: .battery, isOnline: true
        )
        let b = a
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentDevices() {
        let a = RingDevice(
            id: "1", name: "D", model: "doorbell",
            deviceType: .doorbell, firmwareVersion: nil,
            powerSource: .battery, isOnline: true
        )
        let b = RingDevice(
            id: "2", name: "D", model: "doorbell",
            deviceType: .doorbell, firmwareVersion: nil,
            powerSource: .battery, isOnline: true
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - PowerSource

    func testPowerSourceBattery() {
        let device = RingDevice(
            id: "1", name: "D", model: "doorbell",
            deviceType: .doorbell, firmwareVersion: nil,
            powerSource: .battery, isOnline: true
        )
        XCTAssertEqual(device.powerSource, .battery)
    }

    func testPowerSourceLine() {
        let device = RingDevice(
            id: "1", name: "D", model: "doorbell",
            deviceType: .doorbell, firmwareVersion: nil,
            powerSource: .line, isOnline: true
        )
        XCTAssertEqual(device.powerSource, .line)
    }

    func testMutableIsOnline() {
        var device = RingDevice(
            id: "1", name: "D", model: "doorbell",
            deviceType: .doorbell, firmwareVersion: nil,
            powerSource: .battery, isOnline: false
        )
        XCTAssertFalse(device.isOnline)
        device.isOnline = true
        XCTAssertTrue(device.isOnline)
    }
}

// MARK: - DeviceType Tests

final class DeviceTypeTests: XCTestCase {

    func testDoorbellRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.doorbell.rawValue, "doorbell")
    }

    func testUnknownRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.unknown.rawValue, "unknown")
    }

    func testDoorbellDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.doorbell.displayName, "Video Doorbell")
    }

    func testUnknownDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.unknown.displayName, "Camera")
    }

    func testUnrecognizedStringProducesNil() {
        XCTAssertNil(RingDevice.DeviceType(rawValue: "some_future_device"))
    }

    func testKnownRawValueRoundTrips() {
        for deviceType in RingDevice.DeviceType.allCases {
            XCTAssertEqual(
                RingDevice.DeviceType(rawValue: deviceType.rawValue),
                deviceType
            )
        }
    }

    func testAllCasesCount() {
        XCTAssertEqual(RingDevice.DeviceType.allCases.count, 8)
    }
}

// MARK: - PartnerDeviceResource Tests

final class PartnerDeviceResourceTests: XCTestCase {

    func testDecodingFromSnakeCaseJSON() throws {
        let json = """
        {
            "id": "12345",
            "type": "device",
            "attributes": {
                "name": "Front Door",
                "model": "doorbell_pro",
                "firmware_version": "1.4.26",
                "power_source": "line",
                "status": "online"
            }
        }
        """.data(using: .utf8)!

        let resource = try JSONDecoder().decode(PartnerDeviceResource.self, from: json)
        XCTAssertEqual(resource.id, "12345")
        XCTAssertEqual(resource.attributes.name, "Front Door")
        XCTAssertEqual(resource.attributes.model, "doorbell_pro")
    }

    func testToDomainProducesCorrectRingDevice() {
        let resource = PartnerDeviceResource(
            id: "42",
            type: "device",
            attributes: .init(
                name: "Back Yard", model: "spotlight_cam",
                firmwareVersion: "2.0.1", powerSource: "line", status: "online"
            )
        )
        let device = resource.toDomain()
        XCTAssertEqual(device.id, "42")
        XCTAssertEqual(device.name, "Back Yard")
        XCTAssertEqual(device.firmwareVersion, "2.0.1")
        XCTAssertTrue(device.isOnline)
    }

    func testToDomainWithUnknownModel() {
        let resource = PartnerDeviceResource(
            id: "1",
            type: "device",
            attributes: .init(
                name: "D", model: "some_future_device",
                firmwareVersion: nil, powerSource: "battery", status: nil
            )
        )
        let device = resource.toDomain()
        XCTAssertEqual(device.deviceType, .unknown)
    }

    func testToDomainDefaultsIsOnlineToTrueWhenStatusAbsent() {
        let resource = PartnerDeviceResource(
            id: "1",
            type: "device",
            attributes: .init(
                name: "D", model: "doorbell",
                firmwareVersion: nil, powerSource: "battery", status: nil
            )
        )
        XCTAssertTrue(resource.toDomain().isOnline)
    }
}
