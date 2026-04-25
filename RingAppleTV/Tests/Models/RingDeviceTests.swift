import XCTest
@testable import RingAppleTV

final class RingDeviceTests: XCTestCase {

    // MARK: - Codable Round-Trip

    func testCodableRoundTrip() throws {
        let device = RingDevice(
            id: 42,
            description: "Front Door",
            deviceType: .doorbellPro,
            firmwareVersion: "1.2.3",
            address: "123 Main St",
            batteryLife: 85,
            features: RingDevice.DeviceFeatures(motionDetection: true, nightVision: false),
            isOnline: true,
            snapshotURL: URL(string: "https://example.com/snap.jpg")
        )

        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(RingDevice.self, from: data)

        XCTAssertEqual(decoded, device)
    }

    func testCodableRoundTripWithAllNilOptionals() throws {
        let device = RingDevice(
            id: 1,
            description: "Cam",
            deviceType: .unknown,
            firmwareVersion: nil,
            address: nil,
            batteryLife: nil,
            features: nil,
            isOnline: false,
            snapshotURL: nil
        )

        let data = try JSONEncoder().encode(device)
        let decoded = try JSONDecoder().decode(RingDevice.self, from: data)

        XCTAssertEqual(decoded, device)
        XCTAssertNil(decoded.firmwareVersion)
        XCTAssertNil(decoded.address)
        XCTAssertNil(decoded.batteryLife)
        XCTAssertNil(decoded.features)
        XCTAssertNil(decoded.snapshotURL)
    }

    // MARK: - Identifiable

    func testIdentifiableConformance() {
        let device = RingDevice(
            id: 99,
            description: "Back Yard",
            deviceType: .stickupCam,
            firmwareVersion: nil,
            address: nil,
            batteryLife: nil,
            features: nil,
            isOnline: true,
            snapshotURL: nil
        )

        XCTAssertEqual(device.id, 99)
    }

    // MARK: - Equatable

    func testEquatableForEqualDevices() {
        let a = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: nil
        )
        let b = a
        XCTAssertEqual(a, b)
    }

    func testEquatableForDifferentDevices() {
        let a = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: nil
        )
        let b = RingDevice(
            id: 2, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: nil
        )
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Optional Properties

    func testOptionalBatteryLifeNil() {
        let device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: nil
        )
        XCTAssertNil(device.batteryLife)
    }

    func testOptionalBatteryLifePresent() {
        let device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: 72,
            features: nil, isOnline: true, snapshotURL: nil
        )
        XCTAssertEqual(device.batteryLife, 72)
    }

    func testOptionalFeaturesNil() {
        let device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: nil
        )
        XCTAssertNil(device.features)
    }

    func testOptionalFeaturesPresent() {
        let features = RingDevice.DeviceFeatures(motionDetection: true, nightVision: true)
        let device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: features, isOnline: true, snapshotURL: nil
        )
        XCTAssertEqual(device.features?.motionDetection, true)
        XCTAssertEqual(device.features?.nightVision, true)
    }

    func testOptionalSnapshotURLNil() {
        let device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: nil
        )
        XCTAssertNil(device.snapshotURL)
    }

    func testOptionalSnapshotURLPresent() {
        let url = URL(string: "https://example.com/snap.jpg")!
        let device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: true, snapshotURL: url
        )
        XCTAssertEqual(device.snapshotURL, url)
    }

    func testMutableIsOnline() {
        var device = RingDevice(
            id: 1, description: "D", deviceType: .doorbell,
            firmwareVersion: nil, address: nil, batteryLife: nil,
            features: nil, isOnline: false, snapshotURL: nil
        )
        XCTAssertFalse(device.isOnline)
        device.isOnline = true
        XCTAssertTrue(device.isOnline)
    }
}

// MARK: - DeviceType Tests

final class DeviceTypeTests: XCTestCase {

    // MARK: - Raw Values

