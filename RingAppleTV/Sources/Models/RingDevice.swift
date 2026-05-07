import Foundation

/// Domain model representing a Ring camera or doorbell device.
struct RingDevice: Codable, Identifiable, Equatable {
    let id: Int
    let description: String
    let deviceType: DeviceType
    let firmwareVersion: String?
    let address: String?
    let batteryLife: Int?
    let features: DeviceFeatures?
    var isOnline: Bool

    // MARK: - DeviceType

    enum DeviceType: String, Codable, CaseIterable {
        case doorbell
        case doorbellPro = "doorbell_pro"
        case doorbellV2 = "doorbell_v2"
        case stickupCam = "stickup_cam"
        case spotlightCam = "spotlight_cam"
        case floodlightCam = "floodlight_cam"
        case indoorCam = "indoor_cam"
        case unknown

        var displayName: String {
            switch self {
            case .doorbell, .doorbellPro, .doorbellV2:
                return "Video Doorbell"
            case .stickupCam:
                return "Stick Up Cam"
            case .spotlightCam:
                return "Spotlight Cam"
            case .floodlightCam:
                return "Floodlight Cam"
            case .indoorCam:
                return "Indoor Cam"
            case .unknown:
                return "Camera"
            }
        }
    }

    // MARK: - DeviceFeatures

    struct DeviceFeatures: Codable, Equatable {
        let motionDetection: Bool
        let nightVision: Bool
    }
}
