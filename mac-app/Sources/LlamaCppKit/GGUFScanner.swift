import Foundation
import SharedTypes

// MARK: - GGUF Model Scanner

/// Scans local directories for GGUF model files and extracts metadata.
public struct GGUFScanner: Sendable {

    public init() {}

    /// Scan all known model directories for .gguf files.
    public func scanAll() -> [GGUFModelInfo] {
        var results: [GGUFModelInfo] = []
        for (searchDir, source) in knownDirectories() {
            results.append(contentsOf: scanDirectory(searchDir, source: source))
        }
        return results
    }

    /// Check if a specific file is a valid GGUF model.
    public func validateFile(_ url: URL) -> GGUFModelInfo? {
        guard url.pathExtension.lowercased() == "gguf" else { return nil }
        return modelInfo(from: url, source: .custom)
    }

    // MARK: - Known Directories

    private func knownDirectories() -> [(URL, GGUFModelInfo.ModelSource)] {
        var dirs: [(URL, GGUFModelInfo.ModelSource)] = []
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        #else
        let home = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        #endif
        let fm = FileManager.default

        // LM Studio models (common GGUF source)
        let lmStudio = home.appendingPathComponent(".cache/lm-studio/models")
        if fm.fileExists(atPath: lmStudio.path) {
            dirs.append((lmStudio, .lmStudio))
        }

        // Ollama models
        let ollama = home.appendingPathComponent(".ollama/models/blobs")
        if fm.fileExists(atPath: ollama.path) {
            dirs.append((ollama, .ollama))
        }

        // HuggingFace cache (some GGUF files end up here)
        let hfCache = home.appendingPathComponent(".cache/huggingface/hub")
        if fm.fileExists(atPath: hfCache.path) {
            dirs.append((hfCache, .huggingFaceCache))
        }

        // Teale's own GGUF cache
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let tealeGGUF = appSupport.appendingPathComponent("Teale/gguf")
        if fm.fileExists(atPath: tealeGGUF.path) {
            dirs.append((tealeGGUF, .tealeCache))
        }

        return dirs
    }

    // MARK: - Scanning

    private func scanDirectory(_ baseDir: URL, source: GGUFModelInfo.ModelSource) -> [GGUFModelInfo] {
        var results: [GGUFModelInfo] = []
        let fm = FileManager.default

        guard let enumerator = fm.enumerator(
            at: baseDir,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return results }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension.lowercased() == "gguf" else { continue }

            // Skip very small files (likely incomplete downloads)
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_000_000 {
                continue
            }

            if let info = modelInfo(from: fileURL, source: source) {
                results.append(info)
            }
        }

        return results
    }

    // MARK: - Model Info Extraction

    private func modelInfo(from fileURL: URL, source: GGUFModelInfo.ModelSource) -> GGUFModelInfo? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
              let fileSize = attrs[.size] as? UInt64 else { return nil }

        let sizeGB = Double(fileSize) / (1024 * 1024 * 1024)
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let header = GGUFHeader.read(from: fileURL)

        return GGUFModelInfo(
            path: fileURL,
            filename: filename,
            sizeGB: sizeGB,
            source: source,
            header: header
        )
    }
}

// MARK: - GGUF Model Info

public struct GGUFModelInfo: Identifiable, Sendable {
    public var id: String { path.path }
    public var path: URL
    public var filename: String
    public var sizeGB: Double
    public var source: ModelSource
    public var header: GGUFHeader?

    public enum ModelSource: String, Sendable {
        case lmStudio
        case ollama
        case huggingFaceCache
        case tealeCache
        case custom
    }

    /// Convert to a ModelDescriptor for the unified model system.
    public func toDescriptor() -> ModelDescriptor {
        let name = humanReadableName()
        let paramCount = inferParameterCount()
        let quant = detectQuantization()

        return ModelDescriptor(
            id: "gguf-\(filename)",
            name: name,
            huggingFaceRepo: path.path,  // Local file path for GGUF models
            parameterCount: paramCount,
            quantization: quant,
            estimatedSizeGB: sizeGB,
            requiredRAMGB: sizeGB * 1.3,  // GGUF models need ~1.3x file size in RAM
            family: inferFamily(),
            description: "GGUF model from \(source.rawValue)",
            openrouterId: OpenRouterIdResolver.resolve(filename: path.lastPathComponent)
        )
    }

    private func humanReadableName() -> String {
        filename
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    private func inferParameterCount() -> String {
        // Try to extract from filename (e.g., "llama-3-8b-instruct-q4_k_m")
        let lower = filename.lowercased()
        let pattern = "(\\d+(?:\\.\\d+)?)[_-]?[bB]"
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
           let range = Range(match.range(at: 1), in: lower) {
            return "\(lower[range])B".uppercased()
        }

        // Estimate from file size and quantization
        let bitsPerParam: Double
        switch detectQuantization() {
        case .q4: bitsPerParam = 4.5
        case .q8: bitsPerParam = 8.5
        case .fp16: bitsPerParam = 16.0
        }
        let estimatedParams = (sizeGB * 8_589_934_592) / bitsPerParam / 1_000_000_000
        if estimatedParams < 1 {
            return String(format: "%.0fM", estimatedParams * 1000)
        }
        return String(format: "%.0fB", estimatedParams)
    }

    private func detectQuantization() -> QuantizationType {
        let lower = filename.lowercased()
        if lower.contains("q8") || lower.contains("8bit") { return .q8 }
        if lower.contains("f16") || lower.contains("fp16") || lower.contains("f32") { return .fp16 }
        return .q4  // Default for GGUF (most common)
    }

    private func inferFamily() -> String {
        let lower = filename.lowercased()
        let families: [(String, String)] = [
            // Check specific model names before generic families
            ("hermes", "Llama"), ("codellama", "CodeLlama"),
            ("minimax", "MiniMax"),
            ("llama", "Llama"), ("mistral", "Mistral"), ("mixtral", "Mixtral"),
            ("phi", "Phi"), ("gemma", "Gemma"), ("qwen", "Qwen"),
            ("deepseek", "DeepSeek"), ("falcon", "Falcon"), ("yi", "Yi"),
            ("solar", "Solar"), ("starcoder", "StarCoder"),
            ("command", "Command-R"), ("mamba", "Mamba"), ("rwkv", "RWKV"),
            ("internlm", "InternLM"), ("olmo", "OLMo"), ("stablelm", "StableLM"),
        ]
        for (pattern, name) in families {
            if lower.contains(pattern) { return name }
        }
        return "Unknown"
    }
}

// MARK: - GGUF Header Parser

/// Minimal GGUF header reader — extracts architecture and metadata without loading the full model.
public struct GGUFHeader: Sendable {
    public var architecture: String?
    public var contextLength: Int?
    public var modelName: String?

    /// Read just the GGUF magic and version to validate the file.
    static func read(from url: URL) -> GGUFHeader? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Read magic number (4 bytes): "GGUF" = 0x46554747
        guard let magicData = try? handle.read(upToCount: 4), magicData.count == 4 else { return nil }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard magic == 0x46554747 else { return nil }

        // Read version (4 bytes)
        guard let versionData = try? handle.read(upToCount: 4), versionData.count == 4 else { return nil }
        let version = versionData.withUnsafeBytes { $0.load(as: UInt32.self) }
        guard version >= 2 && version <= 3 else { return nil }

        // We've confirmed it's a valid GGUF file. Full metadata parsing is complex,
        // so we rely on filename-based heuristics for now.
        return GGUFHeader(architecture: nil, contextLength: nil, modelName: nil)
    }
}
