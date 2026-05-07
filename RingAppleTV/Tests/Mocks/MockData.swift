import Foundation
@testable import RingAppleTV

/// Reusable sample data for unit and integration tests.
enum MockData {

    // MARK: - Auth Tokens

    /// A valid token that expires 1 hour from now.
    static var validToken: AuthToken {
        AuthToken(
            accessToken: "valid-access-token-abc123",
            refreshToken: "valid-refresh-token-xyz789",
            expiresAt: Date().addingTimeInterval(3600),
            scope: "client",
            tokenType: "Bearer",
            clientId: nil
        )
    }

    /// An expired token (expired 1 hour ago).
    static var expiredToken: AuthToken {
        AuthToken(
            accessToken: "expired-access-token-old",
            refreshToken: "expired-refresh-token-old",
            expiresAt: Date().addingTimeInterval(-3600),
            scope: "client",
            tokenType: "Bearer",
            clientId: nil
        )
    }

    /// A token that needs refresh (expires in 30 seconds, within the 60-second refresh window).
    static var needsRefreshToken: AuthToken {
        AuthToken(
            accessToken: "soon-expiring-access-token",
            refreshToken: "soon-expiring-refresh-token",
            expiresAt: Date().addingTimeInterval(30),
            scope: "client",
            tokenType: "Bearer",
            clientId: nil
        )
    }

    // MARK: - Device Code Flow

    /// A sample device code response from the authorization server.
    static var deviceCodeResponse: DeviceCodeResponse {
        DeviceCodeResponse(
            deviceCode: "test-device-code-abc",
            userCode: "ABCD-1234",
            verificationUri: "https://oauth.ring.com/activate",
            verificationUriComplete: "https://oauth.ring.com/activate?user_code=ABCD-1234",
            expiresIn: 1800,
            interval: 5
        )
    }

    /// A sample DeviceCodeInfo for display in the UI.
    static var deviceCodeInfo: DeviceCodeInfo {
        DeviceCodeInfo(
            userCode: "ABCD-1234",
            verificationUri: "https://oauth.ring.com/activate",
            verificationUriComplete: "https://oauth.ring.com/activate?user_code=ABCD-1234",
            expiresIn: 1800,
            pollingInterval: 5,
            deviceCode: "test-device-code-abc"
        )
    }

    // MARK: - Devices

    /// A Ring Video Doorbell.
    static var doorbell: RingDevice {
        RingDevice(
            id: "1001",
            name: "Front Door",
            model: "doorbell",
            deviceType: .doorbell,
            firmwareVersion: "1.18.0",
            powerSource: .line,
            isOnline: true
        )
    }

    /// A Ring Stick Up Cam.
    static var stickupCam: RingDevice {
        RingDevice(
            id: "2002",
            name: "Backyard Camera",
            model: "stickup_cam",
            deviceType: .stickupCam,
            firmwareVersion: "2.4.1",
            powerSource: .battery,
            isOnline: true
        )
    }

    /// A Ring Indoor Cam (offline).
    static var indoorCam: RingDevice {
        RingDevice(
            id: "3003",
            name: "Living Room",
            model: "indoor_cam",
            deviceType: .indoorCam,
            firmwareVersion: "1.2.0",
            powerSource: .line,
            isOnline: false
        )
    }

    /// All sample devices.
    static var allDevices: [RingDevice] {
        [doorbell, stickupCam, indoorCam]
    }

    // MARK: - Partner Device Resources

    /// A sample PartnerDeviceResource for a doorbell.
    static var partnerDoorbellResource: PartnerDeviceResource {
        PartnerDeviceResource(
            id: "1001",
            type: "device",
            attributes: PartnerDeviceResource.DeviceAttributes(
                name: "Front Door",
                model: "doorbell",
                firmwareVersion: "1.18.0",
                powerSource: "line",
                status: "online"
            )
        )
    }

