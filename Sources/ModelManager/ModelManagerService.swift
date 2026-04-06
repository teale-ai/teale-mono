import Foundation
import SharedTypes
import HardwareProfile
import MLXLMCommon
import MLXLLM
import MLXInference

// MARK: - Download Progress

public enum DownloadProgress: Sendable {
    case downloading(fraction: Double)
    case completed
    case failed(String)
}

// MARK: - Model Manager Service

@Observable
public final class ModelManagerService: @unchecked Sendable {
    public let catalog: ModelCatalog
    public let cache: ModelCache
    private let hardware: HardwareCapability

    public private(set) var downloadingModels: [String: Double] = [:]  // modelID -> progress
    public var peerModelSource: (any PeerModelSource)?

    public init(hardware: HardwareCapability, maxStorageGB: Double = 50.0) {
        self.catalog = ModelCatalog()
        self.cache = ModelCache(maxStorageGB: maxStorageGB)
        self.hardware = hardware
    }

    /// Models that can run on this hardware
    public var compatibleModels: [ModelDescriptor] {
        catalog.availableModels(for: hardware)
    }

    /// Check if a model is downloaded
    public func isDownloaded(_ model: ModelDescriptor) async -> Bool {
        await cache.isModelCached(model)
    }

    /// Download model files only (no loading into memory)
    public func downloadModel(_ descriptor: ModelDescriptor) async throws {
        downloadingModels[descriptor.id] = 0.0

        do {
            try await cache.ensureDirectory()

            let downloader = HFDownloader()
            let patterns = ["*.safetensors", "*.json", "tokenizer.*", "*.model"]
            _ = try await downloader.download(
                id: descriptor.huggingFaceRepo,
                revision: nil,
                matching: patterns,
                useLatest: false
            ) { [weak self] progress in
                Task { @MainActor in
                    self?.downloadingModels[descriptor.id] = progress.fractionCompleted
                }
            }

            downloadingModels.removeValue(forKey: descriptor.id)
        } catch {
            downloadingModels.removeValue(forKey: descriptor.id)
            throw error
        }
    }

    /// Delete a model from cache
    public func deleteModel(_ descriptor: ModelDescriptor) async throws {
        try await cache.deleteModel(descriptor)
    }

    /// Current cache size
    public func cacheSizeGB() async -> Double {
        await cache.totalSizeGB()
    }

    /// Download a model from a peer in the cluster
    public func downloadModelFromPeer(_ descriptor: ModelDescriptor, peerID: UUID) async throws {
        guard let source = peerModelSource else {
            throw ModelManagerError.peerSourceNotAvailable
        }
        downloadingModels[descriptor.id] = 0.0
        do {
            try await source.requestModelFromPeer(modelID: descriptor.id, peerID: peerID)
            downloadingModels.removeValue(forKey: descriptor.id)
        } catch {
            downloadingModels.removeValue(forKey: descriptor.id)
            throw error
        }
    }

    /// Query peers for model availability
    public func queryPeersForModel(_ descriptor: ModelDescriptor) async -> [(peerID: UUID, available: Bool, sizeBytes: UInt64?)] {
        guard let source = peerModelSource else { return [] }
        return await source.queryModelAvailability(modelID: descriptor.id)
    }
}

public enum ModelManagerError: LocalizedError, Sendable {
    case peerSourceNotAvailable

    public var errorDescription: String? {
        switch self {
        case .peerSourceNotAvailable: return "No peer model source configured"
        }
    }
}
