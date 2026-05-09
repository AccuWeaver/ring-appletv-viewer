import Foundation

/// The origin of the video currently playing in `PlayerView`. Surfaced to the
/// UI so we can label the stream honestly (e.g. a "Recorded" or "Test Pattern"
/// pill when we can't show real live video).
enum StreamSource: Equatable {
    /// Live WebRTC via the partner API — the primary path on a real Apple TV.
    case liveWebRTC
    /// Live HLS bypass through the local SIP bridge + mediamtx. Used on the
    /// tvOS simulator where WebRTC frames don't render through Metal.
    case liveHLSBridge
    /// The most-recent recorded event for the device, fetched via the events
    /// API. Happens on the simulator when live HLS is unavailable.
    case recordedEvent
    /// Apple's BipBop HLS test stream. The last-resort fallback when no real
    /// content is reachable; indicates the UI chrome works but the feed isn't
    /// the user's camera.
    case testPattern
}

/// Domain model representing a live stream session from a Ring device.
///
/// Uses WHEP (WebRTC-HTTP Egress Protocol) for live streaming. The session URL
/// is the WHEP resource URL used for session termination via HTTP DELETE.
/// Session duration is derived from the device's power source.
struct StreamSession: Equatable {
    let deviceId: String
    let sessionURL: URL
    let powerSource: PowerSource
    let createdAt: Date
    /// Where the media in `sessionURL` is actually coming from. Defaults to
    /// live WebRTC so older call sites that predate the explicit source
    /// labeling keep their existing behaviour.
    let source: StreamSource
    /// Optional backend-side session id. Set for paths that allocate server
    /// resources we need to release on teardown (SIP bridge HLS, WHEP). `nil`
    /// for purely client-side fallbacks like the recorded event and test
    /// pattern cases.
    let backendSessionId: String?

    init(
        deviceId: String,
        sessionURL: URL,
        powerSource: PowerSource,
        createdAt: Date,
        source: StreamSource = .liveWebRTC,
        backendSessionId: String? = nil
    ) {
        self.deviceId = deviceId
        self.sessionURL = sessionURL
        self.powerSource = powerSource
        self.createdAt = createdAt
        self.source = source
        self.backendSessionId = backendSessionId
    }

    /// Maximum allowed session duration, derived from the device's power source.
    var maxDuration: TimeInterval {
        powerSource.sessionDurationLimit
    }

    /// Whether the stream session still has remaining time.
    var isValid: Bool {
        remainingTime > 0
    }

    /// Seconds remaining before the session expires. Always >= 0.
    var remainingTime: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(createdAt))
    }
}
