import Foundation
import SharedTypes

// MARK: - Model Cache

public actor ModelCache {
    private let baseDirectory: URL
    private let ggufDirectory: URL
    public private(set) var maxStorageGB: Double

    public init(maxStorageGB: Double = 50.0) {
        self.maxStorageGB = maxStorageGB
        self.baseDirectory = ModelCache.defaultCacheDirectory()
        self.ggufDirectory = ModelStorageLayout.ggufRootDirectory()
    }

    /// HubApi download base (`Teale/huggingface`). MLX snapshots live in
    /// `models/<org>/<name>` below it; GGUF files live under `Teale/gguf`.
    public static func defaultCacheDirectory() -> URL {
        ModelStorageLayout.huggingFaceBaseDirectory()
    }

    /// Ensure the cache directories exist
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ggufDirectory, withIntermediateDirectories: true)
    }

    /// Path for a specific model's cache: the HubApi layout (keyed by repo)
    /// for MLX snapshots, `Teale/gguf/<model-id>` for GGUF models.
    public func modelDirectory(for descriptor: ModelDescriptor) -> URL {
        ModelStorageLayout.modelDirectory(for: descriptor)
            ?? baseDirectory.appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("_invalid", isDirectory: true)
    }

    /// Check if a model is fully cached locally.
    /// - GGUF: the verification marker written after every requested file
    ///   downloaded (and matched its sha256 when the repo publishes one)
    ///   exists, and the primary GGUF file is present.
    /// - MLX: config.json plus at least one .safetensors file — a stray
    ///   .json alone is not a downloaded model.
    /// - exo: never "cached" here; exo manages its own shards.
    public func isModelCached(_ descriptor: ModelDescriptor) -> Bool {
        let fm = FileManager.default
        if descriptor.huggingFaceRepo.hasPrefix("/") {
            return fm.fileExists(atPath: descriptor.huggingFaceRepo)
        }
        switch (descriptor.servingBackend, descriptor.format) {
        case (.exo, _):
            return false
        case (_, .gguf):
            guard let dir = ModelStorageLayout.ggufModelDirectory(modelID: descriptor.id) else { return false }
            let marker = dir.appendingPathComponent(ModelStorageLayout.ggufVerifiedMarker)
            return fm.fileExists(atPath: marker.path)
                && ModelStorageLayout.localGGUFFile(for: descriptor) != nil
        case (_, .mlx):
            guard let dir = ModelStorageLayout.mlxModelDirectory(repo: descriptor.huggingFaceRepo),
                  fm.fileExists(atPath: dir.path) else { return false }
            let contents = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            guard contents.contains("config.json"), contents.contains(where: { $0.hasSuffix(".safetensors") }) else {
                return false
            }
            // Sharded checkpoints: every shard named in the index must be present.
            let index = dir.appendingPathComponent("model.safetensors.index.json")
            if let data = try? Data(contentsOf: index),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let weightMap = json["weight_map"] as? [String: String] {
                let present = Set(contents)
                return Set(weightMap.values).allSatisfy { present.contains($0) }
            }
            return true
        }
    }

    /// Repo ids (`org/name`) of the MLX snapshots in the HubApi cache plus
    /// the model ids of the GGUF models under `Teale/gguf`. (This used to
    /// list the top level of `Teale/huggingface`, which only ever returned
    /// "models".)
    public func cachedModelIDs() -> [String] {
        let fm = FileManager.default
        var ids: [String] = []

        let modelsDir = baseDirectory.appendingPathComponent("models", isDirectory: true)
        for org in subdirectories(of: modelsDir) {
            for repo in subdirectories(of: org) {
                ids.append("\(org.lastPathComponent)/\(repo.lastPathComponent)")
            }
        }

        for modelDir in subdirectories(of: ggufDirectory) {
            let marker = modelDir.appendingPathComponent(ModelStorageLayout.ggufVerifiedMarker)
            if fm.fileExists(atPath: marker.path) {
                ids.append(modelDir.lastPathComponent)
            }
        }
        return ids.sorted()
    }

    /// Total size of Teale-managed model storage (MLX snapshots + GGUF) in GB.
    public func totalSizeGB() -> Double {
        let modelsDir = baseDirectory.appendingPathComponent("models", isDirectory: true)
        let total = directorySize(modelsDir) + directorySize(ggufDirectory)
        return Double(total) / (1024 * 1024 * 1024)
    }

    /// Whether downloading `descriptor` keeps total storage within
    /// `maxStorageGB`. Already-cached models always pass.
    public func canStore(_ descriptor: ModelDescriptor) -> Bool {
        if isModelCached(descriptor) { return true }
        return totalSizeGB() + descriptor.estimatedSizeGB <= maxStorageGB
    }

    /// Delete a cached model
    public func deleteModel(_ descriptor: ModelDescriptor) throws {
        guard let dir = ModelStorageLayout.modelDirectory(for: descriptor),
              SafePathComponent.isContained(dir, in: ModelStorageLayout.tealeApplicationSupportDirectory()) else {
            return
        }
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Set max storage limit
    public func setMaxStorage(_ gb: Double) {
        maxStorageGB = gb
    }

    // MARK: - Private

    private func subdirectories(of url: URL) -> [URL] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )) ?? []
        return contents.filter { child in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: child.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    private func directorySize(_ url: URL) -> UInt64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }

        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
