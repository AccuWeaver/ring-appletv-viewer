import Foundation

/// Power source of a Ring device, determining session duration limits.
enum PowerSource: String, Codable {
    case battery
    case line

    /// Maximum allowed live-stream duration based on power source.
    /// Battery-powered devices have shorter sessions to conserve charge.
    var sessionDurationLimit: TimeInterval {
        switch self {
        case .battery: return 30
        case .line: return 60
        }
    }
}
