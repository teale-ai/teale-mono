import Foundation
import SharedTypes

// MARK: - Peer Health Monitor

/// Monitors peer health via heartbeats, marks degraded/disconnected
public actor PeerHealthMonitor {
    private let heartbeatInterval: TimeInterval = 5.0     // Send heartbeat every 5s
    private let degradedThreshold: TimeInterval = 15.0    // Mark degraded after 15s
    private let disconnectedThreshold: TimeInterval = 30.0 // Mark disconnected after 30s

    private var monitorTask: Task<Void, Never>?

    public var onPeerDegraded: ((UUID) -> Void)?
    public var onPeerDisconnected: ((UUID) -> Void)?

    public init() {}

    /// Start monitoring a set of peers (called periodically by ClusterManager)
    public func checkHealth(peers: [PeerInfo], now: Date = Date()) -> [(UUID, PeerStatus)] {
        var updates: [(UUID, PeerStatus)] = []

        for peer in peers where peer.status == .connected || peer.status == .degraded {
            let elapsed = now.timeIntervalSince(peer.lastHeartbeat)

            if elapsed > disconnectedThreshold && peer.status != .disconnected {
                updates.append((peer.id, .disconnected))
            } else if elapsed > degradedThreshold && peer.status == .connected {
                updates.append((peer.id, .degraded))
            }
        }

        return updates
    }

    /// Build a heartbeat payload from local state
    public func makeHeartbeat(
        deviceID: UUID,
        thermalLevel: ThermalLevel,
        throttleLevel: Int,
        loadedModels: [String],
        isGenerating: Bool,
        queueDepth: Int = 0
    ) -> HeartbeatPayload {
        HeartbeatPayload(
            deviceID: deviceID,
            timestamp: Date(),
            thermalLevel: thermalLevel,
            throttleLevel: throttleLevel,
            loadedModels: loadedModels,
            isGenerating: isGenerating,
            queueDepth: queueDepth
        )
    }
}
