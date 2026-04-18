import Foundation

// MARK: - Peer Status

public enum PeerStatus: String, Codable, Sendable {
    case discovered       // seen via Bonjour, not yet connected
    case connecting       // handshake in progress
    case connected        // healthy
    case degraded         // missed heartbeats
    case disconnected     // gone
}

// MARK: - Connection Quality

public enum ConnectionQuality: String, Codable, Sendable {
    case thunderbolt      // ~40 Gbps direct Thunderbolt bridge
    case tenGigabit       // ≥10 GbE
    case gigabit          // ~1 Gbps wired ethernet
    case wifi             // variable, typically 100-1000 Mbps
    case unknown

    public var estimatedBandwidthMBs: Double {
        switch self {
        case .thunderbolt: return 5000    // ~40 Gbps
        case .tenGigabit: return 1250     // 10 Gbps
        case .gigabit: return 125         // 1 Gbps
        case .wifi: return 50             // conservative estimate
        case .unknown: return 10
        }
    }

    /// Whether this connection is fast enough for tensor parallelism
    public var supportsTensorParallelism: Bool {
        switch self {
        case .thunderbolt, .tenGigabit: return true
        default: return false
        }
    }
}

// MARK: - Cluster State

public struct ClusterState: Sendable {
    public var isEnabled: Bool
    public var peerCount: Int
    public var connectedPeerCount: Int
    public var totalClusterRAMGB: Double
    public var totalClusterBandwidthGBs: Double

    public init(
        isEnabled: Bool = false,
        peerCount: Int = 0,
        connectedPeerCount: Int = 0,
        totalClusterRAMGB: Double = 0,
        totalClusterBandwidthGBs: Double = 0
    ) {
        self.isEnabled = isEnabled
        self.peerCount = peerCount
        self.connectedPeerCount = connectedPeerCount
        self.totalClusterRAMGB = totalClusterRAMGB
        self.totalClusterBandwidthGBs = totalClusterBandwidthGBs
    }
}

// MARK: - Peer Model Source

/// Protocol for querying and transferring models from peers.
/// Allows ModelManager to request models without depending on ClusterKit.
public protocol PeerModelSource: AnyObject, Sendable {
    func queryModelAvailability(modelID: String) async -> [(peerID: UUID, available: Bool, sizeBytes: UInt64?)]
    func requestModelFromPeer(modelID: String, peerID: UUID) async throws
}

// MARK: - Peer Summary (lightweight info for UI without connection)

public struct PeerSummary: Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var hardware: HardwareCapability
    public var status: PeerStatus
    public var connectionQuality: ConnectionQuality
    public var engineStatus: EngineStatus
    public var loadedModel: String?
    public var lastSeen: Date

    public init(
        id: UUID,
        name: String,
        hardware: HardwareCapability,
        status: PeerStatus,
        connectionQuality: ConnectionQuality,
        engineStatus: EngineStatus = .idle,
        loadedModel: String? = nil,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.hardware = hardware
        self.status = status
        self.connectionQuality = connectionQuality
        self.engineStatus = engineStatus
        self.loadedModel = loadedModel
        self.lastSeen = lastSeen
    }
}
