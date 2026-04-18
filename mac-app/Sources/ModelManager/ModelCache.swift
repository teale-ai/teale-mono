import Foundation
import SharedTypes

// MARK: - Model Cache

public actor ModelCache {
    private let baseDirectory: URL
    public private(set) var maxStorageGB: Double

    public init(maxStorageGB: Double = 50.0) {
        self.maxStorageGB = maxStorageGB
        self.baseDirectory = ModelCache.defaultCacheDirectory()
    }

    public static func defaultCacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale/huggingface", isDirectory: true)
    }

    /// Ensure the cache directory exists
    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
    }

    /// Get path for a specific model's cache (matches HuggingFace Hub's storage layout)
    public func modelDirectory(for descriptor: ModelDescriptor) -> URL {
        baseDirectory.appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(descriptor.huggingFaceRepo, isDirectory: true)
    }

    /// Check if a model is cached locally
    public func isModelCached(_ descriptor: ModelDescriptor) -> Bool {
        let dir = modelDirectory(for: descriptor)
        // Check that the directory exists and has actual model files (not just an empty dir)
        guard FileManager.default.fileExists(atPath: dir.path) else { return false }
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return contents.contains { $0.hasSuffix(".safetensors") || $0.hasSuffix(".json") }
    }

    /// List all cached model IDs
    public func cachedModelIDs() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return []
        }
        return contents.compactMap { url in
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
            return isDir.boolValue ? url.lastPathComponent : nil
        }
    }

    /// Total size of cache in GB
    public func totalSizeGB() -> Double {
        let modelsDir = baseDirectory.appendingPathComponent("models", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: .skipsHiddenFiles
        ) else {
            return 0
        }

        var total: UInt64 = 0
        for url in contents {
            total += directorySize(url)
        }
        return Double(total) / (1024 * 1024 * 1024)
    }

    /// Delete a cached model
    public func deleteModel(_ descriptor: ModelDescriptor) throws {
        let dir = modelDirectory(for: descriptor)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
    }

    /// Set max storage limit
    public func setMaxStorage(_ gb: Double) {
        maxStorageGB = gb
    }

    // MARK: - Private

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
