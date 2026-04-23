import Foundation
import SwiftUI
import AppCore
import SharedTypes
import HardwareProfile
import ModelManager

/// Windows-parity top-level navigation tabs.
enum CompanionTab: String, CaseIterable, Hashable {
    case home
    case supply
    case demand
    case wallet
    case account

    var label: String {
        switch self {
        case .home: return "teale.com"
        case .supply: return "supply"
        case .demand: return "demand"
        case .wallet: return "wallet"
        case .account: return "account"
        }
    }
}

/// Windows-parity engine state machine surface. Translates the rich Mac
/// EngineStatus + app state into the 5 discrete buckets the Windows UI uses.
enum CompanionEngineState {
    case starting
    case loading(String)          // model name
    case serving(String)          // model name
    case downloading(String, Double) // model name, fraction
    case needsModel
    case pausedUser
    case pausedBattery
    case error(String)

    var displayText: String {
        switch self {
        case .starting: return "Starting"
        case .loading(let name): return "Loading \(name)"
        case .serving: return "Serving"
        case .downloading(let name, let p): return "Downloading \(name) (\(Int(p * 100))%)"
        case .needsModel: return "Needs a model"
        case .pausedUser: return "Paused"
        case .pausedBattery: return "Paused (on battery)"
        case .error(let msg): return "Error: \(msg)"
        }
    }

    var statusLine: String {
        switch self {
        case .starting: return "Connecting to the local Teale service..."
        case .loading: return "Loading weights into GPU memory..."
        case .serving: return "Accepting inference requests from the network."
        case .downloading: return "Fetching model weights from HuggingFace..."
        case .needsModel: return "Pick a model in the catalog to start earning."
        case .pausedUser: return "Supply is paused. Resume from the tray menu."
        case .pausedBattery: return "Waiting for AC power before resuming."
        case .error(let msg): return msg
        }
    }

    var chipColor: Color {
        switch self {
        case .serving: return TealeDesign.teale
        case .loading, .downloading: return TealeDesign.warn
        case .error: return TealeDesign.fail
        default: return TealeDesign.muted
        }
    }
}

extension AppState {
    /// Collapse the Mac-side EngineStatus + download/pause/hardware state into
    /// the Windows companion's 5-way state machine for view rendering.
    @MainActor
    var companionState: CompanionEngineState {
        if let (name, fraction) = firstActiveDownload {
            return .downloading(name, fraction)
        }
        switch engineStatus {
        case .idle:
            return downloadedModelIDs.isEmpty ? .needsModel : .starting
        case .loadingModel(let descriptor):
            return .loading(descriptor.name)
        case .ready(let descriptor):
            return .serving(descriptor.name)
        case .generating(let descriptor, _):
            return .serving(descriptor.name)
        case .error(let msg):
            return .error(msg)
        case .paused(let reason):
            switch reason {
            case .battery, .lowPowerMode, .notPluggedIn, .thermal: return .pausedBattery
            default: return .pausedUser
            }
        }
    }

    @MainActor
    private var firstActiveDownload: (String, Double)? {
        guard let (id, fraction) = activeDownloads.first else { return nil }
        let name = ModelCatalog.allModels.first(where: { $0.id == id })?.name ?? id
        return (name, fraction)
    }

    /// Largest catalog model whose RAM requirement fits the current hardware,
    /// preferring higher popularity (lower rank). Falls back to nil on empty.
    @MainActor
    func companionRecommendedModel() -> ModelDescriptor? {
        let compat = modelManager.catalog.availableModels(for: hardware)
        // Sort by descending requiredRAMGB to pick the largest that fits, then
        // by popularityRank as tiebreaker so popular models win at the margin.
        return compat.max { lhs, rhs in
            if lhs.requiredRAMGB != rhs.requiredRAMGB {
                return lhs.requiredRAMGB < rhs.requiredRAMGB
            }
            return lhs.popularityRank > rhs.popularityRank
        }
    }

    @MainActor
    var companionBackendLabel: String {
        switch inferenceBackend {
        case .localMLX: return "MLX"
        case .llamaCpp: return "llama.cpp (Metal)"
        case .exo: return "Exo"
        }
    }

    @MainActor
    var companionDeviceName: String {
        ProcessInfo.processInfo.hostName
    }

    @MainActor
    var companionPowerLabel: String {
        throttler.powerMonitor.powerState.isOnACPower ? "AC power" : "Battery"
    }

    @MainActor
    var companionRAMLabel: String {
        "\(Int(hardware.totalRAMGB)) GB · \(hardware.chipName)"
    }
}
