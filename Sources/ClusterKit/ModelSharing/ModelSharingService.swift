import Foundation
import SharedTypes

// MARK: - Model Sharing Service

/// Handles model availability queries and file transfers between peers
public actor ModelSharingService {
    private let modelCacheDirectory: URL
    private var activeTransfers: [UUID: TransferState] = [:]

    public init(modelCacheDirectory: URL? = nil) {
        self.modelCacheDirectory = modelCacheDirectory ?? {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return appSupport.appendingPathComponent("Teale/Models", isDirectory: true)
        }()
    }

    // MARK: - Query Handling

    /// Check if we have a model locally and respond
    public func handleModelQuery(_ query: ModelQueryPayload, connection: PeerConnection) async throws {
        let modelDir = modelCacheDirectory.appendingPathComponent(query.modelID)
        let exists = FileManager.default.fileExists(atPath: modelDir.path)
        var totalSize: UInt64? = nil

        if exists {
            totalSize = directorySize(modelDir)
        }

        let response = ModelQueryResponsePayload(
            modelID: query.modelID,
            available: exists,
            totalSizeBytes: totalSize
        )
        try await connection.send(.modelQueryResponse(response))
    }

    // MARK: - Transfer Sending

    /// Send a model to a requesting peer in chunks
    public func handleTransferRequest(_ request: ModelTransferRequestPayload, connection: PeerConnection) async throws {
        let modelDir = modelCacheDirectory.appendingPathComponent(request.modelID)
        guard FileManager.default.fileExists(atPath: modelDir.path) else {
            throw ModelSharingError.modelNotFound
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: modelDir,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        )

        for file in files {
            let fileData = try Data(contentsOf: file)
            let chunkSize = 1_048_576  // 1MB chunks

            var offset: UInt64 = 0
            while Int(offset) < fileData.count {
                let end = min(Int(offset) + chunkSize, fileData.count)
                let chunk = fileData[Int(offset)..<end]
                let isLast = end == fileData.count

                let payload = ModelTransferChunkPayload(
                    transferID: request.transferID,
                    fileName: file.lastPathComponent,
                    offset: offset,
                    data: Data(chunk),
                    isLastChunk: isLast && file == files.last
                )
                try await connection.send(.modelTransferChunk(payload))
                offset = UInt64(end)
            }
        }

        let complete = ModelTransferCompletePayload(
            transferID: request.transferID,
            modelID: request.modelID
        )
        try await connection.send(.modelTransferComplete(complete))
    }

    // MARK: - Transfer Receiving

    /// Handle an incoming chunk during a transfer
    public func handleTransferChunk(_ chunk: ModelTransferChunkPayload) throws {
        let transferDir = modelCacheDirectory.appendingPathComponent("_transfers/\(chunk.transferID.uuidString)")
        try FileManager.default.createDirectory(at: transferDir, withIntermediateDirectories: true)

        let filePath = transferDir.appendingPathComponent(chunk.fileName)

        if chunk.offset == 0 {
            // Create new file
            FileManager.default.createFile(atPath: filePath.path, contents: chunk.data)
        } else {
            // Append to existing file
            let handle = try FileHandle(forWritingTo: filePath)
            handle.seekToEndOfFile()
            handle.write(chunk.data)
            handle.closeFile()
        }
    }

    /// Finalize a completed transfer
    public func handleTransferComplete(_ complete: ModelTransferCompletePayload) throws {
        let transferDir = modelCacheDirectory.appendingPathComponent("_transfers/\(complete.transferID.uuidString)")
        let destDir = modelCacheDirectory.appendingPathComponent(complete.modelID)

        // Move from transfer dir to model cache
        if FileManager.default.fileExists(atPath: destDir.path) {
            try FileManager.default.removeItem(at: destDir)
        }
        try FileManager.default.moveItem(at: transferDir, to: destDir)
    }

    // MARK: - Helpers

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

// MARK: - Transfer State

private struct TransferState {
    var modelID: String
    var receivedBytes: UInt64
    var totalBytes: UInt64?
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
