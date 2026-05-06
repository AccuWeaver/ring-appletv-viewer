import Foundation

/// Consolidates video clip download and snapshot image download into a single service.
/// Replaces the separate `VideoService` and `SnapshotService` protocols.
protocol MediaService: Sendable {
    /// Download a video clip for a specific event. Returns the playable video URL.
    func downloadVideo(deviceId: String, eventId: String) async throws -> URL
    /// Download the latest cached snapshot image for a device. Returns raw image data.
    func downloadSnapshot(deviceId: String) async throws -> Data
}
