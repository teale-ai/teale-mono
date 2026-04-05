import Foundation
import SharedTypes
import HardwareProfile

// MARK: - Adaptive Throttler

@Observable
public final class AdaptiveThrottler: @unchecked Sendable {
    public let thermalMonitor: ThermalMonitor
    public let powerMonitor: PowerMonitor
    public let activityMonitor: UserActivityMonitor
    public let networkMonitor: NetworkMonitor

    public private(set) var throttleLevel: ThrottleLevel = .full
    public private(set) var pauseReason: PauseReason?

    /// Contribution schedule — controls when this node serves network requests
    public private(set) var contributionSchedule: ContributionSchedule

    /// Whether network contribution is currently allowed (schedule + conditions)
    public private(set) var shouldAllowNetworkContribution: Bool = true
    public private(set) var networkPauseReason: PauseReason?

    private var timer: Timer?

    public init() {
        self.thermalMonitor = ThermalMonitor()
        self.powerMonitor = PowerMonitor()
        self.activityMonitor = UserActivityMonitor()
        self.networkMonitor = NetworkMonitor()
        self.contributionSchedule = ContributionSchedule.loadFromDisk()
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    /// Update the contribution schedule and persist it
    public func updateSchedule(_ schedule: ContributionSchedule) {
        contributionSchedule = schedule
        schedule.save()
        evaluateNetworkContribution()
    }

    private func startMonitoring() {
        evaluate()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.evaluate()
        }
    }

    /// Evaluate conditions and determine throttle level
    public func evaluate() {
        let thermal = thermalMonitor.thermalLevel
        let power = powerMonitor.powerState
        let isIdle = !activityMonitor.isUserActive

        // Hard stops
        if power.isLowPowerMode {
            throttleLevel = .paused
            pauseReason = .lowPowerMode
            evaluateNetworkContribution()
            return
        }

        if thermal == .critical {
            throttleLevel = .paused
            pauseReason = .thermal
            evaluateNetworkContribution()
            return
        }

        if !power.isOnACPower {
            if let battery = power.batteryLevel, battery < 0.1 {
                throttleLevel = .paused
                pauseReason = .battery
                evaluateNetworkContribution()
                return
            }
        }

        // Graduated throttling
        pauseReason = nil

        if thermal == .serious {
            throttleLevel = .minimal
            evaluateNetworkContribution()
            return
        }

        if !power.isOnACPower {
            if let battery = power.batteryLevel, battery < 0.25 {
                throttleLevel = .minimal
                evaluateNetworkContribution()
                return
            }
            throttleLevel = .reduced
            evaluateNetworkContribution()
            return
        }

        if thermal == .fair {
            throttleLevel = .reduced
            evaluateNetworkContribution()
            return
        }

        // For contribution (Phase 2+): reduce when user is active
        // For local use: always allow full since user is actively requesting
        throttleLevel = .full
        evaluateNetworkContribution()
    }

    /// Whether inference should proceed right now (for local requests — always allowed unless hardware-paused)
    public var shouldAllowInference: Bool {
        throttleLevel > .paused
    }

    /// Evaluate whether network contribution is allowed based on schedule and conditions
    private func evaluateNetworkContribution() {
        // If hardware is paused, network is also paused (use the hardware reason)
        if throttleLevel == .paused {
            shouldAllowNetworkContribution = false
            networkPauseReason = pauseReason
            return
        }

        // Schedule check
        if !contributionSchedule.isActiveNow() {
            shouldAllowNetworkContribution = false
            networkPauseReason = .scheduledOff
            return
        }

        // Power condition
        if contributionSchedule.onlyWhenPluggedIn && !powerMonitor.powerState.isOnACPower {
            shouldAllowNetworkContribution = false
            networkPauseReason = .notPluggedIn
            return
        }

        // Wi-Fi condition
        if contributionSchedule.onlyOnWiFi && !networkMonitor.isOnWiFi {
            shouldAllowNetworkContribution = false
            networkPauseReason = .notOnWiFi
            return
        }

        shouldAllowNetworkContribution = true
        networkPauseReason = nil
    }
}
