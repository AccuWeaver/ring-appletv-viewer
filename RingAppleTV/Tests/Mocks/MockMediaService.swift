import Foundation
@testable import RingAppleTV

/// Mock `MediaService` with configurable responses and call tracking.
/// Replaces `MockVideoService` and `MockSnapshotService` usage.
final class MockMediaService: MediaService, @unchecked Sendable {

    // MARK: - downloadVideo

    var downloadVideoResult: Result<URL, Error> = .failure(PartnerAPIError.notFound)
    var downloadVideoCalls: [(deviceId: String, eventId: String)] = []

    func downloadVideo(deviceId: String, eventId: String) async throws -> URL {
        downloadVideoCalls.append((deviceId: deviceId, eventId: eventId))
        return try downloadVideoResult.get()
    }

    // MARK: - downloadSnapshot

    var downloadSnapshotResult: Result<Data, Error> = .failure(PartnerAPIError.notFound)
    var downloadSnapshotCalls: [String] = []

    /// Per-device configurable results. If set, takes precedence over `downloadSnapshotResult`.
    var perDeviceSnapshotResults: [String: Result<Data, Error>] = [:]

    func downloadSnapshot(deviceId: String) async throws -> Data {
        downloadSnapshotCalls.append(deviceId)
        if let perDevice = perDeviceSnapshotResults[deviceId] {
            return try perDevice.get()
        }
        return try downloadSnapshotResult.get()
    }
}
