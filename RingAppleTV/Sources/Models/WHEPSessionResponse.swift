import Foundation

/// Response from a WHEP session creation request.
///
/// Not `Codable` — the SDP answer is parsed from the HTTP 201 response body
/// and the session URL is extracted from the `Location` header.
struct WHEPSessionResponse: Equatable {
    let sdpAnswer: String
    let sessionURL: URL
}
