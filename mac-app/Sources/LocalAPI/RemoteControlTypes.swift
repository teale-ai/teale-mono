import Foundation
import SharedTypes

public protocol LocalAppControlling: AnyObject {
    func remoteSnapshot() async -> RemoteAppSnapshot
    func remoteLoadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot
    func remoteDownloadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot
    func remoteUnloadModel() async -> RemoteAppSnapshot
    func remoteUpdateSettings(_ update: RemoteSettingsUpdate) async throws -> RemoteAppSnapshot
    func remoteListPTNs() async -> [RemotePTNSnapshot]
    func remoteCreatePTN(name: String) async throws -> RemotePTNSnapshot
    func remoteGeneratePTNInvite(ptnID: String) async throws -> String
    func remoteIssuePTNCert(ptnID: String, nodeID: String, role: String) async throws -> Data
    func remoteJoinPTNWithCert(certData: Data) async throws -> RemotePTNSnapshot
    func remoteLeavePTN(ptnID: String) async throws
    func remotePromoteAdmin(ptnID: String, targetNodeID: String) async throws -> Data
    func remoteImportCAKey(ptnID: String, caKeyHex: String) async throws -> RemotePTNSnapshot
    func remoteRecoverPTN(oldPTNID: String) async throws -> RemotePTNSnapshot
    func remoteListAPIKeys() async -> [RemoteAPIKeySnapshot]
    func remoteGenerateAPIKey(name: String) async -> RemoteAPIKeySnapshot
    func remoteRevokeAPIKey(id: UUID) async
    func remoteWalletBalance() async -> RemoteWalletSnapshot
    func remoteWalletTransactions(limit: Int) async -> [RemoteTransactionSnapshot]
    func remoteWalletSend(amount: Double, toPeer: String, memo: String?) async throws -> Bool
    func remoteSolanaStatus() async -> RemoteSolanaSnapshot
    func remoteListPeers() async -> RemotePeersSnapshot
    func remoteAgentProfile() async -> RemoteAgentProfileSnapshot?
    func remoteAgentDirectory() async -> [RemoteAgentDirectoryEntry]
    func remoteAgentConversations() async -> [RemoteAgentConversationSnapshot]
}

public struct RemotePTNSnapshot: Codable, Sendable {
    public var ptnID: String
    public var ptnName: String
    public var role: String
    public var isCreator: Bool
    public var memberCount: Int

    public init(ptnID: String, ptnName: String, role: String, isCreator: Bool, memberCount: Int = 1) {
        self.ptnID = ptnID
        self.ptnName = ptnName
        self.role = role
        self.isCreator = isCreator
        self.memberCount = memberCount
    }
}

public struct RemoteAppSnapshot: Codable, Sendable {
    public var appVersion: String
    public var loadedModelID: String?
    public var loadedModelRepo: String?
    public var engineStatus: String
    public var isServerRunning: Bool
    public var auth: RemoteAuthConfigSnapshot?
    public var demand: RemoteDemandSnapshot?
    public var settings: RemoteSettingsSnapshot
    public var models: [RemoteModelSnapshot]

    public init(
        appVersion: String,
        loadedModelID: String?,
        loadedModelRepo: String?,
        engineStatus: String,
        isServerRunning: Bool,
        auth: RemoteAuthConfigSnapshot? = nil,
        demand: RemoteDemandSnapshot? = nil,
        settings: RemoteSettingsSnapshot,
        models: [RemoteModelSnapshot]
    ) {
        self.appVersion = appVersion
        self.loadedModelID = loadedModelID
        self.loadedModelRepo = loadedModelRepo
        self.engineStatus = engineStatus
        self.isServerRunning = isServerRunning
        self.auth = auth
        self.demand = demand
        self.settings = settings
        self.models = models
    }
}

public struct RemoteAuthConfigSnapshot: Codable, Sendable {
    public var configured: Bool
    public var supabaseURL: String?
    public var supabaseAnonKey: String?
    public var redirectURL: String?

    enum CodingKeys: String, CodingKey {
        case configured
        case supabaseURL = "supabase_url"
        case supabaseAnonKey = "supabase_anon_key"
        case redirectURL = "redirect_url"
    }

