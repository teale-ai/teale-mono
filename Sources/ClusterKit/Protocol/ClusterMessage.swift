import Foundation
import SharedTypes

// MARK: - Cluster Message

public enum ClusterMessage: Codable, Sendable {
    // Handshake
    case hello(HelloPayload)
    case helloAck(HelloPayload)

    // Health
    case heartbeat(HeartbeatPayload)
    case heartbeatAck(HeartbeatPayload)

    // Inference
    case inferenceRequest(InferenceRequestPayload)
    case inferenceChunk(InferenceChunkPayload)
    case inferenceComplete(InferenceCompletePayload)
    case inferenceError(InferenceErrorPayload)

    // Model sharing
    case modelQuery(ModelQueryPayload)
    case modelQueryResponse(ModelQueryResponsePayload)
    case modelTransferRequest(ModelTransferRequestPayload)
    case modelTransferChunk(ModelTransferChunkPayload)
    case modelTransferComplete(ModelTransferCompletePayload)

    // Agent protocol
    case agentMessage(AgentTransportPayload)

    // USDC transfer
    case usdcTransferRequest(USDCTransferPayload)
    case usdcTransferConfirm(USDCTransferConfirmPayload)

    // Group E2E encrypted chat
    case groupKeyExchange(GroupKeyExchangeTransportPayload)
    case groupMessage(GroupMessageTransportPayload)
    case groupSyncRequest(GroupSyncRequestTransportPayload)
    case groupSyncResponse(GroupSyncResponseTransportPayload)
    case groupConfigUpdate(GroupConfigUpdateTransportPayload)
}

// MARK: - Group Key Exchange Payload (transport wrapper)

public struct GroupKeyExchangeTransportPayload: Codable, Sendable {
    public var data: Data
    public var senderNodeID: String

    public init(data: Data, senderNodeID: String) {
        self.data = data
        self.senderNodeID = senderNodeID
    }
}

/// P2P group chat message (encrypted payload).
public struct GroupMessageTransportPayload: Codable, Sendable {
    public var data: Data // JSON-encoded StoredMessage
    public init(data: Data) { self.data = data }
}

/// Sync request: peer sends their vector clock to catch up.
public struct GroupSyncRequestTransportPayload: Codable, Sendable {
    public var data: Data // JSON-encoded GroupSyncRequestPayload
    public init(data: Data) { self.data = data }
}

/// Sync response: batch of missed messages.
public struct GroupSyncResponseTransportPayload: Codable, Sendable {
    public var data: Data // JSON-encoded GroupSyncResponsePayload
    public init(data: Data) { self.data = data }
}

/// Group config update (admin-signed MD files).
public struct GroupConfigUpdateTransportPayload: Codable, Sendable {
    public var data: Data // JSON-encoded GroupConfigUpdatePayload
    public init(data: Data) { self.data = data }
}

// MARK: - Agent Transport Payload

public struct AgentTransportPayload: Codable, Sendable {
    public var data: Data

    public init(data: Data) {
        self.data = data
    }
}

// MARK: - Handshake Payloads

public struct HelloPayload: Codable, Sendable {
    public var deviceInfo: DeviceInfo
    public var protocolVersion: Int
    public var clusterPasscodeHash: String?
    public var loadedModels: [String]
    public var ownerUserID: UUID?

    public init(
        deviceInfo: DeviceInfo,
        protocolVersion: Int = 1,
        clusterPasscodeHash: String? = nil,
        loadedModels: [String] = [],
        ownerUserID: UUID? = nil
    ) {
        self.deviceInfo = deviceInfo
        self.protocolVersion = protocolVersion
        self.clusterPasscodeHash = clusterPasscodeHash
        self.loadedModels = loadedModels
        self.ownerUserID = ownerUserID
    }
}

// MARK: - Health Payloads

public struct HeartbeatPayload: Codable, Sendable {
    public var deviceID: UUID
    public var timestamp: Date
    public var thermalLevel: ThermalLevel
    public var throttleLevel: Int  // 0-100
    public var loadedModels: [String]
    public var isGenerating: Bool
    public var queueDepth: Int
    public var organizationID: String?  // Optional for backward compat
    public var ownerUserID: UUID?

