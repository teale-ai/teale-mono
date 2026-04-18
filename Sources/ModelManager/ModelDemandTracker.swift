import Foundation
import SharedTypes

// MARK: - Model Demand Tracker

/// Tracks which models are requested on the network and suggests downloads.
/// When auto-manage is enabled, automatically downloads in-demand models
/// that this node can run but hasn't downloaded yet.
@Observable
public final class ModelDemandTracker: @unchecked Sendable {
    /// Per-model request counts observed from the network
    public private(set) var demandCounts: [String: Int] = [:]  // modelID -> request count

    /// Models suggested for download based on network demand
    public private(set) var suggestedModels: [ModelDescriptor] = []

    /// Whether to automatically download high-demand models
    public var autoManageEnabled: Bool = false

    /// Callback invoked when a model should be auto-downloaded
    public var onAutoDownloadRequested: ((ModelDescriptor) -> Void)?

    private let catalog: ModelCatalog
    private let hardware: HardwareCapability

    public init(catalog: ModelCatalog, hardware: HardwareCapability) {
        self.catalog = catalog
        self.hardware = hardware
    }

    /// Record a demand signal for a model (from peer requests, cluster routing, etc.)
    public func recordDemand(for modelID: String, count: Int = 1) {
        demandCounts[modelID, default: 0] += count
        refreshSuggestions()
    }

    /// Record demand from a batch of peer heartbeats (what models peers are requesting)
    public func recordPeerDemand(_ requestedModelIDs: [String]) {
        for id in requestedModelIDs {
            demandCounts[id, default: 0] += 1
        }
        refreshSuggestions()
    }

    /// Reset demand counters (call periodically, e.g. daily)
    public func resetCounts() {
        demandCounts.removeAll()
        suggestedModels.removeAll()
    }

    /// Models sorted by demand, highest first
    public var modelsByDemand: [(model: ModelDescriptor, requests: Int)] {
        let compatible = catalog.availableModels(for: hardware)
        return compatible
            .compactMap { model -> (ModelDescriptor, Int)? in
                guard let count = demandCounts[model.id], count > 0 else { return nil }
                return (model, count)
            }
            .sorted { $0.1 > $1.1 }
    }

    // MARK: - Private

    private func refreshSuggestions() {
        let compatible = Set(catalog.availableModels(for: hardware).map(\.id))
        let allModelsMap = Dictionary(
            uniqueKeysWithValues: ModelCatalog.allModels.map { ($0.id, $0) }
        )

        // Find high-demand models we can run — sorted by demand
        let sorted = demandCounts
            .filter { compatible.contains($0.key) }
            .sorted { $0.value > $1.value }

        suggestedModels = sorted.prefix(5).compactMap { allModelsMap[$0.key] }

        // Auto-download if enabled
        if autoManageEnabled, let top = suggestedModels.first {
            onAutoDownloadRequested?(top)
        }
    }
}
