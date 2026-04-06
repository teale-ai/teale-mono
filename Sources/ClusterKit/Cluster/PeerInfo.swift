import Foundation
import SharedTypes

// MARK: - Peer Info

/// Runtime state of a connected peer
public final class PeerInfo: Sendable, Identifiable {
    public let id: UUID
    public let deviceInfo: DeviceInfo
    public let connection: PeerConnection
    public let connectionQuality: ConnectionQuality

    // Mutable state accessed via ClusterManager actor
    public var status: PeerStatus
    public var lastHeartbeat: Date
    public var loadedModels: [String]
    public var isGenerating: Bool
    public var thermalLevel: ThermalLevel
    public var throttleLevel: Int  // 0-100
    public var activeRequestCount: Int
    public var organizationID: String?

    public init(
        deviceInfo: DeviceInfo,
        connection: PeerConnection,
        status: PeerStatus = .connected,
        connectionQuality: ConnectionQuality = .unknown,
        lastHeartbeat: Date = Date(),
        loadedModels: [String] = [],
        isGenerating: Bool = false,
        thermalLevel: ThermalLevel = .nominal,
        throttleLevel: Int = 100,
        activeRequestCount: Int = 0
    ) {
        self.id = deviceInfo.id
        self.deviceInfo = deviceInfo
        self.connection = connection
        self.connectionQuality = connectionQuality
        self.status = status
        self.lastHeartbeat = lastHeartbeat
        self.loadedModels = loadedModels
        self.isGenerating = isGenerating
        self.thermalLevel = thermalLevel
        self.throttleLevel = throttleLevel
        self.activeRequestCount = activeRequestCount
    }

    /// Capability score for routing decisions (higher = more capable)
    public var capabilityScore: Double {
        let ramScore = deviceInfo.hardware.totalRAMGB
        let bwScore = deviceInfo.hardware.memoryBandwidthGBs / 100.0
        let tierBonus: Double = {
            switch deviceInfo.hardware.tier {
            case .tier1: return 2.0
            case .tier2: return 1.0
            case .tier3: return 0.5
            case .tier4: return 0.2
            }
        }()
        return ramScore * bwScore * tierBonus
    }

    /// Convert to lightweight summary for UI
    public func toSummary() -> PeerSummary {
        PeerSummary(
            id: id,
            name: deviceInfo.name,
            hardware: deviceInfo.hardware,
            status: status,
            connectionQuality: connectionQuality,
            loadedModel: loadedModels.first,
            lastSeen: lastHeartbeat
        )
    }
}
