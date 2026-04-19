import Foundation
import SharedTypes

// MARK: - Local Model Info

/// A model found on the local filesystem, not necessarily in the Teale catalog.
public struct LocalModelInfo: Identifiable, Sendable {
    public var id: String { path.path }
    public var path: URL
    public var name: String
    public var configJSON: ModelConfigJSON?
    public var sizeGB: Double
    public var source: ModelSource

    public enum ModelSource: String, Sendable {
        case huggingFaceCache      // ~/.cache/huggingface/hub/
        case lmStudio              // ~/.cache/lm-studio/models/
        case tealeCache            // ~/Library/Application Support/Teale/huggingface/
        case custom                // User-selected folder
    }

    /// Try to create a ModelDescriptor from the scanned info
    public func toDescriptor() -> ModelDescriptor {
        let paramCount = configJSON?.parameterCountString ?? "?"
        let quant = detectQuantization()
        // Try to resolve a canonical OpenRouter slug from the filename
        // so the gateway can match this local model against its catalog.
        // Falls back to nil (no advertisement under an OR id) for models
        // we don't recognize.
        let orId = ModelCatalog.openrouterIdForFilename(path.lastPathComponent)

        return ModelDescriptor(
            id: "local-\(path.lastPathComponent)",
            name: name,
            huggingFaceRepo: path.path,  // Use local path as repo identifier
            parameterCount: paramCount,
            quantization: quant,
            estimatedSizeGB: sizeGB,
            requiredRAMGB: sizeGB * 1.5,  // Rough estimate: model needs ~1.5x disk size in RAM
            family: configJSON?.modelType ?? "Unknown",
            description: "Local model from \(source.rawValue)",
            openrouterId: orId
        )
    }

    private func detectQuantization() -> QuantizationType {
        let pathStr = path.lastPathComponent.lowercased()
        if pathStr.contains("4bit") || pathStr.contains("q4") { return .q4 }
        if pathStr.contains("8bit") || pathStr.contains("q8") { return .q8 }
        return .fp16
    }
}

// MARK: - Model Config JSON (partial parse)

/// Minimal parsing of config.json to extract model metadata.
public struct ModelConfigJSON: Sendable {
    public var modelType: String?
    public var hiddenSize: Int?
    public var numHiddenLayers: Int?
    public var numParameters: Int?

    public var parameterCountString: String {
        guard let params = numParameters else {
            // Estimate from architecture if available
            if let hidden = hiddenSize, let layers = numHiddenLayers {
                let estimated = Double(hidden * hidden * layers * 4) / 1_000_000_000
                if estimated < 1 { return String(format: "%.0fM", estimated * 1000) }
                return String(format: "%.0fB", estimated)
            }
            return "?"
        }
        let billions = Double(params) / 1_000_000_000
        if billions < 1 { return String(format: "%.0fM", Double(params) / 1_000_000) }
        return String(format: "%.0fB", billions)
    }

    static func parse(from url: URL) -> ModelConfigJSON? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return ModelConfigJSON(
            modelType: json["model_type"] as? String,
            hiddenSize: json["hidden_size"] as? Int,
            numHiddenLayers: json["num_hidden_layers"] as? Int,
            numParameters: json["num_parameters"] as? Int
        )
    }
}

// MARK: - Local Model Scanner

/// Scans known locations on disk for MLX-compatible models (safetensors format).
public struct LocalModelScanner: Sendable {

    public init() {}

    /// Scan all known model directories and return found models.
    public func scanAll() -> [LocalModelInfo] {
        var results: [LocalModelInfo] = []
        for (searchDir, source) in knownDirectories() {
            results.append(contentsOf: scanDirectory(searchDir, source: source))
        }
        return results
    }

    /// Validate a specific directory as an MLX-compatible model.
    public func validateDirectory(_ url: URL) -> LocalModelInfo? {
        guard isMLXCompatible(url) else { return nil }
        return modelInfo(from: url, source: .custom)
    }

    // MARK: - Known Directories

