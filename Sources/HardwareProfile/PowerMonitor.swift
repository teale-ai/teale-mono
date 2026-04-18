import Foundation
import Combine
import SharedTypes

#if os(macOS)
import IOKit.ps
#endif

// MARK: - Power Monitor

@Observable
public final class PowerMonitor: @unchecked Sendable {
    public private(set) var powerState: PowerState = PowerState(isOnACPower: true)
    private var timer: Timer?

    public init() {
        updatePowerState()
        startMonitoring()
    }

    deinit {
        timer?.invalidate()
    }

    private func startMonitoring() {
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.updatePowerState()
        }
    }

    private func updatePowerState() {
        #if os(macOS)
        powerState = detectMacOSPowerState()
        #else
        powerState = PowerState(isOnACPower: true)
        #endif
    }

    #if os(macOS)
    private func detectMacOSPowerState() -> PowerState {
        let snapshot = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(snapshot).takeRetainedValue() as? [CFTypeRef] ?? []

        // Default: AC power, no battery (desktop Mac)
        if sources.isEmpty {
            return PowerState(isOnACPower: true, batteryLevel: nil, isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source).takeUnretainedValue() as? [String: Any] else {
                continue
            }

            let isCharging = info[kIOPSIsChargingKey] as? Bool ?? false
            let powerSource = info[kIOPSPowerSourceStateKey] as? String
            let isOnACPower = powerSource == kIOPSACPowerValue || isCharging
            let currentCapacity = info[kIOPSCurrentCapacityKey] as? Int ?? 100
            let maxCapacity = info[kIOPSMaxCapacityKey] as? Int ?? 100
            let batteryLevel = Double(currentCapacity) / Double(max(maxCapacity, 1))

            return PowerState(
                isOnACPower: isOnACPower,
                batteryLevel: batteryLevel,
                isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
            )
        }

        return PowerState(isOnACPower: true, batteryLevel: nil, isLowPowerMode: false)
    }
    #endif
}
