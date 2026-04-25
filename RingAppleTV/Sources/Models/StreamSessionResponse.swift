import Foundation

/// DTO for the JSON response from Ring's live stream endpoint.
/// Maps snake_case JSON keys to Swift properties and converts to the domain `StreamSession`.
struct StreamSessionResponse: Codable {
    let deviceId: Int
    let hlsURL: String
    let maxDuration: Int

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case hlsURL = "hls_url"
        case maxDuration = "max_duration"
    }

    /// Converts the API response into a domain `StreamSession`, computing `createdAt` as now.
    func toDomain() -> StreamSession {
        StreamSession(
            deviceId: deviceId,
            hlsURL: URL(string: hlsURL) ?? URL(string: "about:blank")!,
            createdAt: Date(),
            maxDuration: TimeInterval(maxDuration)
        )
    }
}
