import Foundation
import Combine
import SharedTypes

// MARK: - Thermal Monitor

@Observable
public final class ThermalMonitor: @unchecked Sendable {
    public private(set) var thermalLevel: ThermalLevel = .nominal
    private var cancellable: AnyCancellable?

    public init() {
        startMonitoring()
    }

    private func startMonitoring() {
        // Map ProcessInfo.ThermalState to our ThermalLevel
        thermalLevel = mapThermalState(ProcessInfo.processInfo.thermalState)

        cancellable = NotificationCenter.default
            .publisher(for: ProcessInfo.thermalStateDidChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.thermalLevel = self?.mapThermalState(ProcessInfo.processInfo.thermalState) ?? .nominal
            }
    }

    private func mapThermalState(_ state: ProcessInfo.ThermalState) -> ThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}
