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

@MainActor
@Observable
public final class ModelManagerService {
    public let catalog: ModelCatalog
    public let cache: ModelCache
    private let hardware: HardwareCapability

    public private(set) var downloadingModels: [String: Double] = [:]  // modelID -> progress
    public var peerModelSource: (any PeerModelSource)?

    public init(hardware: HardwareCapability, maxStorageGB: Double = 50.0) {
        self.catalog = ModelCatalog()
        self.cache = ModelCache(maxStorageGB: maxStorageGB)
        self.hardware = hardware
        // LAN model sharing resolves peer-supplied model ids through this
        // registry; ids outside the catalog resolve to nothing.
        ModelDirectoryRegistry.shared.register(ModelCatalog.allModels)
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
    ///
    /// - MLX models: HubApi snapshot (safetensors + json + tokenizer).
    /// - GGUF models: only the files named in `ggufFiles`, sha256-verified,
    ///   into `Teale/gguf/<model-id>`.
    /// - exo models: refused; exo downloads and shards them itself.
    /// Refuses downloads that would push Teale's model storage past
    /// `maxStorageGB`.
    public func downloadModel(_ descriptor: ModelDescriptor) async throws {
        if descriptor.servingBackend == .exo {
            throw ModelManagerError.managedByExo(descriptor.name)
        }
        guard await cache.canStore(descriptor) else {
            let used = await cache.totalSizeGB()
            let limit = await cache.maxStorageGB
            throw ModelManagerError.storageLimitExceeded(
                model: descriptor.name,
                neededGB: descriptor.estimatedSizeGB,
                usedGB: used,
                limitGB: limit
            )
        }

        downloadingModels[descriptor.id] = 0.0

        do {
            try await cache.ensureDirectory()

            switch descriptor.format {
            case .gguf:
                try await GGUFDownloader().download(descriptor) { [weak self] fraction in
                    Task { @MainActor in
                        self?.downloadingModels[descriptor.id] = fraction
                    }
                }
            case .mlx:
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
    case managedByExo(String)
    case storageLimitExceeded(model: String, neededGB: Double, usedGB: Double, limitGB: Double)

    public var errorDescription: String? {
        switch self {
        case .peerSourceNotAvailable:
            return "No peer model source configured"
        case .managedByExo(let name):
            return "\(name) is served by an exo cluster; exo downloads its shards itself."
        case .storageLimitExceeded(let model, let needed, let used, let limit):
            return String(
                format: "Downloading %@ needs ~%.0f GB but model storage is at %.0f of %.0f GB. Raise the storage limit or delete a model.",
                model, needed, used, limit
            )
        }
    }
}