    func testDoorbellRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.doorbell.rawValue, "doorbell")
    }

    func testDoorbellProRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.doorbellPro.rawValue, "doorbell_pro")
    }

    func testDoorbellV2RawValue() {
        XCTAssertEqual(RingDevice.DeviceType.doorbellV2.rawValue, "doorbell_v2")
    }

    func testStickupCamRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.stickupCam.rawValue, "stickup_cam")
    }

    func testSpotlightCamRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.spotlightCam.rawValue, "spotlight_cam")
    }

    func testFloodlightCamRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.floodlightCam.rawValue, "floodlight_cam")
    }

    func testIndoorCamRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.indoorCam.rawValue, "indoor_cam")
    }

    func testUnknownRawValue() {
        XCTAssertEqual(RingDevice.DeviceType.unknown.rawValue, "unknown")
    }

    // MARK: - Display Names

    func testDoorbellDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.doorbell.displayName, "Video Doorbell")
    }

    func testDoorbellProDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.doorbellPro.displayName, "Video Doorbell")
    }

    func testDoorbellV2DisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.doorbellV2.displayName, "Video Doorbell")
    }

    func testStickupCamDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.stickupCam.displayName, "Stick Up Cam")
    }

    func testSpotlightCamDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.spotlightCam.displayName, "Spotlight Cam")
    }

    func testFloodlightCamDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.floodlightCam.displayName, "Floodlight Cam")
    }

    func testIndoorCamDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.indoorCam.displayName, "Indoor Cam")
    }

    func testUnknownDisplayName() {
        XCTAssertEqual(RingDevice.DeviceType.unknown.displayName, "Camera")
    }

    // MARK: - Unknown Case for Unrecognized Strings

    func testUnrecognizedStringProducesNil() {
        XCTAssertNil(RingDevice.DeviceType(rawValue: "some_future_device"))
    }

    func testEmptyStringProducesNil() {
        XCTAssertNil(RingDevice.DeviceType(rawValue: ""))
    }

    func testKnownRawValueRoundTrips() {
        for deviceType in RingDevice.DeviceType.allCases {
            XCTAssertEqual(
                RingDevice.DeviceType(rawValue: deviceType.rawValue),
                deviceType,
                "Round-trip failed for \(deviceType)"
            )
        }
    }

    // MARK: - Codable

    func testDeviceTypeCodableRoundTrip() throws {
        for deviceType in RingDevice.DeviceType.allCases {
            let data = try JSONEncoder().encode(deviceType)
            let decoded = try JSONDecoder().decode(RingDevice.DeviceType.self, from: data)
            XCTAssertEqual(decoded, deviceType)
        }
    }

    func testDeviceTypeDecodesFromRawValueJSON() throws {
        let json = "\"stickup_cam\"".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RingDevice.DeviceType.self, from: json)
        XCTAssertEqual(decoded, .stickupCam)
    }

    // MARK: - CaseIterable

    func testAllCasesCount() {
        XCTAssertEqual(RingDevice.DeviceType.allCases.count, 8)
    }
}


// MARK: - DeviceFeatures Tests

final class DeviceFeaturesTests: XCTestCase {

    func testCodableRoundTrip() throws {
        let features = RingDevice.DeviceFeatures(motionDetection: true, nightVision: false)
        let data = try JSONEncoder().encode(features)
        let decoded = try JSONDecoder().decode(RingDevice.DeviceFeatures.self, from: data)
        XCTAssertEqual(decoded, features)
    }

    func testEquatable() {
        let a = RingDevice.DeviceFeatures(motionDetection: true, nightVision: true)
        let b = RingDevice.DeviceFeatures(motionDetection: true, nightVision: true)
        let c = RingDevice.DeviceFeatures(motionDetection: false, nightVision: true)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}

// MARK: - RingDeviceResponse Tests

final class RingDeviceResponseTests: XCTestCase {

    // MARK: - JSON Decoding with snake_case keys

    func testDecodingFromSnakeCaseJSON() throws {
        let json = """
        {
            "id": 12345,
            "description": "Front Door",
            "kind": "doorbell_pro",
            "firmware_version": "1.4.26",
            "address": "123 Main St",
            "battery_life": "85",
            "features": {"motion_detection": true, "night_vision": false}
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RingDeviceResponse.self, from: json)

        XCTAssertEqual(response.id, 12345)
        XCTAssertEqual(response.description, "Front Door")
        XCTAssertEqual(response.kind, "doorbell_pro")
        XCTAssertEqual(response.firmwareVersion, "1.4.26")
        XCTAssertEqual(response.address, "123 Main St")
        XCTAssertEqual(response.batteryLife, "85")
        XCTAssertEqual(response.features?["motion_detection"], true)
        XCTAssertEqual(response.features?["night_vision"], false)
    }

    func testDecodingWithNullOptionals() throws {
        let json = """
        {
            "id": 1,
            "description": "Cam",
            "kind": "stickup_cam",
            "firmware_version": null,
            "address": null,
            "battery_life": null,
            "features": null
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RingDeviceResponse.self, from: json)

        XCTAssertNil(response.firmwareVersion)
        XCTAssertNil(response.address)
        XCTAssertNil(response.batteryLife)
        XCTAssertNil(response.features)
    }

