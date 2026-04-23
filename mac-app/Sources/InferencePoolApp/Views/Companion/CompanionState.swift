import Foundation
import SwiftUI
import AppCore
import SharedTypes
import HardwareProfile
import ModelManager
import CreditKit
import ClusterKit
import WANKit

/// Windows-parity top-level navigation tabs.
enum CompanionTab: String, CaseIterable, Hashable {
    case home
    case supply
    case demand
    case wallet
    case account

    var label: String {
        switch self {
        case .home: return "teale"
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

    /// Most-requested model this machine can run. Falls back to the static
    /// catalog demand ranking when we do not have live demand observations yet.
    @MainActor
    func companionHighestDemandModel() -> ModelDescriptor? {
        if let liveDemand = demandTracker.modelsByDemand.first?.model {
            return liveDemand
        }
        return modelManager.catalog.topModels(for: hardware, limit: 1).first
    }

    /// Largest catalog model whose RAM requirement fits the current hardware,
    /// preferring higher popularity (lower rank). Falls back to nil on empty.
    @MainActor
    func companionLargestFitModel() -> ModelDescriptor? {
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

    @MainActor
    var companionLocalBaseURL: String {
        "http://127.0.0.1:\(serverPort)"
    }

    @MainActor
    var companionNetworkMetrics: CompanionNetworkMetrics {
        let lanPeers = clusterManager.topology.connectedPeers
        let wanPeers = wanManager.state.connectedPeers

        var uniqueModels = Set<String>()
        if let localModel = engineStatus.currentModel {
            uniqueModels.insert(localModel.openrouterId ?? localModel.huggingFaceRepo)
        }
        for peer in lanPeers {
            peer.loadedModels.forEach { uniqueModels.insert($0) }
        }
        for peer in wanPeers {
            peer.loadedModels.forEach { uniqueModels.insert($0) }
        }

        let tpsSamples = deviceTPSSamples(lanPeers: lanPeers, wanPeers: wanPeers)
        let ttftSamples = wanPeers.compactMap(\.latencyMs)

        return CompanionNetworkMetrics(
            totalDevices: 1 + lanPeers.count + wanPeers.count,
            totalRAMGB: hardware.totalRAMGB
                + clusterManager.topology.totalRAMGB
                + wanPeers.reduce(0) { $0 + $1.hardware.totalRAMGB },
            totalModels: uniqueModels.count,
            averageTTFTMs: ttftSamples.isEmpty
                ? nil
                : ttftSamples.reduce(0, +) / Double(ttftSamples.count),
            averageTPS: tpsSamples.isEmpty
                ? nil
                : tpsSamples.reduce(0, +) / Double(tpsSamples.count)
        )
    }

    @MainActor
    var companionTotalDevicesLabel: String {
        "\(companionNetworkMetrics.totalDevices)"
    }

    @MainActor
    var companionTotalRAMLabel: String {
        "\(Int(companionNetworkMetrics.totalRAMGB.rounded())) GB"
    }

    @MainActor
    var companionTotalModelsLabel: String {
        "\(companionNetworkMetrics.totalModels)"
    }

    @MainActor
    var companionAverageTTFTLabel: String {
        guard let ttft = companionNetworkMetrics.averageTTFTMs else {
            return "Waiting for WAN latency"
        }
        return "\(Int(ttft.rounded())) ms"
    }

    @MainActor
    var companionAverageTPSLabel: String {
        guard let tps = companionNetworkMetrics.averageTPS else {
            return "Waiting for serving nodes"
        }
        return String(format: "%.1f tok/s", tps)
    }

    @MainActor
    var companionTotalCreditsEarnedLabel: String {
        "\(companionCreditCountString(wallet.totalEarned)) credits"
    }

    @MainActor
    var companionTotalCreditsSpentLabel: String {
        "\(companionCreditCountString(wallet.totalSpent)) credits"
    }

    @MainActor
    var companionTotalUSDCDistributedLabel: String {
        "Not yet surfaced on mac"
    }

    @MainActor
    var companionHomeNetworkNote: String {
        "Home now matches the Windows sections: live peer counts plus threaded chat. TTFT and settlement totals still use the mac-side data that exists today."
    }

    @MainActor
    var companionGatewayBearerLabel: String {
        gatewayAPIKey.isEmpty ? "Not configured on this Mac" : "•••" + String(gatewayAPIKey.suffix(4))
    }

    @MainActor
    var companionSelectedGatewayModel: String {
        engineStatus.currentModel?.openrouterId
            ?? companionHighestDemandModel()?.openrouterId
            ?? "teale/auto"
    }

    @MainActor
    var companionLANPeersLabel: String {
        let count = clusterManager.topology.connectedPeers.count
        let status = clusterEnabled ? "LAN on" : "LAN off"
        return "\(count) peer(s) · \(status)"
    }

    @MainActor
    var companionWANStatusLabel: String {
        wanManager.state.statusSummary
    }

    @MainActor
    private func deviceTPSSamples(
        lanPeers: [PeerInfo],
        wanPeers: [WANPeerSummary]
    ) -> [Double] {
        var samples: [Double] = []

        if engineStatus.currentModel != nil {
            samples.append(max(hardware.memoryBandwidthGBs * 0.5, 1))
        }

        for peer in lanPeers where !peer.loadedModels.isEmpty {
            samples.append(max(peer.deviceInfo.hardware.memoryBandwidthGBs * 0.5, 1))
        }

        for peer in wanPeers where !peer.loadedModels.isEmpty {
            samples.append(max(peer.hardware.memoryBandwidthGBs * 0.5, 1))
        }

        return samples
    }

    @MainActor
    private func companionCreditCountString(_ amount: USDCAmount) -> String {
        let credits = amount.value * 1_000_000
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: credits)) ?? String(Int(credits))
    }
}

struct CompanionNetworkMetrics {
    let totalDevices: Int
    let totalRAMGB: Double
    let totalModels: Int
    let averageTTFTMs: Double?
    let averageTPS: Double?
}
