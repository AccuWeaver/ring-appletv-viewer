import Foundation

/// DTO for the JSON response from Ring's live stream endpoint.
///
/// Ring's live view API returns a SIP/WebRTC session, not an HLS URL.
/// This model captures the actual response fields. The `toDomain()` method
/// constructs a `StreamSession` — but since Ring doesn't provide HLS,
/// live streaming requires a WebRTC implementation (future work).
struct StreamSessionResponse: Codable {
    let sipServerIp: String?
    let sipServerPort: Int?
    let sipServerTls: Bool?
    let sipSessionId: String?
    let sipFrom: String?
    let sipTo: String?
    let sipToken: String?
    let sipEndpoints: [String]?
    let doorbotId: Int
    let expiresIn: Int?
    let protocol_: String?
    let state: String?

    enum CodingKeys: String, CodingKey {
        case sipServerIp = "sip_server_ip"
        case sipServerPort = "sip_server_port"
        case sipServerTls = "sip_server_tls"
        case sipSessionId = "sip_session_id"
        case sipFrom = "sip_from"
        case sipTo = "sip_to"
        case sipToken = "sip_token"
        case sipEndpoints = "sip_endpoints"
        case doorbotId = "doorbot_id"
        case expiresIn = "expires_in"
        case protocol_ = "protocol"
        case state
    }

    /// Converts the API response into a domain `StreamSession`.
    /// Since Ring uses SIP/WebRTC (not HLS), the hlsURL is a placeholder
    /// and live video playback is not yet supported.
    func toDomain() -> StreamSession {
        StreamSession(
            deviceId: doorbotId,
            sipServerIp: sipServerIp,
            sipServerPort: sipServerPort,
            sipSessionId: sipSessionId,
            protocol_: protocol_ ?? "sip",
            createdAt: Date(),
            maxDuration: TimeInterval(expiresIn ?? 600)
        )
    }
}
