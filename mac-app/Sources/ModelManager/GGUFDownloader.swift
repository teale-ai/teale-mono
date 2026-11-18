import CryptoKit
import Foundation
import MLXInference
import SharedTypes

// MARK: - GGUF Downloader

/// Downloads the GGUF file(s) a catalog descriptor names (`ggufFiles`) into
/// `Teale/gguf/<model-id>`, verifies each file against the sha256 the
/// Hugging Face repo publishes for it (LFS oid), and only then writes the
/// verification marker that `ModelCache.isModelCached` checks.
struct GGUFDownloader: Sendable {
    struct RemoteFile: Sendable, Equatable {
        let path: String
        let size: Int64?
        let sha256: String?
    }

    enum DownloadError: LocalizedError {
        case notAGGUFDescriptor(String)
        case noMatchingRemoteFiles(String)
        case missingAfterDownload(String)
        case sizeMismatch(String)
        case checksumMismatch(String)

        var errorDescription: String? {
            switch self {
            case .notAGGUFDescriptor(let id):
                return "\(id) has no GGUF file list or an unsafe id."
            case .noMatchingRemoteFiles(let repo):
                return "No GGUF files in \(repo) match the catalog entry."
            case .missingAfterDownload(let path):
                return "GGUF file missing after download: \(path)"
            case .sizeMismatch(let path):
                return "GGUF file has the wrong size: \(path)"
            case .checksumMismatch(let path):
                return "GGUF file failed sha256 verification: \(path)"
            }
        }
    }

    var session: URLSession = .shared

    func download(
        _ descriptor: ModelDescriptor,
        progress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard descriptor.format == .gguf,
              let patterns = descriptor.ggufFiles, !patterns.isEmpty,
              let modelDir = ModelStorageLayout.ggufModelDirectory(modelID: descriptor.id) else {
            throw DownloadError.notAGGUFDescriptor(descriptor.id)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)
        let marker = modelDir.appendingPathComponent(ModelStorageLayout.ggufVerifiedMarker)
        try? fm.removeItem(at: marker)

        let remote = try await remoteFiles(repo: descriptor.huggingFaceRepo, patterns: patterns)
        guard !remote.isEmpty else {
            throw DownloadError.noMatchingRemoteFiles(descriptor.huggingFaceRepo)
        }

        let downloader = HFDownloader(downloadBase: modelDir)
        let snapshot = try await downloader.download(
            id: descriptor.huggingFaceRepo,
            revision: nil,
            matching: remote.map(\.path),
            useLatest: false
        ) { value in
            // Leave the last 5% for verification.
            progress(min(value.fractionCompleted, 1.0) * 0.95)
        }

        for (index, file) in remote.enumerated() {
            let local = snapshot.appendingPathComponent(file.path)
            guard SafePathComponent.isContained(local, in: modelDir),
                  fm.fileExists(atPath: local.path) else {
                throw DownloadError.missingAfterDownload(file.path)
            }
            if let size = file.size {
                let attributes = try fm.attributesOfItem(atPath: local.resolvingSymlinksInPath().path)
                let actual = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard actual == size else { throw DownloadError.sizeMismatch(file.path) }
            }
            if let expected = file.sha256 {
                let actual = try await Task.detached(priority: .utility) {
                    try Self.sha256Hex(of: local.resolvingSymlinksInPath())
                }.value
                guard actual == expected.lowercased() else {
                    try? fm.removeItem(at: local)
                    throw DownloadError.checksumMismatch(file.path)
                }
            }
            progress(0.95 + 0.05 * Double(index + 1) / Double(remote.count))
        }

        let record: [String: Any] = [
            "repo": descriptor.huggingFaceRepo,
            "files": remote.map(\.path),
            "sha256Verified": remote.allSatisfy { $0.sha256 != nil },
            "verifiedAt": ISO8601DateFormatter().string(from: Date()),
        ]
        let data = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: marker, options: .atomic)
    }

    /// Lists the repo files matching `patterns` via the Hub tree API, with
    /// their LFS sha256 and size. One listing per distinct directory.
    func remoteFiles(repo: String, patterns: [String]) async throws -> [RemoteFile] {
        var directories: [String] = []
        for pattern in patterns {
            let dir = pattern.split(separator: "/").dropLast().joined(separator: "/")
            if !directories.contains(dir) { directories.append(dir) }
        }

        var files: [RemoteFile] = []
        for dir in directories {
            var path = "https://huggingface.co/api/models/\(repo)/tree/main"
            if !dir.isEmpty { path += "/\(dir)" }
            guard let url = URL(string: path) else { continue }
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            files.append(contentsOf: Self.parseTree(data).filter { file in
                patterns.contains { ModelStorageLayout.globMatches(pattern: $0, path: file.path) }
            })
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Parses a Hub `tree` listing: `[{type, path, size, lfs: {oid, size}}]`.
    static func parseTree(_ data: Data) -> [RemoteFile] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard (entry["type"] as? String) == "file", let path = entry["path"] as? String else {
                return nil
            }
            let lfs = entry["lfs"] as? [String: Any]
            let sha = (lfs?["oid"] as? String).flatMap { $0.count == 64 ? $0 : nil }
            let size = (lfs?["size"] as? NSNumber)?.int64Value ?? (entry["size"] as? NSNumber)?.int64Value
            return RemoteFile(path: path, size: size, sha256: sha)
        }
    }

    /// Streaming sha256 (8 MiB reads) so multi-hundred-GB shards never sit
    /// in memory.
    static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: 8 * 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
