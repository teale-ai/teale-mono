import Foundation
import SharedTypes

// MARK: - Model Sharing Service

/// Handles model availability queries and file transfers between peers.
///
/// Everything a peer sends is untrusted:
/// - `modelID` must be a single safe path component AND a model this Mac
///   knows (`ModelDirectoryRegistry`, filled from the catalog). It is
///   mapped to the real model cache directory (`ModelStorageLayout`), never
///   joined onto a path directly.
/// - `fileName` must be a single safe path component.
/// - Every resolved path is checked to stay inside Teale's storage before
///   any read, write, move or delete.
/// - Incoming chunks are accepted only for transfers this Mac requested,
///   from the peer it asked, at the exact offset expected, up to a size cap.
/// Only flat MLX snapshot directories are shared; GGUF models are not.
public actor ModelSharingService {
    private let storageRoot: URL
    private let transfersRoot: URL
    private let resolveModelDirectory: @Sendable (String) -> URL?
    private var incoming: [UUID: IncomingTransfer] = [:]

    /// Bytes per outgoing chunk; files are streamed, never read whole.
    static let chunkSize = 1_048_576
    /// Upper bound for one received model (guards disk exhaustion).
    static let maxTransferBytes: UInt64 = 1 << 40  // 1 TiB

    public init(
        storageRoot: URL = ModelStorageLayout.tealeApplicationSupportDirectory(),
        transfersRoot: URL = ModelStorageLayout.transfersDirectory(),
        resolveModelDirectory: @escaping @Sendable (String) -> URL? = ModelSharingService.defaultModelDirectory
    ) {
        self.storageRoot = storageRoot
        self.transfersRoot = transfersRoot
        self.resolveModelDirectory = resolveModelDirectory
    }

    /// Catalog model id → its real cache directory (the HubApi MLX layout).
    /// Unknown ids, unsafe ids and GGUF/exo models resolve to nil.
    public static let defaultModelDirectory: @Sendable (String) -> URL? = { modelID in
        guard let descriptor = ModelDirectoryRegistry.shared.descriptor(forModelID: modelID),
              descriptor.format == .mlx,
              descriptor.servingBackend != .exo else {
            return nil
        }
        return ModelStorageLayout.mlxModelDirectory(repo: descriptor.huggingFaceRepo)
    }

    /// Safe, contained directory for a peer-supplied model id, or nil.
    func modelDirectory(for modelID: String) -> URL? {
        guard SafePathComponent.isValid(modelID),
              let dir = resolveModelDirectory(modelID),
              SafePathComponent.isContained(dir, in: storageRoot),
              !SafePathComponent.isSymlink(dir) else {
            return nil
        }
        return dir
    }

    // MARK: - Query Handling

    /// Check if we have a model locally and respond
    public func handleModelQuery(_ query: ModelQueryPayload, connection: PeerConnection) async throws {
        var exists = false
        var totalSize: UInt64? = nil
        if let modelDir = modelDirectory(for: query.modelID),
           FileManager.default.fileExists(atPath: modelDir.path) {
            let files = shareableFiles(in: modelDir)
            exists = !files.isEmpty
            totalSize = exists ? files.reduce(0) { $0 + $1.size } : nil
        }

        let response = ModelQueryResponsePayload(
            modelID: query.modelID,
            available: exists,
            totalSizeBytes: totalSize
        )
        try await connection.send(.modelQueryResponse(response))
    }

    // MARK: - Transfer Sending

    /// Stream a model to a requesting peer in 1 MiB chunks.
    public func handleTransferRequest(_ request: ModelTransferRequestPayload, connection: PeerConnection) async throws {
        guard let modelDir = modelDirectory(for: request.modelID),
              FileManager.default.fileExists(atPath: modelDir.path) else {
            throw ModelSharingError.modelNotFound
        }

        let files = shareableFiles(in: modelDir)
        guard !files.isEmpty else { throw ModelSharingError.modelNotFound }

        for (fileIndex, file) in files.enumerated() {
            let isLastFile = fileIndex == files.count - 1
            let handle = try FileHandle(forReadingFrom: file.url)
            defer { try? handle.close() }

            var offset: UInt64 = 0
            repeat {
                let data = try handle.read(upToCount: Self.chunkSize) ?? Data()
                let nextOffset = offset + UInt64(data.count)
                let isLast = nextOffset >= file.size || data.isEmpty
                let payload = ModelTransferChunkPayload(
                    transferID: request.transferID,
                    fileName: file.url.lastPathComponent,
                    offset: offset,
                    data: data,
                    isLastChunk: isLast && isLastFile
                )
                try await connection.send(.modelTransferChunk(payload))
                offset = nextOffset
                if isLast { break }
            } while true
        }

        let complete = ModelTransferCompletePayload(
            transferID: request.transferID,
            modelID: request.modelID
        )
        try await connection.send(.modelTransferComplete(complete))
    }

    // MARK: - Transfer Receiving

    /// Record that this Mac asked `peerID` for `modelID` under `transferID`.
    /// Chunks for any other transfer are rejected.
    public func expectTransfer(transferID: UUID, modelID: String, from peerID: UUID) throws {
        guard modelDirectory(for: modelID) != nil else {
            throw ModelSharingError.transferFailed("unknown or unsafe model id")
        }
        incoming[transferID] = IncomingTransfer(modelID: modelID, peerID: peerID)
    }

    public func cancelExpectedTransfer(_ transferID: UUID) {
        incoming.removeValue(forKey: transferID)
        if let dir = transferDirectory(for: transferID) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Handle an incoming chunk during a transfer
    public func handleTransferChunk(_ chunk: ModelTransferChunkPayload, from peerID: UUID) throws {
        guard var transfer = incoming[chunk.transferID], transfer.peerID == peerID else {
            throw ModelSharingError.transferFailed("unexpected transfer")
        }
        guard let transferDir = transferDirectory(for: chunk.transferID),
              let filePath = SafePathComponent.resolve(chunk.fileName, in: transferDir) else {
            cancelExpectedTransfer(chunk.transferID)
            throw ModelSharingError.transferFailed("unsafe file name")
        }
        let received = transfer.receivedBytes + UInt64(chunk.data.count)
        guard received <= Self.maxTransferBytes else {
            cancelExpectedTransfer(chunk.transferID)
            throw ModelSharingError.transferFailed("transfer exceeds size limit")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: transferDir, withIntermediateDirectories: true)
        guard !SafePathComponent.isSymlink(filePath) else {
            cancelExpectedTransfer(chunk.transferID)
            throw ModelSharingError.transferFailed("refusing to write through a symlink")
        }

        let currentSize = transfer.fileSizes[chunk.fileName] ?? 0
        guard chunk.offset == currentSize else {
            cancelExpectedTransfer(chunk.transferID)
            throw ModelSharingError.transferFailed("out-of-order chunk")
        }

        if chunk.offset == 0 {
            guard fm.createFile(atPath: filePath.path, contents: chunk.data) else {
                throw ModelSharingError.transferFailed("cannot create \(chunk.fileName)")
            }
        } else {
            let handle = try FileHandle(forWritingTo: filePath)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: chunk.data)
        }

        transfer.fileSizes[chunk.fileName] = currentSize + UInt64(chunk.data.count)
        transfer.receivedBytes = received
        incoming[chunk.transferID] = transfer
    }

    /// Finalize a completed transfer into the model's real cache directory.
    public func handleTransferComplete(_ complete: ModelTransferCompletePayload, from peerID: UUID) throws {
        guard let transfer = incoming[complete.transferID], transfer.peerID == peerID else {
            throw ModelSharingError.transferFailed("unexpected transfer")
        }
        incoming.removeValue(forKey: complete.transferID)
        guard complete.modelID == transfer.modelID,
              let destDir = modelDirectory(for: transfer.modelID),
              let transferDir = transferDirectory(for: complete.transferID) else {
            cancelExpectedTransfer(complete.transferID)
            throw ModelSharingError.transferFailed("model id mismatch")
        }

        let fm = FileManager.default
        try fm.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destDir.path) {
            try fm.removeItem(at: destDir)
        }
        try fm.moveItem(at: transferDir, to: destDir)
    }

    // MARK: - Helpers

    private func transferDirectory(for transferID: UUID) -> URL? {
        SafePathComponent.resolve(transferID.uuidString, in: transfersRoot)
    }

    /// Regular, non-hidden, top-level files of a model directory (symlinks
    /// are followed only when they stay inside Teale's storage, as HubApi
    /// snapshots may link into a blob store).
    private func shareableFiles(in dir: URL) -> [(url: URL, size: UInt64)] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        var files: [(url: URL, size: UInt64)] = []
        for name in names.sorted() where SafePathComponent.isValid(name) && !name.hasPrefix(".") {
            let url = dir.appendingPathComponent(name)
            let resolved = url.resolvingSymlinksInPath()
            guard SafePathComponent.isContained(resolved, in: storageRoot)
                    || resolved.standardizedFileURL.path == url.standardizedFileURL.path,
                  let attributes = try? fm.attributesOfItem(atPath: resolved.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                continue
            }
            files.append((url: resolved, size: size))
        }
        return files
    }
}

// MARK: - Transfer State

private struct IncomingTransfer {
    var modelID: String
    var peerID: UUID
    var receivedBytes: UInt64 = 0
    var fileSizes: [String: UInt64] = [:]
}

// MARK: - Errors

public enum ModelSharingError: LocalizedError, Sendable {
    case modelNotFound
    case transferFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound: return "Model not found in local cache"
        case .transferFailed(let msg): return "Model transfer failed: \(msg)"
        }
    }
}