    func testDecodingWithMissingOptionals() throws {
        let json = """
        {
            "id": 1,
            "description": "Cam",
            "kind": "indoor_cam"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(RingDeviceResponse.self, from: json)

        XCTAssertEqual(response.id, 1)
        XCTAssertEqual(response.kind, "indoor_cam")
        XCTAssertNil(response.firmwareVersion)
        XCTAssertNil(response.address)
        XCTAssertNil(response.batteryLife)
        XCTAssertNil(response.features)
    }

    // MARK: - toDomain()

    func testToDomainProducesCorrectRingDevice() {
        let response = RingDeviceResponse(
            id: 42,
            description: "Back Yard",
            kind: "spotlight_cam",
            firmwareVersion: "2.0.1",
            address: "456 Oak Ave",
            batteryLife: "72",
            features: ["motion_detection": true]
        )

        let device = response.toDomain()

        XCTAssertEqual(device.id, 42)
        XCTAssertEqual(device.description, "Back Yard")
        XCTAssertEqual(device.deviceType, .spotlightCam)
        XCTAssertEqual(device.firmwareVersion, "2.0.1")
        XCTAssertEqual(device.address, "456 Oak Ave")
        XCTAssertEqual(device.batteryLife, 72)
        XCTAssertNil(device.features) // features dict is not mapped to DeviceFeatures
        XCTAssertTrue(device.isOnline)
        XCTAssertNil(device.snapshotURL)
    }

    func testToDomainWithUnknownKind() {
        let response = RingDeviceResponse(
            id: 1,
            description: "D",
            kind: "some_future_device",
            firmwareVersion: nil,
            address: nil,
            batteryLife: nil,
            features: nil
        )

        let device = response.toDomain()
        XCTAssertEqual(device.deviceType, .unknown)
    }

    func testToDomainWithNonNumericBatteryLife() {
        let response = RingDeviceResponse(
            id: 1,
            description: "D",
            kind: "doorbell",
            firmwareVersion: nil,
            address: nil,
            batteryLife: "not_a_number",
            features: nil
        )

        let device = response.toDomain()
        XCTAssertNil(device.batteryLife)
    }

    func testToDomainWithNilBatteryLife() {
        let response = RingDeviceResponse(
            id: 1,
            description: "D",
            kind: "doorbell",
            firmwareVersion: nil,
            address: nil,
            batteryLife: nil,
            features: nil
        )

        let device = response.toDomain()
        XCTAssertNil(device.batteryLife)
    }

    func testToDomainMapsAllKnownDeviceTypes() {
        let kinds = [
            ("doorbell", RingDevice.DeviceType.doorbell),
            ("doorbell_pro", RingDevice.DeviceType.doorbellPro),
            ("doorbell_v2", RingDevice.DeviceType.doorbellV2),
            ("stickup_cam", RingDevice.DeviceType.stickupCam),
            ("spotlight_cam", RingDevice.DeviceType.spotlightCam),
            ("floodlight_cam", RingDevice.DeviceType.floodlightCam),
            ("indoor_cam", RingDevice.DeviceType.indoorCam),
        ]

        for (kind, expectedType) in kinds {
            let response = RingDeviceResponse(
                id: 1, description: "D", kind: kind,
                firmwareVersion: nil, address: nil,
                batteryLife: nil, features: nil
            )
            XCTAssertEqual(
                response.toDomain().deviceType, expectedType,
                "Kind '\(kind)' should map to \(expectedType)"
            )
        }
    }

    func testToDomainDefaultsIsOnlineToTrue() {
        let response = RingDeviceResponse(
            id: 1, description: "D", kind: "doorbell",
            firmwareVersion: nil, address: nil,
            batteryLife: nil, features: nil
        )
        XCTAssertTrue(response.toDomain().isOnline)
    }
}
