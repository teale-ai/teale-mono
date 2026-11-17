import Foundation

// MARK: - Safe path components

/// Validation for names that arrive from untrusted sources (LAN peers,
/// remote control) before they are joined onto a local directory.
public enum SafePathComponent {
    /// True when `name` is a single path component that cannot climb out
    /// of the directory it is appended to: not empty, not `.`/`..`, and no
    /// `/`, `\`, `..` or NUL/control characters anywhere in it.
    public static func isValid(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 255 else { return false }
        if name.contains("..") { return false }
        if name == "." { return false }
        for scalar in name.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar.value == 0 { return false }
            if scalar.properties.generalCategory == .control { return false }
        }
        return true
    }

    /// Appends `component` to `directory` and returns the result only when
    /// the component is valid and the standardized result is still strictly
    /// inside `directory`.
    public static func resolve(_ component: String, in directory: URL) -> URL? {
        guard isValid(component) else { return nil }
        let candidate = directory.appendingPathComponent(component)
        guard isContained(candidate, in: directory) else { return nil }
        return candidate
    }

    /// Lexical containment check on standardized paths: `url` must be a
    /// strict descendant of `directory`.
    public static func isContained(_ url: URL, in directory: URL) -> Bool {
        let root = directory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        let prefix = root.hasSuffix("/") ? root : root + "/"
        return target.hasPrefix(prefix) && target.count > prefix.count
    }

    /// True when `url` exists and is a symbolic link (never write through one).
    public static func isSymlink(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return false
        }
        return (attributes[.type] as? FileAttributeType) == .typeSymbolicLink
    }
}

// MARK: - Model storage layout

/// On-disk layout of Teale-managed model weights. Shared by `ModelCache`,
/// the GGUF download path, the llama.cpp/ds4 providers and LAN model
/// sharing so they all agree on where a model lives.
///
/// - MLX snapshots: `Teale/huggingface/models/<org>/<name>` — the layout
///   HubApi writes and the MLX loader reads (keyed by repo).
/// - GGUF files: `Teale/gguf/<model-id>/models/<org>/<name>/...` — keyed
///   by the catalog model id, so two catalog entries that share one HF
///   repo (DeepSeek V4 Flash / Pro) never share a cache directory.
public enum ModelStorageLayout {
    public static func tealeApplicationSupportDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Teale", isDirectory: true)
    }

    /// HubApi download base for MLX snapshots.
    public static func huggingFaceBaseDirectory() -> URL {
        tealeApplicationSupportDirectory().appendingPathComponent("huggingface", isDirectory: true)
    }

    public static func huggingFaceModelsDirectory() -> URL {
        huggingFaceBaseDirectory().appendingPathComponent("models", isDirectory: true)
    }

    public static func ggufRootDirectory() -> URL {
        tealeApplicationSupportDirectory().appendingPathComponent("gguf", isDirectory: true)
    }

    /// Scratch space for in-flight LAN model transfers.
    public static func transfersDirectory() -> URL {
        tealeApplicationSupportDirectory().appendingPathComponent("transfers", isDirectory: true)
    }

    /// `org/name` repo id → `huggingface/models/org/name`, or nil when the
    /// repo id is not one or two safe path components.
    public static func mlxModelDirectory(repo: String) -> URL? {
        let parts = repo.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...2).contains(parts.count), parts.allSatisfy(SafePathComponent.isValid) else {
            return nil
        }
        var url = huggingFaceModelsDirectory()
        for part in parts {
            url.appendPathComponent(part, isDirectory: true)
        }
        return url
    }

    /// `Teale/gguf/<model-id>`, or nil for an unsafe id.
    public static func ggufModelDirectory(modelID: String) -> URL? {
        SafePathComponent.resolve(modelID, in: ggufRootDirectory())
    }

    /// Where this model's weights live (or will live) on disk.
    public static func modelDirectory(for descriptor: ModelDescriptor) -> URL? {
        switch descriptor.format {
        case .gguf:
            return ggufModelDirectory(modelID: descriptor.id)
        case .mlx:
            return mlxModelDirectory(repo: descriptor.huggingFaceRepo)
        }
    }

    /// Name of the marker written after every GGUF file of a model was
    /// downloaded and verified. Its presence is what "downloaded" means.
    public static let ggufVerifiedMarker = ".teale-verified"

    /// The file llama.cpp / ds4-server should be started with: the
    /// descriptor path itself for a scanned local GGUF, otherwise the first
    /// (sorted) downloaded file under `Teale/gguf/<model-id>` matching the
    /// descriptor's `ggufFiles` patterns — for split GGUFs that is the
    /// `-00001-of-N` shard.
    public static func localGGUFFile(for descriptor: ModelDescriptor) -> URL? {
        let fm = FileManager.default
        if descriptor.huggingFaceRepo.hasPrefix("/"), fm.fileExists(atPath: descriptor.huggingFaceRepo) {
            return URL(fileURLWithPath: descriptor.huggingFaceRepo)
        }
        guard descriptor.format == .gguf,
              let modelDir = ggufModelDirectory(modelID: descriptor.id),
              let patterns = descriptor.ggufFiles, !patterns.isEmpty else {
            return nil
        }
        let files = ggufFiles(in: modelDir, matching: patterns).sorted()
        guard let first = files.first else { return nil }
        return modelDir.appendingPathComponent(first)
    }

    /// GGUF files under `modelDir` (relative paths) whose path ends with a
    /// repo-relative `pattern`. Matching on the suffix keeps this
    /// independent of the exact snapshot sub-path HubApi writes
    /// (`models/<org>/<name>/...`).
    public static func ggufFiles(in modelDir: URL, matching patterns: [String]) -> [String] {
        relativeFiles(in: modelDir)
            .filter { $0.lowercased().hasSuffix(".gguf") }
            .filter { path in
                patterns.contains { pattern in
                    globMatches(pattern: pattern, path: path) || globMatches(pattern: "*/" + pattern, path: path)
                }
            }
    }

    /// Regular files under `directory`, as paths relative to it (hidden
    /// entries skipped).
    public static func relativeFiles(in directory: URL) -> [String] {
        let root = directory.standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(root + "/") else { continue }
            results.append(String(path.dropFirst(root.count + 1)))
        }
        return results
    }

    /// fnmatch(3) with no flags: `*` also matches `/`, matching how HubApi
    /// filters repo paths.
    public static func globMatches(pattern: String, path: String) -> Bool {
        fnmatch(pattern, path, 0) == 0
    }
}