    public init(
        configured: Bool,
        supabaseURL: String?,
        supabaseAnonKey: String?,
        redirectURL: String?
    ) {
        self.configured = configured
        self.supabaseURL = supabaseURL
        self.supabaseAnonKey = supabaseAnonKey
        self.redirectURL = redirectURL
    }
}

public struct RemoteDemandSnapshot: Codable, Sendable {
    public var localBaseURL: String
    public var localModelID: String?
    public var networkBaseURL: String
    public var networkBearerToken: String?

    enum CodingKeys: String, CodingKey {
        case localBaseURL = "local_base_url"
        case localModelID = "local_model_id"
        case networkBaseURL = "network_base_url"
        case networkBearerToken = "network_bearer_token"
    }

    public init(
        localBaseURL: String,
        localModelID: String?,
        networkBaseURL: String,
        networkBearerToken: String?
    ) {
        self.localBaseURL = localBaseURL
        self.localModelID = localModelID
        self.networkBaseURL = networkBaseURL
        self.networkBearerToken = networkBearerToken
    }
}

public struct RemoteSettingsSnapshot: Codable, Sendable {
    public var clusterEnabled: Bool
    public var wanEnabled: Bool
    public var wanRelayURL: String
    public var wanBusy: Bool
    public var wanLastError: String?
    public var wanRelayStatus: String?
    public var wanDiscoveredPeerCount: Int?
    public var maxStorageGB: Double
    public var orgCapacityReservation: Double
    public var clusterPasscodeSet: Bool
    public var allowNetworkAccess: Bool
    public var electricityCostPerKWh: Double
    public var electricityCurrency: String
    public var electricityMarginMultiplier: Double
    public var keepAwake: Bool
    public var autoManageModels: Bool
    public var inferenceBackend: String
    public var privacyFilterMode: String
    public var privacyFilterStatus: String
    public var privacyFilterDetail: String?
    public var language: String

    public init(
        clusterEnabled: Bool,
        wanEnabled: Bool,
        wanRelayURL: String,
        wanBusy: Bool = false,
        wanLastError: String? = nil,
        wanRelayStatus: String? = nil,
        wanDiscoveredPeerCount: Int? = nil,
        maxStorageGB: Double,
        orgCapacityReservation: Double,
        clusterPasscodeSet: Bool,
        allowNetworkAccess: Bool,
        electricityCostPerKWh: Double = 0.12,
        electricityCurrency: String = "USD",
        electricityMarginMultiplier: Double = 1.2,
        keepAwake: Bool = false,
        autoManageModels: Bool = false,
        inferenceBackend: String = "local_mlx",
        privacyFilterMode: String = "off",
        privacyFilterStatus: String = "disabled",
        privacyFilterDetail: String? = nil,
        language: String = "en"
    ) {
        self.clusterEnabled = clusterEnabled
        self.wanEnabled = wanEnabled
        self.wanRelayURL = wanRelayURL
        self.wanBusy = wanBusy
        self.wanLastError = wanLastError
        self.wanRelayStatus = wanRelayStatus
        self.wanDiscoveredPeerCount = wanDiscoveredPeerCount
        self.maxStorageGB = maxStorageGB
        self.orgCapacityReservation = orgCapacityReservation
        self.clusterPasscodeSet = clusterPasscodeSet
        self.allowNetworkAccess = allowNetworkAccess
        self.electricityCostPerKWh = electricityCostPerKWh
        self.electricityCurrency = electricityCurrency
        self.electricityMarginMultiplier = electricityMarginMultiplier
        self.keepAwake = keepAwake
        self.autoManageModels = autoManageModels
        self.inferenceBackend = inferenceBackend
        self.privacyFilterMode = privacyFilterMode
        self.privacyFilterStatus = privacyFilterStatus
        self.privacyFilterDetail = privacyFilterDetail
        self.language = language
    }
}

public struct RemoteModelSnapshot: Codable, Sendable {
    public var id: String
    public var name: String
    public var huggingFaceRepo: String
    public var downloaded: Bool
    public var loaded: Bool
    public var downloadingProgress: Double?

    public init(
        id: String,
        name: String,
        huggingFaceRepo: String,
        downloaded: Bool,
        loaded: Bool,
        downloadingProgress: Double?
    ) {
        self.id = id
        self.name = name
        self.huggingFaceRepo = huggingFaceRepo
        self.downloaded = downloaded
        self.loaded = loaded
        self.downloadingProgress = downloadingProgress
    }
}

