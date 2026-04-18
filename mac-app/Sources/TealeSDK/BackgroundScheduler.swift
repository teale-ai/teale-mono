import Foundation

#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

// MARK: - Background Scheduler

/// Manages background execution for resource contribution.
/// iOS: Uses BGProcessingTask for overnight/charging contribution windows.
/// macOS: Uses a simple long-running Task (no BGTaskScheduler needed).
public final class BackgroundScheduler: Sendable {
    private let appID: String
    private let onContribute: @Sendable () async -> Void

    public var taskIdentifier: String {
        "com.teale.sdk.contribute.\(appID)"
    }

    public init(appID: String, onContribute: @escaping @Sendable () async -> Void) {
        self.appID = appID
        self.onContribute = onContribute
    }

    // MARK: - iOS Background Tasks

    #if os(iOS)
    /// Register the background task with the system.
    /// Developer must also add the task identifier to Info.plist BGTaskSchedulerPermittedIdentifiers.
    public func registerBackgroundTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { [weak self] task in
            guard let self = self, let processingTask = task as? BGProcessingTask else { return }
            self.handleBackgroundTask(processingTask)
        }
    }

    /// Schedule the next background contribution window
    public func scheduleNextContribution(requiresCharging: Bool = true) {
        let request = BGProcessingTaskRequest(identifier: taskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = requiresCharging
        // Schedule for at least 15 minutes from now
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)

        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            // Scheduling failed — will retry on next app launch
        }
    }

    private func handleBackgroundTask(_ task: BGProcessingTask) {
        // Schedule the next one before we start
        scheduleNextContribution()

        let contributionTask = Task {
            await onContribute()
        }

        task.expirationHandler = {
            contributionTask.cancel()
        }

        Task {
            await contributionTask.value
            task.setTaskCompleted(success: true)
        }
    }
    #endif

    // MARK: - macOS Background

    #if os(macOS)
    /// On macOS, no special registration is needed.
    /// The app can run tasks in the background while open.
    public func registerBackgroundTasks() {
        // No-op on macOS
    }

    public func scheduleNextContribution(requiresCharging: Bool = true) {
        // No-op on macOS — contribution runs while app is open
    }
    #endif
}
