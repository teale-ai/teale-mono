import Foundation
import SharedTypes
import HardwareProfile
import ModelManager

/// Port of Windows `context_for_model()` from
/// `node/src/windows_model_catalog.rs` — scales a model's default context by
/// available RAM headroom. CPU-backend path is shorter: return default context
/// unchanged. Apple Silicon always uses GPU (Metal), so the RAM-headroom path
/// is the one that runs on the fleet.
public enum ContextScaler {
    public static func contextFor(
        model: ModelDescriptor,
        totalRAMGB: Double,
        defaultContext: Int? = nil,
        maxContext: Int? = nil
    ) -> Int {
        let base = defaultContext ?? 8192
        let cap = maxContext ?? 131_072
        let requiredRAM = model.requiredRAMGB
        let spareGB = max(totalRAMGB - requiredRAM, 0)
        var context = base
        if spareGB >= 4 { context = context * 2 }
        if spareGB >= 12 { context = context * 2 }
        if spareGB >= 24 { context = context * 2 }
        return min(context, cap)
    }
}

/// First-launch automation: pick the largest catalog model whose RAM budget
/// fits this Mac, download it, and load it. The 6-Mac fleet is heterogeneous
/// (8 GB to 512 GB) so we can't hardcode a single starter.
///
/// No-op if a model is already downloaded or loading. Safe to call on every
/// launch — the guards prevent redundant downloads.
public enum FleetAutoSetup {
    /// Largest catalog model that fits. Prefers higher RAM requirement so big
    /// fleet Macs serve flagship models instead of tiny ones.
    @MainActor
    public static func bestStarterModel(for appState: AppState) -> ModelDescriptor? {
        let catalog = appState.modelManager.catalog
        let compat = catalog.availableModels(for: appState.hardware)
        // Rank by: largest model that fits (descending requiredRAMGB), then
        // by lower popularityRank as tiebreaker.
        return compat.max { lhs, rhs in
            if lhs.requiredRAMGB != rhs.requiredRAMGB {
                return lhs.requiredRAMGB < rhs.requiredRAMGB
            }
            return lhs.popularityRank > rhs.popularityRank
        }
    }

    /// Call once on app launch. No-ops if a model is already present or
    /// a download is in flight.
    @MainActor
    public static func runIfNeeded(_ appState: AppState) async {
        // Don't re-trigger if user has already made a choice.
        let lastLoaded = UserDefaults.standard.string(forKey: "teale.lastLoadedModelID")
        let hasChoice = (lastLoaded != nil && !(lastLoaded?.isEmpty ?? true))
        guard !hasChoice else { return }
        guard appState.downloadedModelIDs.isEmpty else { return }
        guard appState.activeDownloads.isEmpty else { return }
        guard !appState.engineStatus.isReady else { return }

        guard let starter = bestStarterModel(for: appState) else { return }

        FileHandle.standardError.write(Data(
            "[FleetAutoSetup] Auto-downloading \(starter.name) (needs \(Int(starter.requiredRAMGB)) GB RAM) on \(appState.hardware.chipName) (\(Int(appState.hardware.totalRAMGB)) GB)\n".utf8
        ))

        await appState.downloadModel(starter)
    }
}