// MARK: - Known-model registry

/// Maps catalog model ids to descriptors for components that cannot import
/// the catalog (ClusterKit's LAN model sharing). `ModelManagerService`
/// registers the catalog at start-up. Unknown ids resolve to nothing,
/// which is what keeps a peer from naming arbitrary directories.
public final class ModelDirectoryRegistry: @unchecked Sendable {
    public static let shared = ModelDirectoryRegistry()

    private let lock = NSLock()
    private var descriptorsByID: [String: ModelDescriptor] = [:]

    public init() {}

    public func register(_ descriptors: [ModelDescriptor]) {
        lock.lock(); defer { lock.unlock() }
        for descriptor in descriptors {
            descriptorsByID[descriptor.id] = descriptor
        }
    }

    public func descriptor(forModelID id: String) -> ModelDescriptor? {
        guard SafePathComponent.isValid(id) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return descriptorsByID[id]
    }
}

// MARK: - Model fit rule

/// The one rule that decides whether a model fits a device. Used by the
/// catalog filter (`ModelCatalog.availableModels`), by
/// `HardwareCapability.availableRAMForModelsGB`, and by the MLX loader's
/// free-memory guard; `docs/device-model-matrix.md` and
/// `docs/mac-fleet-configurations.md` describe the same rule.
///
/// Budget = min(75% of unified RAM, RAM − 4 GB), floor 1 GB. A model fits
/// when its full footprint (`requiredRAMGB`: weights + KV cache + runtime)
/// is within that budget. For planning from a bare weight size the
/// footprint is estimated as 1.25 × weights, which makes the rule
/// equivalent to the docs' "weights ≤ 0.6 × RAM" on machines ≥ 16 GB.
public enum ModelFit {
    public static let usableRAMFraction = 0.75
    public static let osReserveGB = 4.0
    public static let footprintPerWeightGB = 1.25

    public static func budgetGB(totalRAMGB: Double) -> Double {
        max(min(totalRAMGB * usableRAMFraction, totalRAMGB - osReserveGB), 1.0)
    }

    /// Footprint for a descriptor: its declared `requiredRAMGB`, or an
    /// estimate from the weight size when that is unknown (0).
    public static func footprintGB(for model: ModelDescriptor) -> Double {
        if model.requiredRAMGB > 0 { return model.requiredRAMGB }
        return model.estimatedSizeGB * footprintPerWeightGB
    }

    public static func fits(_ model: ModelDescriptor, totalRAMGB: Double) -> Bool {
        footprintGB(for: model) <= budgetGB(totalRAMGB: totalRAMGB)
    }
}
