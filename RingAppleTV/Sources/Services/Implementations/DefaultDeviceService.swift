import Foundation

/// Production implementation of `DeviceService` that fetches Ring devices from
/// the Partner API with cache-first strategy, and provides filtering/sorting.
///
/// Uses `PartnerAPIClientProtocol` for JSON:API device resource fetching and
/// maps `PartnerDeviceResource` → `RingDevice` via `toDomain()`.
final class DefaultDeviceService: DeviceService, @unchecked Sendable {

    // MARK: - Dependencies

    private let authService: AuthService
    private let partnerAPIClient: PartnerAPIClientProtocol
    private let cacheService: CacheService

    // MARK: - Constants

    private static let cacheKey = "ring_devices"
    private static let cacheTTL: TimeInterval = 300 // 5 minutes

    // MARK: - Init

    init(authService: AuthService, partnerAPIClient: PartnerAPIClientProtocol, cacheService: CacheService) {
        self.authService = authService
        self.partnerAPIClient = partnerAPIClient
        self.cacheService = cacheService
    }

    // MARK: - DeviceService

    func fetchDevices() async throws -> [RingDevice] {
        // Try cache first
        if let cached = try? cacheService.load(for: Self.cacheKey, as: [RingDevice].self) {
            return cached
        }
        // Fall back to API
        return try await fetchFromAPI()
    }

    func filterDevices(_ devices: [RingDevice], by filter: DeviceFilter) -> [RingDevice] {
        switch filter {
        case .all:
            return devices
        case .name(let query):
            let lowered = query.lowercased()
            return devices.filter { $0.name.lowercased().contains(lowered) }
        case .type(let deviceType):
            return devices.filter { $0.deviceType == deviceType }
        case .status(let status):
            switch status {
            case .online:
                return devices.filter { $0.isOnline }
            case .offline:
                return devices.filter { !$0.isOnline }
            }
        }
    }

    func sortDevices(_ devices: [RingDevice], by sort: DeviceSort) -> [RingDevice] {
        switch sort {
        case .nameAscending:
            return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .nameDescending:
            return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending }
        case .type:
            return devices.sorted { $0.deviceType.rawValue < $1.deviceType.rawValue }
        case .status:
            // Online devices first
            return devices.sorted { $0.isOnline && !$1.isOnline }
        }
    }

    func refreshDevices() async throws -> [RingDevice] {
        return try await fetchFromAPI()
    }

    // MARK: - Private

    private func fetchFromAPI() async throws -> [RingDevice] {
        let token = try await authService.getValidToken()
        let resources = try await partnerAPIClient.fetchDevices(token: token.accessToken)
        let devices = resources.map { $0.toDomain() }
        try? cacheService.save(devices, for: Self.cacheKey, ttl: Self.cacheTTL)
        return devices
    }
}