    public init(
        deviceID: UUID,
        timestamp: Date = Date(),
        thermalLevel: ThermalLevel = .nominal,
        throttleLevel: Int = 100,
        loadedModels: [String] = [],
        isGenerating: Bool = false,
        queueDepth: Int = 0,
        organizationID: String? = nil,
        ownerUserID: UUID? = nil
    ) {
        self.deviceID = deviceID
        self.timestamp = timestamp
        self.thermalLevel = thermalLevel
        self.throttleLevel = throttleLevel
        self.loadedModels = loadedModels
        self.isGenerating = isGenerating
        self.queueDepth = queueDepth
        self.organizationID = organizationID
        self.ownerUserID = ownerUserID
    }
}

// MARK: - Inference Payloads

public struct InferenceRequestPayload: Codable, Sendable {
    public var requestID: UUID
    public var request: ChatCompletionRequest
    public var streaming: Bool

    public init(requestID: UUID = UUID(), request: ChatCompletionRequest, streaming: Bool = true) {
        self.requestID = requestID
        self.request = request
        self.streaming = streaming
    }
}

public struct InferenceChunkPayload: Codable, Sendable {
    public var requestID: UUID
    public var chunk: ChatCompletionChunk

    public init(requestID: UUID, chunk: ChatCompletionChunk) {
        self.requestID = requestID
        self.chunk = chunk
    }
}

public struct InferenceCompletePayload: Codable, Sendable {
    public var requestID: UUID

    public init(requestID: UUID) {
        self.requestID = requestID
    }
}

public struct InferenceErrorPayload: Codable, Sendable {
    public var requestID: UUID
    public var errorMessage: String

    public init(requestID: UUID, errorMessage: String) {
        self.requestID = requestID
        self.errorMessage = errorMessage
    }
}

// MARK: - Model Sharing Payloads

public struct ModelQueryPayload: Codable, Sendable {
    public var modelID: String

    public init(modelID: String) {
        self.modelID = modelID
    }
}

public struct ModelQueryResponsePayload: Codable, Sendable {
    public var modelID: String
    public var available: Bool
    public var totalSizeBytes: UInt64?

    public init(modelID: String, available: Bool, totalSizeBytes: UInt64? = nil) {
        self.modelID = modelID
        self.available = available
        self.totalSizeBytes = totalSizeBytes
    }
}

public struct ModelTransferRequestPayload: Codable, Sendable {
    public var transferID: UUID
    public var modelID: String

    public init(transferID: UUID = UUID(), modelID: String) {
        self.transferID = transferID
        self.modelID = modelID
    }
}

public struct ModelTransferChunkPayload: Codable, Sendable {
    public var transferID: UUID
    public var fileName: String
    public var offset: UInt64
    public var data: Data
    public var isLastChunk: Bool

    public init(transferID: UUID, fileName: String, offset: UInt64, data: Data, isLastChunk: Bool) {
        self.transferID = transferID
        self.fileName = fileName
        self.offset = offset
        self.data = data
        self.isLastChunk = isLastChunk
    }
}

public struct ModelTransferCompletePayload: Codable, Sendable {
    public var transferID: UUID
    public var modelID: String

    public init(transferID: UUID, modelID: String) {
        self.transferID = transferID
        self.modelID = modelID
    }
}

// MARK: - USDC Transfer Payloads

public struct USDCTransferPayload: Codable, Sendable {
    public var transferID: UUID
    public var senderNodeID: String
    public var senderDeviceName: String?
    public var amount: Double
    public var memo: String?
    public var modelID: String?
    public var tokenCount: Int?

    public init(
        transferID: UUID = UUID(),
        senderNodeID: String,
        senderDeviceName: String? = nil,
        amount: Double,
        memo: String? = nil,
        modelID: String? = nil,
        tokenCount: Int? = nil
    ) {
        self.transferID = transferID
        self.senderNodeID = senderNodeID
        self.senderDeviceName = senderDeviceName
        self.amount = amount
        self.memo = memo
        self.modelID = modelID
        self.tokenCount = tokenCount
    }
}

public struct USDCTransferConfirmPayload: Codable, Sendable {
    public var transferID: UUID
    public var receiverNodeID: String
    public var accepted: Bool

    public init(transferID: UUID, receiverNodeID: String, accepted: Bool = true) {
        self.transferID = transferID
        self.receiverNodeID = receiverNodeID
        self.accepted = accepted
    }
}