public struct RemoteModelControlRequest: Codable, Sendable {
    public var model: String
    public var downloadIfNeeded: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case downloadIfNeeded = "download_if_needed"
    }

    public init(model: String, downloadIfNeeded: Bool? = nil) {
        self.model = model
        self.downloadIfNeeded = downloadIfNeeded
    }
}

public struct RemoteSettingsUpdate: Codable, Sendable {
    public var clusterEnabled: Bool?
    public var wanEnabled: Bool?
    public var wanRelayURL: String?
    public var maxStorageGB: Double?
    public var orgCapacityReservation: Double?
    public var clusterPasscode: String?
    public var allowNetworkAccess: Bool?
    public var electricityCostPerKWh: Double?
    public var electricityCurrency: String?
    public var electricityMarginMultiplier: Double?
    public var keepAwake: Bool?
    public var autoManageModels: Bool?
    public var inferenceBackend: String?
    public var privacyFilterMode: String?
    public var language: String?

    enum CodingKeys: String, CodingKey {
        case clusterEnabled = "cluster_enabled"
        case wanEnabled = "wan_enabled"
        case wanRelayURL = "wan_relay_url"
        case maxStorageGB = "max_storage_gb"
        case orgCapacityReservation = "org_capacity_reservation"
        case clusterPasscode = "cluster_passcode"
        case allowNetworkAccess = "allow_network_access"
        case electricityCostPerKWh = "electricity_cost"
        case electricityCurrency = "electricity_currency"
        case electricityMarginMultiplier = "electricity_margin"
        case keepAwake = "keep_awake"
        case autoManageModels = "auto_manage_models"
        case inferenceBackend = "inference_backend"
        case privacyFilterMode = "privacy_filter_mode"
        case language
    }

    public init(
        clusterEnabled: Bool? = nil,
        wanEnabled: Bool? = nil,
        wanRelayURL: String? = nil,
        maxStorageGB: Double? = nil,
        orgCapacityReservation: Double? = nil,
        clusterPasscode: String? = nil,
        allowNetworkAccess: Bool? = nil,
        electricityCostPerKWh: Double? = nil,
        electricityCurrency: String? = nil,
        electricityMarginMultiplier: Double? = nil,
        keepAwake: Bool? = nil,
        autoManageModels: Bool? = nil,
        inferenceBackend: String? = nil,
        privacyFilterMode: String? = nil,
        language: String? = nil
    ) {
        self.clusterEnabled = clusterEnabled
        self.wanEnabled = wanEnabled
        self.wanRelayURL = wanRelayURL
        self.maxStorageGB = maxStorageGB
        self.orgCapacityReservation = orgCapacityReservation
        self.clusterPasscode = clusterPasscode
        self.allowNetworkAccess = allowNetworkAccess
        self.electricityCostPerKWh = electricityCostPerKWh
        self.electricityCurrency = electricityCurrency
        self.electricityMarginMultiplier = electricityMarginMultiplier
        self.keepAwake = keepAwake
        self.autoManageModels = autoManageModels
        self.inferenceBackend = inferenceBackend
        self.privacyFilterMode = privacyFilterMode
        self.language = language
    }
}

// MARK: - Wallet Types

public struct RemoteWalletSnapshot: Codable, Sendable {
    public var deviceID: String
    public var balance: Double
    public var totalEarned: Double
    public var totalSpent: Double
    public var wanNodeID: String?
    public var relayConnected: Bool?
    public var localServingReady: Bool?
    public var identityMismatch: Bool?
    public var earningEligible: Bool?
    public var error: String?

    public init(
        deviceID: String,
        balance: Double,
        totalEarned: Double,
        totalSpent: Double,
        wanNodeID: String? = nil,
        relayConnected: Bool? = nil,
        localServingReady: Bool? = nil,
        identityMismatch: Bool? = nil,
        earningEligible: Bool? = nil,
        error: String? = nil
    ) {
        self.deviceID = deviceID
        self.balance = balance
        self.totalEarned = totalEarned
        self.totalSpent = totalSpent
        self.wanNodeID = wanNodeID
        self.relayConnected = relayConnected
        self.localServingReady = localServingReady
        self.identityMismatch = identityMismatch
        self.earningEligible = earningEligible
        self.error = error
    }
}