    /// A sample PartnerDeviceResource for a stickup cam.
    static var partnerStickupCamResource: PartnerDeviceResource {
        PartnerDeviceResource(
            id: "2002",
            type: "device",
            attributes: PartnerDeviceResource.DeviceAttributes(
                name: "Backyard Camera",
                model: "stickup_cam",
                firmwareVersion: "2.4.1",
                powerSource: "battery",
                status: "online"
            )
        )
    }

    /// A sample PartnerDeviceResource with unknown model and absent status.
    static var partnerUnknownDeviceResource: PartnerDeviceResource {
        PartnerDeviceResource(
            id: "9999",
            type: "device",
            attributes: PartnerDeviceResource.DeviceAttributes(
                name: "Future Device",
                model: "some_future_device",
                firmwareVersion: nil,
                powerSource: "battery",
                status: nil
            )
        )
    }

    // MARK: - Events

    /// A motion event from the doorbell.
    static var motionEvent: RingEvent {
        RingEvent(
            id: "5001",
            deviceId: "1001",
            eventType: .motion,
            createdAt: Date().addingTimeInterval(-1800),
            duration: 30
        )
    }

    /// A doorbell press (ding) event.
    static var dingEvent: RingEvent {
        RingEvent(
            id: "5002",
            deviceId: "1001",
            eventType: .ding,
            createdAt: Date().addingTimeInterval(-3600),
            duration: 15
        )
    }

    /// A motion event from the stickup cam.
    static var motionEventNoVideo: RingEvent {
        RingEvent(
            id: "5003",
            deviceId: "2002",
            eventType: .motion,
            createdAt: Date().addingTimeInterval(-7200),
            duration: 20
        )
    }

    /// All sample events.
    static var allEvents: [RingEvent] {
        [motionEvent, dingEvent, motionEventNoVideo]
    }

    // MARK: - Partner Event Resources

    /// A sample PartnerEventResource for a motion event.
    static var partnerMotionEventResource: PartnerEventResource {
        PartnerEventResource(
            id: "5001",
            deviceId: "1001",
            type: "motion",
            createdAt: "2025-01-15T10:30:00Z",
            duration: 30
        )
    }

    /// A sample PartnerEventResource for a ding event.
    static var partnerDingEventResource: PartnerEventResource {
        PartnerEventResource(
            id: "5002",
            deviceId: "1001",
            type: "ding",
            createdAt: "2025-01-15T09:30:00Z",
            duration: 15
        )
    }

    // MARK: - Stream Sessions

    /// A valid stream session created just now.
    static var validStreamSession: StreamSession {
        StreamSession(
            deviceId: "1001",
            sessionURL: URL(string: "https://api.amazonvision.com/v1/sessions/test-session")!,
            powerSource: .line,
            createdAt: Date()
        )
    }

    /// An expired stream session.
    static var expiredStreamSession: StreamSession {
        StreamSession(
            deviceId: "1001",
            sessionURL: URL(string: "https://api.amazonvision.com/v1/sessions/expired-session")!,
            powerSource: .line,
            createdAt: Date().addingTimeInterval(-700)
        )
    }

    // MARK: - WHEP Session

    /// A sample WHEPSessionResponse.
    static var whepSessionResponse: WHEPSessionResponse {
        WHEPSessionResponse(
            sdpAnswer: "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n",
            sessionURL: URL(string: "https://api.amazonvision.com/v1/devices/1001/media/streaming/whep/sessions/abc123")!
        )
    }

    // MARK: - Snapshots

    /// A minimal valid JPEG image (smallest possible 1×1 pixel JPEG).
    static var sampleJPEGData: Data {
        Data([
            0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46,
            0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01,
            0x00, 0x01, 0x00, 0x00, 0xFF, 0xD9
        ])
    }

    // MARK: - Power Source

    /// Battery power source.
    static var batteryPowerSource: PowerSource { .battery }

    /// Line power source.
    static var linePowerSource: PowerSource { .line }
}
