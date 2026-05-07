import Foundation
import os

#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS))
import BackgroundTasks
#endif

/// Manages tvOS background app refresh for pre-fetching camera snapshots.
/// Registers a `BGAppRefreshTask` that fetches the device list and snapshots
/// for up to 10 devices, storing results in the snapshot cache so they're
/// ready when the user opens the app.
///
/// `BGTaskScheduler` is unavailable on macOS, so on that platform the
/// implementation reduces to a no-op stub. This keeps the Swift package
/// buildable in the CI's default macOS environment without conditional
/// imports leaking into every caller.
final class BackgroundRefreshManager: @unchecked Sendable {

    // MARK: - Constants

    static let taskIdentifier = "com.ringappletv.snapshot-refresh"

    /// Maximum number of devices to fetch snapshots for during background refresh.
    private static let maxDevicesPerRefresh = 10

    /// Earliest time (in seconds) before the next background refresh is eligible to run.
    private static let refreshInterval: TimeInterval = 15 * 60 // 15 minutes

    // MARK: - Dependencies

    nonisolated(unsafe) private let deviceService: DeviceService
    private let snapshotService: SnapshotService

    // MARK: - Logging

    private let logger = Logger(subsystem: "com.ringappletv", category: "BackgroundRefresh")

    // MARK: - Init

    init(deviceService: DeviceService, snapshotService: SnapshotService) {
        self.deviceService = deviceService
        self.snapshotService = snapshotService
    }

    // MARK: - Registration

#if canImport(BackgroundTasks) && (os(iOS) || os(tvOS))

    /// Register the background refresh task handler with `BGTaskScheduler`.
    /// Must be called before the end of the app launch sequence (e.g. in `App.init`).
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else { return }
            self.handleBackgroundRefresh(refreshTask)
        }
        logger.debug("Registered background refresh task: \(Self.taskIdentifier)")
    }

    /// Schedule the next background app refresh request.
    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshInterval)

        do {
            try BGTaskScheduler.shared.submit(request)
            logger.debug("Scheduled next background refresh in \(Self.refreshInterval)s")
        } catch {
            logger.error("Failed to schedule background refresh: \(error.localizedDescription)")
        }
    }

    // MARK: - Handler

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        // Schedule the next refresh before starting work
        scheduleNextRefresh()

        let deviceService = self.deviceService
        let snapshotService = self.snapshotService
        let logger = self.logger
        nonisolated(unsafe) let bgTask = task

        let workTask = Task {
            do {
                // Fetch device list
                let devices = try await deviceService.fetchDevices()

                // Take up to 10 devices
                let devicesToRefresh = Array(devices.prefix(Self.maxDevicesPerRefresh))

                logger.debug("Background refresh: fetching snapshots for \(devicesToRefresh.count) devices")

                // Fetch snapshots in parallel — results are stored in the snapshot cache
                // by the SnapshotService automatically
                await withTaskGroup(of: Void.self) { group in
                    for device in devicesToRefresh {
                        let deviceId = device.id
                        group.addTask {
                            do {
                                _ = try await snapshotService.getSnapshot(for: deviceId)
                            } catch {
                                // Silently ignore individual snapshot failures during background refresh
                            }
                        }
                    }
                }

                bgTask.setTaskCompleted(success: true)
                logger.debug("Background refresh completed successfully")
            } catch {
                logger.error("Background refresh failed: \(error.localizedDescription)")
                bgTask.setTaskCompleted(success: false)
            }
        }

        // If the system needs to terminate the background task early, cancel our work
        task.expirationHandler = {
            workTask.cancel()
        }
    }

#else

    /// macOS stub — `BGTaskScheduler` is unavailable on that platform.
    func registerBackgroundTask() {
        logger.debug("BackgroundRefreshManager.registerBackgroundTask: no-op on this platform")
    }

    /// macOS stub — `BGTaskScheduler` is unavailable on that platform.
    func scheduleNextRefresh() {
        logger.debug("BackgroundRefreshManager.scheduleNextRefresh: no-op on this platform")
    }

#endif
}
