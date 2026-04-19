import Foundation
import SharedTypes
import CompilerKit
import ClusterKit
import WANKit

// MARK: - Network Model Collector

/// Converts heterogeneous peer state (local, LAN, WAN) into the uniform
/// `[ModelOnNetwork]` that CompilerKit needs for model selection.
enum NetworkModelCollector {

    /// Collect all models currently available across all network tiers.
    ///
    /// - Parameters:
    ///   - localModel: The locally loaded model descriptor, if any.
    ///   - localHardware: The local device's hardware capability.
    ///   - lanPeers: Connected LAN cluster peers.
    ///   - wanPeers: Connected WAN peer summaries.
    /// - Returns: Flat list of models available on the network, one entry per model per device.
    static func collect(
        localModel: ModelDescriptor?,
        localHardware: HardwareCapability,
        lanPeers: [PeerInfo],
        wanPeers: [WANPeerSummary]
    ) -> [ModelOnNetwork] {
        var models: [ModelOnNetwork] = []

        // Local model
        if let descriptor = localModel {
            models.append(ModelOnNetwork(
                model: descriptor.huggingFaceRepo,
                modelFamily: descriptor.family,
                parameterBillions: extractParameterBillions(descriptor.parameterCount),
                deviceID: nil,
                currentLoad: 0,
                estimatedToksPerSec: estimateToksPerSec(bandwidthGBs: localHardware.memoryBandwidthGBs)
            ))
        }

        // LAN cluster peers
        for peer in lanPeers where peer.status == .connected {
            for modelID in peer.loadedModels {
                models.append(ModelOnNetwork(
                    model: modelID,
                    modelFamily: extractModelFamily(modelID),
                    parameterBillions: extractParameterBillionsFromRepo(modelID),
                    deviceID: peer.id,
                    currentLoad: peer.activeRequestCount,
                    estimatedToksPerSec: estimateToksPerSec(bandwidthGBs: peer.deviceInfo.hardware.memoryBandwidthGBs)
                ))
            }
        }

        // WAN peers
        for peer in wanPeers {
            let deviceID = stableUUID(from: peer.id)
            for modelID in peer.loadedModels {
                models.append(ModelOnNetwork(
                    model: modelID,
                    modelFamily: extractModelFamily(modelID),
                    parameterBillions: extractParameterBillionsFromRepo(modelID),
                    deviceID: deviceID,
                    currentLoad: 0,
                    estimatedToksPerSec: estimateToksPerSec(bandwidthGBs: peer.hardware.memoryBandwidthGBs)
                ))
            }
        }

        return models
    }

    // MARK: - Helpers

    /// Extract model family from a HuggingFace repo string.
    /// e.g. "mlx-community/Qwen2.5-7B-Instruct-4bit" → "Qwen"
    static func extractModelFamily(_ repoID: String) -> String {
        let lowered = repoID.lowercased()
        let families = ["qwen", "llama", "gemma", "phi", "mistral"]
        for family in families {
            if lowered.contains(family) {
                return family.prefix(1).uppercased() + family.dropFirst()
            }
        }
        return "Unknown"
    }

    /// Extract parameter count from a string like "8B" or "1.5B" → Double.
    static func extractParameterBillions(_ paramString: String) -> Double {
        let pattern = #"(\d+\.?\d*)"#
        guard let match = paramString.range(of: pattern, options: .regularExpression) else {
            return 3.0
        }
        return Double(paramString[match]) ?? 3.0
    }

    /// Extract parameter count from a HuggingFace repo ID.
    /// e.g. "mlx-community/Llama-3.2-8B-Instruct-4bit" → 8.0
    static func extractParameterBillionsFromRepo(_ repoID: String) -> Double {
        // Match patterns like "8B", "1.5B", "109B" (case insensitive)
        let pattern = #"(\d+\.?\d*)[Bb](?:-|$|\d)"#
        guard let match = repoID.range(of: pattern, options: .regularExpression) else {
            // Try simpler pattern without trailing constraint
            let simple = #"(\d+\.?\d*)[Bb]"#
            guard let simpleMatch = repoID.range(of: simple, options: .regularExpression) else {
                return 3.0
            }
            let numStr = repoID[simpleMatch].dropLast() // drop the "B"
            return Double(numStr) ?? 3.0
        }
        // Extract just the numeric portion
        let segment = repoID[match]
        let numStr = segment.prefix(while: { $0.isNumber || $0 == "." })
        return Double(numStr) ?? 3.0
    }

    /// Estimate tokens/sec from memory bandwidth.
    /// Heuristic: quantized models on Apple Silicon get ~0.5 tok/sec per GB/s bandwidth.
    static func estimateToksPerSec(bandwidthGBs: Double) -> Double {
        guard bandwidthGBs > 0 else { return 15.0 }
        return bandwidthGBs * 0.5
    }

    /// Create a deterministic UUID from a WAN nodeID string.
    /// WAN nodeIDs are already UUID strings from `stableInstallNodeID()`.
    static func stableUUID(from nodeID: String) -> UUID {
        if let uuid = UUID(uuidString: nodeID) {
            return uuid
        }
        // Fallback: hash the string into a UUID
        var hasher = Hasher()
        hasher.combine(nodeID)
        let hash = hasher.finalize()
        let bytes = withUnsafeBytes(of: hash) { Array($0) }
        // Pad to 16 bytes
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for (i, byte) in bytes.prefix(16).enumerated() {
            uuidBytes[i] = byte
        }
        return UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        ))
    }
}