public struct RemoteTransactionSnapshot: Codable, Sendable {
    public var id: UUID
    public var type: String
    public var amount: Double
    public var description: String
    public var peerNodeID: String?
    public var timestamp: Date

    public init(id: UUID, type: String, amount: Double, description: String, peerNodeID: String? = nil, timestamp: Date) {
        self.id = id
        self.type = type
        self.amount = amount
        self.description = description
        self.peerNodeID = peerNodeID
        self.timestamp = timestamp
    }
}

public struct RemoteSolanaSnapshot: Codable, Sendable {
    public var enabled: Bool
    public var address: String
    public var usdcBalance: String
    public var network: String

    public init(enabled: Bool, address: String = "", usdcBalance: String = "0", network: String = "mainnet") {
        self.enabled = enabled
        self.address = address
        self.usdcBalance = usdcBalance
        self.network = network
    }
}

// MARK: - Peer Types

public struct RemotePeersSnapshot: Codable, Sendable {
    public var wanPeers: [RemotePeerSnapshot]
    public var wanDiscoveredPeers: [RemotePeerSnapshot]
    public var clusterPeers: [RemotePeerSnapshot]

    public init(
        wanPeers: [RemotePeerSnapshot] = [],
        wanDiscoveredPeers: [RemotePeerSnapshot] = [],
        clusterPeers: [RemotePeerSnapshot] = []
    ) {
        self.wanPeers = wanPeers
        self.wanDiscoveredPeers = wanDiscoveredPeers
        self.clusterPeers = clusterPeers
    }
}

public struct RemotePeerSnapshot: Codable, Sendable {
    public var nodeID: String
    public var displayName: String
    public var loadedModels: [String]
    public var source: String

    public init(nodeID: String, displayName: String, loadedModels: [String] = [], source: String) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.loadedModels = loadedModels
        self.source = source
    }
}

// MARK: - Agent Types

public struct RemoteAgentProfileSnapshot: Codable, Sendable {
    public var nodeID: String
    public var displayName: String
    public var agentType: String
    public var bio: String
    public var capabilities: [String]

    public init(nodeID: String, displayName: String, agentType: String, bio: String, capabilities: [String]) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.agentType = agentType
        self.bio = bio
        self.capabilities = capabilities
    }
}

public struct RemoteAgentDirectoryEntry: Codable, Sendable {
    public var nodeID: String
    public var displayName: String
    public var agentType: String
    public var bio: String
    public var capabilities: [String]
    public var isOnline: Bool
    public var rating: Double?

    public init(nodeID: String, displayName: String, agentType: String, bio: String, capabilities: [String], isOnline: Bool, rating: Double? = nil) {
        self.nodeID = nodeID
        self.displayName = displayName
        self.agentType = agentType
        self.bio = bio
        self.capabilities = capabilities
        self.isOnline = isOnline
        self.rating = rating
    }
}

public struct RemoteAgentConversationSnapshot: Codable, Sendable {
    public var id: UUID
    public var participants: [String]
    public var state: String
    public var messageCount: Int
    public var lastMessage: String?
    public var updatedAt: Date

    public init(id: UUID, participants: [String], state: String, messageCount: Int, lastMessage: String? = nil, updatedAt: Date) {
        self.id = id
        self.participants = participants
        self.state = state
        self.messageCount = messageCount
        self.lastMessage = lastMessage
        self.updatedAt = updatedAt
    }
}

// MARK: - API Key Types

public struct RemoteAPIKeySnapshot: Codable, Sendable {
    public var id: UUID
    public var key: String
    public var name: String
    public var createdAt: Date
    public var lastUsedAt: Date?
    public var isActive: Bool

    public init(id: UUID, key: String, name: String, createdAt: Date, lastUsedAt: Date? = nil, isActive: Bool) {
        self.id = id
        self.key = key
        self.name = name
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.isActive = isActive
    }
}

public enum RemoteControlError: LocalizedError, Sendable {
    case unsupported
    case modelNotFound(String)
    case modelNotDownloaded(String)
    case invalidSetting(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Remote control is not enabled for this app instance"
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .modelNotDownloaded(let model):
            return "Model is not downloaded: \(model)"
        case .invalidSetting(let message):
            return message
        }
    }
}