    private func knownDirectories() -> [(URL, LocalModelInfo.ModelSource)] {
        var dirs: [(URL, LocalModelInfo.ModelSource)] = []
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #else
        let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        #endif
        let fm = FileManager.default

        // HuggingFace Hub cache
        let hfCache = home.appendingPathComponent(".cache/huggingface/hub")
        if fm.fileExists(atPath: hfCache.path) {
            dirs.append((hfCache, .huggingFaceCache))
        }

        // LM Studio
        let lmStudio = home.appendingPathComponent(".cache/lm-studio/models")
        if fm.fileExists(atPath: lmStudio.path) {
            dirs.append((lmStudio, .lmStudio))
        }

        // Teale's own HF cache
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tealeCache = appSupport.appendingPathComponent("Teale/huggingface/models")
        if fm.fileExists(atPath: tealeCache.path) {
            dirs.append((tealeCache, .tealeCache))
        }

        return dirs
    }

    // MARK: - Directory Scanning

    private func scanDirectory(_ baseDir: URL, source: LocalModelInfo.ModelSource) -> [LocalModelInfo] {
        var results: [LocalModelInfo] = []
        let fm = FileManager.default

        // For HuggingFace cache, models are in models--{org}--{name}/snapshots/{hash}/
        if source == .huggingFaceCache {
            let contents = (try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
            for dir in contents where dir.lastPathComponent.hasPrefix("models--") {
                let snapshots = dir.appendingPathComponent("snapshots")
                guard let snapshotDirs = try? fm.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
                for snapshot in snapshotDirs {
                    if isMLXCompatible(snapshot), let info = modelInfo(from: snapshot, source: source) {
                        results.append(info)
                    }
                }
            }
        } else {
            // For other sources, scan recursively up to 3 levels
            results.append(contentsOf: scanRecursive(baseDir, source: source, depth: 0, maxDepth: 3))
        }

        return results
    }

    private func scanRecursive(_ dir: URL, source: LocalModelInfo.ModelSource, depth: Int, maxDepth: Int) -> [LocalModelInfo] {
        guard depth <= maxDepth else { return [] }
        let fm = FileManager.default

        // Check if this directory itself is a model
        if isMLXCompatible(dir), let info = modelInfo(from: dir, source: source) {
            return [info]
        }

        // Otherwise recurse into subdirectories
        guard let contents = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }

        var results: [LocalModelInfo] = []
        for subdir in contents {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: subdir.path, isDirectory: &isDir)
            if isDir.boolValue {
                results.append(contentsOf: scanRecursive(subdir, source: source, depth: depth + 1, maxDepth: maxDepth))
            }
        }
        return results
    }

    // MARK: - Validation

    /// Check if a directory contains MLX-compatible model files.
    /// Requires: at least one .safetensors file AND a config.json.
    public func isMLXCompatible(_ dir: URL) -> Bool {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: dir.path) else { return false }
        let hasSafetensors = contents.contains { $0.hasSuffix(".safetensors") }
        let hasConfig = contents.contains { $0 == "config.json" }
        return hasSafetensors && hasConfig
    }

    // MARK: - Model Info Extraction

    private func modelInfo(from dir: URL, source: LocalModelInfo.ModelSource) -> LocalModelInfo? {
        let configURL = dir.appendingPathComponent("config.json")
        let config = ModelConfigJSON.parse(from: configURL)

        // Compute directory size
        let sizeGB = directorySizeGB(dir)

        // Derive name from path
        let name = deriveName(from: dir, source: source)

        return LocalModelInfo(
            path: dir,
            name: name,
            configJSON: config,
            sizeGB: sizeGB,
            source: source
        )
    }

    private func deriveName(from dir: URL, source: LocalModelInfo.ModelSource) -> String {
        switch source {
        case .huggingFaceCache:
            // Path: .../models--org--name/snapshots/hash/
            // Extract org/name from the parent's parent's name
            let modelsDir = dir.deletingLastPathComponent().deletingLastPathComponent()
            let dirName = modelsDir.lastPathComponent  // "models--org--name"
            let parts = dirName.replacingOccurrences(of: "models--", with: "").split(separator: "--")
            if parts.count >= 2 {
                return parts.joined(separator: "/")
            }
            return dirName
        default:
            return dir.lastPathComponent
        }
    }

    private func directorySizeGB(_ url: URL) -> Double {
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
        return Double(total) / (1024 * 1024 * 1024)
    }
}
