import Foundation

/// Manages the device dashboard: loading, filtering, sorting, and background refresh.
@MainActor
final class DashboardViewModel: ObservableObject {

    // MARK: - Published State

    @Published var state: ViewState<[RingDevice]> = .idle
    @Published var currentFilter: DeviceFilter = .all
    @Published var currentSort: DeviceSort = .nameAscending
    @Published var snapshots: [Int: Data] = [:]

    // MARK: - Dependencies

    nonisolated(unsafe) private let deviceService: DeviceService
    nonisolated(unsafe) private let snapshotService: SnapshotService

    // MARK: - Background Refresh

    private var refreshTask: Task<Void, Never>?
    private let refreshInterval: TimeInterval

    // MARK: - Internal cache of raw devices

    private var allDevices: [RingDevice] = []

    // MARK: - Init

    init(deviceService: DeviceService, snapshotService: SnapshotService, refreshInterval: TimeInterval = 60) {
        self.deviceService = deviceService
        self.snapshotService = snapshotService
        self.refreshInterval = refreshInterval
    }

    deinit {
        refreshTask?.cancel()
    }

    // MARK: - Actions

    /// Load devices from the service, apply current filter/sort, and start background refresh.
    func loadDevices() async {
        state = .loading

        do {
            let devices = try await deviceService.fetchDevices()
            allDevices = devices
            applyFilterAndSort()
            await loadSnapshots(for: devices)
            startBackgroundRefresh()
        } catch let error as RingAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Force refresh from the API (bypasses cache).
    func refresh() async {
        state = .loading

        do {
            let devices = try await deviceService.refreshDevices()
            allDevices = devices
            applyFilterAndSort()
        } catch let error as RingAPIError {
            state = .error(error.userMessage)
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Update the active filter and re-apply.
    func applyFilter(_ filter: DeviceFilter) {
        currentFilter = filter
        applyFilterAndSort()
    }

    /// Update the active sort and re-apply.
    func applySort(_ sort: DeviceSort) {
        currentSort = sort
        applyFilterAndSort()
    }

    /// Stop background refresh (e.g. when view disappears).
    func stopBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    // MARK: - Private

    private func applyFilterAndSort() {
        let filtered = deviceService.filterDevices(allDevices, by: currentFilter)
        let sorted = deviceService.sortDevices(filtered, by: currentSort)

        if sorted.isEmpty {
            state = .empty("No devices found.")
        } else {
            state = .loaded(sorted)
        }
    }

    private func startBackgroundRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64((self?.refreshInterval ?? 60) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                do {
                    guard let self else { return }
                    let devices = try await self.deviceService.refreshDevices()
                    self.allDevices = devices
                    self.applyFilterAndSort()
                    await self.loadSnapshots(for: devices)
                } catch {
                    // Silently ignore background refresh errors to avoid disrupting the UI.
                }
            }
        }
    }

    /// Fetch snapshots for all devices in parallel, updating the `snapshots` dictionary.
    /// Individual failures are logged but do not affect other devices.
    private func loadSnapshots(for devices: [RingDevice]) async {
        let results = await Self.fetchAllSnapshots(for: devices, using: snapshotService)
        for (deviceId, data) in results {
            if let data {
                snapshots[deviceId] = data
            }
        }
    }

    /// Nonisolated helper that performs parallel snapshot fetches.
    nonisolated private static func fetchAllSnapshots(
        for devices: [RingDevice],
        using service: SnapshotService
    ) async -> [(Int, Data?)] {
        await withTaskGroup(of: (Int, Data?).self) { group in
            for device in devices {
                let deviceId = device.id
                group.addTask {
                    do {
                        let data = try await service.getSnapshot(for: deviceId)
                        return (deviceId, data)
                    } catch {
                        print(
                            "[DashboardViewModel] Snapshot fetch failed for device \(deviceId): "
                            + error.localizedDescription
                        )
                        return (deviceId, nil)
                    }
                }
            }
            var collected: [(Int, Data?)] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
    }
}
