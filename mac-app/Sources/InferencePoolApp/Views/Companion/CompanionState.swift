import Foundation
import SwiftUI
import AppCore
import SharedTypes
import HardwareProfile
import ModelManager
import CreditKit
import ClusterKit
import WANKit
import GatewayKit

/// Windows-parity top-level navigation tabs.
enum CompanionTab: String, CaseIterable, Hashable {
    case home
    case supply
    case demand
    case wallet
    case account

    @MainActor
    func label(in appState: AppState) -> String {
        switch self {
        case .home: return appState.companionText("nav.home", fallback: "teale")
        case .supply: return appState.companionText("nav.supply", fallback: "supply")
        case .demand: return appState.companionText("nav.demand", fallback: "demand")
        case .wallet: return appState.companionText("nav.wallet", fallback: "wallet")
        case .account: return appState.companionText("nav.account", fallback: "account")
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
        case .serving: return "Local serving is ready. Wallet earnings still require relay connectivity and a gateway-aligned device identity."
        case .downloading: return "Fetching model weights from HuggingFace..."
        case .needsModel: return "Pick a model in the catalog to become eligible for network earnings."
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
        companionDisplayAmountString(amount: wallet.totalEarned)
    }

    @MainActor
    var companionTotalCreditsSpentLabel: String {
        companionDisplayAmountString(amount: wallet.totalSpent)
    }

    @MainActor
    var companionTotalUSDCDistributedLabel: String {
        "-"
    }

    @MainActor
    var companionHomeNetworkNote: String {
        ""
    }

    @MainActor
    var companionGatewayBearerLabel: String {
        gatewayAPIKey.isEmpty ? "..." : "•••" + String(gatewayAPIKey.suffix(4))
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
    var companionSupplyIdentityStatus: CompanionSupplyIdentityStatus {
        let gatewayDeviceID = GatewayIdentity.shared.deviceID
        let wanNodeID = (try? WANNodeIdentity.loadFromFile().nodeID) ?? gatewayDeviceID
        return CompanionSupplyIdentityStatus(
            gatewayDeviceID: gatewayDeviceID,
            wanNodeID: wanNodeID,
            localServingReady: engineStatus.isReady || engineStatus.isGenerating,
            relayConnected: wanEnabled && wanManager.state.relayStatus == .connected
        )
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
}

struct CompanionNetworkMetrics {
    let totalDevices: Int
    let totalRAMGB: Double
    let totalModels: Int
    let averageTTFTMs: Double?
    let averageTPS: Double?
}

struct CompanionNetworkModelSummary: Identifiable, Hashable {
    let id: String
    let deviceCount: Int
    let promptUSDPerToken: Double?
    let completionUSDPerToken: Double?
}

struct CompanionSupplyIdentityStatus {
    let gatewayDeviceID: String
    let wanNodeID: String
    let localServingReady: Bool
    let relayConnected: Bool

    var identityMismatch: Bool {
        gatewayDeviceID != wanNodeID
    }

    var earningEligible: Bool {
        localServingReady && relayConnected && !identityMismatch
    }

    var relayLabel: String {
        relayConnected ? "Connected" : "Disconnected"
    }

    var identityLabel: String {
        identityMismatch ? "Mismatch" : "Aligned"
    }

    var eligibilityLabel: String {
        earningEligible ? "Eligible" : "Not yet"
    }

    var summary: String {
        if earningEligible {
            return "Relay connected, model loaded, and WAN identity matches this gateway wallet."
        }
        if identityMismatch {
            return "This install is serving under a different WAN node ID than the gateway wallet shown here."
        }
        if !relayConnected {
            return "Relay is not connected yet, so this wallet cannot earn network credits."
        }
        if !localServingReady {
            return "Load a compatible model to make this wallet eligible for network earnings."
        }
        return "Waiting for wallet eligibility."
    }

    var walletBalanceNote: String {
        earningEligible
            ? "This is the live gateway-backed device wallet balance."
            : "This is the live gateway-backed device wallet balance. Earnings start only after relay connectivity, a loaded model, and an aligned device identity."
    }

    var sessionNote: String {
        earningEligible
            ? "Session tokens reflect local serving. Gateway credits land in this wallet when routed Teale requests use this device."
            : "Session tokens reflect local serving only. They do not guarantee gateway wallet earnings until eligibility is green."
    }

    var supplyWalletNote: String {
        earningEligible
            ? "Open Wallet to watch the gateway-backed device balance update."
            : "Open Wallet to verify gateway eligibility before expecting the device balance to move."
    }
}

private struct CompanionModelPricing {
    let promptUSDPerToken: Double
    let completionUSDPerToken: Double
}

private let companionModelPricingByID: [String: CompanionModelPricing] = [
    "meta-llama/llama-3.2-1b-instruct": .init(promptUSDPerToken: 0.00000002, completionUSDPerToken: 0.00000004),
    "meta-llama/llama-3.2-3b-instruct": .init(promptUSDPerToken: 0.00000004, completionUSDPerToken: 0.00000008),
    "google/gemma-3-4b-it": .init(promptUSDPerToken: 0.00000008, completionUSDPerToken: 0.00000016),
    "nousresearch/hermes-3-llama-3.1-8b": .init(promptUSDPerToken: 0.00000010, completionUSDPerToken: 0.00000020),
    "meta-llama/llama-3.1-8b-instruct": .init(promptUSDPerToken: 0.00000010, completionUSDPerToken: 0.00000020),
    "qwen/qwen3-8b": .init(promptUSDPerToken: 0.00000010, completionUSDPerToken: 0.00000020),
    "mistralai/mistral-small-24b-instruct-2501": .init(promptUSDPerToken: 0.00000040, completionUSDPerToken: 0.00000080),
    "mistralai/mistral-small-3.2-24b-instruct": .init(promptUSDPerToken: 0.00000040, completionUSDPerToken: 0.00000080),
    "microsoft/phi-4": .init(promptUSDPerToken: 0.00000020, completionUSDPerToken: 0.00000040),
    "google/gemma-3-27b-it": .init(promptUSDPerToken: 0.00000040, completionUSDPerToken: 0.00000080),
    "qwen/qwen3-32b": .init(promptUSDPerToken: 0.00000030, completionUSDPerToken: 0.00000060),
    "meta-llama/llama-4-scout": .init(promptUSDPerToken: 0.00000080, completionUSDPerToken: 0.00000160),
    "qwen/qwen3.6-27b": .init(promptUSDPerToken: 0.00000025, completionUSDPerToken: 0.00000050),
    "qwen/qwen3.6-35b-a3b": .init(promptUSDPerToken: 0.00000030, completionUSDPerToken: 0.00000060),
    "deepseek/deepseek-v3.2": .init(promptUSDPerToken: 0.00000025, completionUSDPerToken: 0.00000050),
    "zai/glm-5.1": .init(promptUSDPerToken: 0.00000025, completionUSDPerToken: 0.00000050),
    "moonshotai/kimi-k2": .init(promptUSDPerToken: 0.00000035, completionUSDPerToken: 0.00000070),
    "moonshotai/kimi-k2.6": .init(promptUSDPerToken: 0.00000050, completionUSDPerToken: 0.00000100),
]

extension AppState {
    @MainActor
    var companionLiveNetworkModels: [CompanionNetworkModelSummary] {
        var counts: [String: Int] = [:]

        for peer in clusterManager.topology.connectedPeers where peer.status == .connected {
            for modelID in peer.loadedModels {
                counts[modelID, default: 0] += 1
            }
        }

        for peer in wanManager.state.connectedPeers {
            for modelID in peer.loadedModels {
                counts[modelID, default: 0] += 1
            }
        }

        return counts.map { id, deviceCount in
            let pricing = companionModelPricingByID[id]
            return CompanionNetworkModelSummary(
                id: id,
                deviceCount: deviceCount,
                promptUSDPerToken: pricing?.promptUSDPerToken,
                completionUSDPerToken: pricing?.completionUSDPerToken
            )
        }
        .sorted { left, right in
            if left.deviceCount != right.deviceCount {
                return left.deviceCount > right.deviceCount
            }
            let leftCompletion = left.completionUSDPerToken ?? .greatestFiniteMagnitude
            let rightCompletion = right.completionUSDPerToken ?? .greatestFiniteMagnitude
            if leftCompletion != rightCompletion {
                return leftCompletion < rightCompletion
            }
            return left.id < right.id
        }
    }

    @MainActor
    var companionDisplayUnitTitle: String {
        companionDisplayUnit == .credits ? "Teale credits" : "USD"
    }

    @MainActor
    var companionEarnedTitle: String {
        companionDisplayUnit == .credits ? "Total credits earned" : "Total USD earned"
    }

    @MainActor
    var companionSpentTitle: String {
        companionDisplayUnit == .credits ? "Total credits spent" : "Total USD spent"
    }

    @MainActor
    var companionDisplayAmountPlaceholder: String {
        companionDisplayUnit == .credits ? "0" : "0.00"
    }

    @MainActor
    var companionDisplaySpendUnitLabel: String {
        companionDisplayUnit.spendLabel
    }

    @MainActor
    func companionDisplayAmountString(amount: USDCAmount, includeUnit: Bool = true) -> String {
        if companionDisplayUnit == .credits {
            let credits = Int64((amount.value * CompanionDisplayUnit.creditsPerUSD).rounded())
            return companionDisplayAmountString(credits: credits, includeUnit: includeUnit)
        }
        return companionDisplayUSDString(amount.value, includeUnit: includeUnit)
    }

    @MainActor
    func companionDisplayAmountString(credits: Int, includeUnit: Bool = true, compact: Bool = false) -> String {
        companionDisplayAmountString(credits: Int64(credits), includeUnit: includeUnit, compact: compact)
    }

    @MainActor
    func companionDisplayAmountString(credits: Int64, includeUnit: Bool = true, compact: Bool = false) -> String {
        if companionDisplayUnit == .credits {
            let value = compact ? companionCompactCreditsLabel(credits) : companionCreditsLabel(credits)
            return includeUnit ? "\(value) credits" : value
        }
        return companionDisplayUSDString(Double(credits) / CompanionDisplayUnit.creditsPerUSD, includeUnit: includeUnit)
    }

    @MainActor
    func companionDisplayPricePerMillionLabel(promptUSDPerToken: Double?, completionUSDPerToken: Double?) -> String? {
        guard let promptUSDPerToken, let completionUSDPerToken else { return nil }
        if companionDisplayUnit == .credits {
            let promptCredits = Int64((promptUSDPerToken * CompanionDisplayUnit.creditsPerUSD * 1_000_000).rounded())
            let completionCredits = Int64((completionUSDPerToken * CompanionDisplayUnit.creditsPerUSD * 1_000_000).rounded())
            return "\(companionCompactCreditsLabel(promptCredits))i/\(companionCompactCreditsLabel(completionCredits))o/1M"
        }
        return "\(companionUSDPerMillionString(promptUSDPerToken))i/\(companionUSDPerMillionString(completionUSDPerToken))o/1M"
    }

    @MainActor
    func companionShortModelLabel(_ identifier: String) -> String {
        let last = identifier.split(separator: "/").last.map(String.init) ?? identifier
        return last.replacingOccurrences(of: "-", with: " ")
    }

    @MainActor
    func companionParseDisplayAmountToCredits(_ rawValue: String) -> Int? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if companionDisplayUnit == .credits {
            guard trimmed.allSatisfy(\.isNumber), let value = Int(trimmed), value > 0 else {
                return nil
            }
            return value
        }

        let normalized = trimmed.replacingOccurrences(of: ",", with: "")
        guard let value = Double(normalized), value > 0 else { return nil }
        let credits = Int((value * CompanionDisplayUnit.creditsPerUSD).rounded())
        return credits > 0 ? credits : nil
    }

    @MainActor
    private func companionCreditsLabel(_ credits: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: credits)) ?? String(credits)
    }

    @MainActor
    private func companionCompactCreditsLabel(_ credits: Int64) -> String {
        let absValue = abs(Double(credits))
        if absValue >= 1_000_000 {
            return "\(max(1, Int((Double(credits) / 1_000_000).rounded())))M"
        }
        if absValue >= 1_000 {
            return "\(max(1, Int((Double(credits) / 1_000).rounded())))K"
        }
        return String(max(0, Int(Double(credits).rounded())))
    }

    @MainActor
    private func companionDisplayUSDString(_ usd: Double, includeUnit: Bool) -> String {
        let formatted: String
        if usd >= 1 {
            formatted = String(format: "$%.2f", usd)
        } else {
            formatted = String(format: "$%.4f", usd)
        }
        return includeUnit ? "\(formatted) USD" : formatted
    }

    @MainActor
    private func companionUSDPerMillionString(_ usdPerToken: Double) -> String {
        let usdPerMillion = usdPerToken * 1_000_000
        if usdPerMillion >= 1 {
            return String(format: "$%.2f", usdPerMillion)
        }
        if usdPerMillion >= 0.01 {
            return String(format: "$%.3f", usdPerMillion)
        }
        return String(format: "$%.4f", usdPerMillion)
    }
}
