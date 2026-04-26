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
            tokenType: "Bearer"
        )
    }

    /// An expired token (expired 1 hour ago).
    static var expiredToken: AuthToken {
        AuthToken(
            accessToken: "expired-access-token-old",
            refreshToken: "expired-refresh-token-old",
            expiresAt: Date().addingTimeInterval(-3600),
            scope: "client",
            tokenType: "Bearer"
        )
    }

    /// A token that needs refresh (expires in 2 minutes, within the 5-minute refresh window).
    static var needsRefreshToken: AuthToken {
        AuthToken(
            accessToken: "soon-expiring-access-token",
            refreshToken: "soon-expiring-refresh-token",
            expiresAt: Date().addingTimeInterval(120),
            scope: "client",
            tokenType: "Bearer"
        )
    }

    // MARK: - Devices

    /// A Ring Video Doorbell.
    static var doorbell: RingDevice {
        RingDevice(
            id: 1001,
            description: "Front Door",
            deviceType: .doorbell,
            firmwareVersion: "1.18.0",
            address: "123 Main St",
            batteryLife: 85,
            features: RingDevice.DeviceFeatures(motionDetection: true, nightVision: true),
            isOnline: true,
            snapshotURL: nil
        )
    }

    /// A Ring Stick Up Cam.
    static var stickupCam: RingDevice {
        RingDevice(
            id: 2002,
            description: "Backyard Camera",
            deviceType: .stickupCam,
            firmwareVersion: "2.4.1",
            address: nil,
            batteryLife: 62,
            features: RingDevice.DeviceFeatures(motionDetection: true, nightVision: true),
            isOnline: true,
            snapshotURL: nil
        )
    }

    /// A Ring Indoor Cam (offline).
    static var indoorCam: RingDevice {
        RingDevice(
            id: 3003,
            description: "Living Room",
            deviceType: .indoorCam,
            firmwareVersion: "1.2.0",
            address: nil,
            batteryLife: nil,
            features: RingDevice.DeviceFeatures(motionDetection: true, nightVision: false),
            isOnline: false,
            snapshotURL: nil
        )
    }

    /// All sample devices.
    static var allDevices: [RingDevice] {
        [doorbell, stickupCam, indoorCam]
    }

    // MARK: - Events

    /// A motion event from the doorbell.
    static var motionEvent: RingEvent {
        RingEvent(
            id: 5001,
            deviceId: 1001,
            deviceName: "Front Door",
            eventType: .motion,
            createdAt: Date().addingTimeInterval(-1800),
            duration: 30,
            thumbnailURL: URL(string: "https://ring.com/thumb/5001.jpg"),
            videoAvailable: true
        )
    }

    /// A doorbell press (ding) event.
    static var dingEvent: RingEvent {
        RingEvent(
            id: 5002,
            deviceId: 1001,
            deviceName: "Front Door",
            eventType: .ding,
            createdAt: Date().addingTimeInterval(-3600),
            duration: 15,
            thumbnailURL: URL(string: "https://ring.com/thumb/5002.jpg"),
            videoAvailable: true
        )
    }

    /// A motion event from the stickup cam (no video).
    static var motionEventNoVideo: RingEvent {
        RingEvent(
            id: 5003,
            deviceId: 2002,
            deviceName: "Backyard Camera",
            eventType: .motion,
            createdAt: Date().addingTimeInterval(-7200),
            duration: 20,
            thumbnailURL: nil,
            videoAvailable: false
        )
    }

    /// All sample events.
    static var allEvents: [RingEvent] {
        [motionEvent, dingEvent, motionEventNoVideo]
    }

    // MARK: - Stream Sessions

    /// A valid stream session created just now.
    static var validStreamSession: StreamSession {
        StreamSession(
            deviceId: 1001,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date(),
            maxDuration: 600
        )
    }

    /// An expired stream session.
    static var expiredStreamSession: StreamSession {
        StreamSession(
            deviceId: 1001,
            sipServerIp: "52.12.182.65",
            sipServerPort: 15064,
            sipSessionId: "test-session",
            protocol_: "sip",
            createdAt: Date().addingTimeInterval(-700),
            maxDuration: 600
        )
    }
}
