import SwiftUI
import AppCore
import SharedTypes
import ModelManager
import GatewayKit

struct CompanionSupplyView: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState
    let onNavigate: (CompanionTab) -> Void

    private let availabilityTickSeconds: Int64 = 1
    private let hermesReferencePromptUSD: Double = 0.00000010
    private let hermesReferenceCompletionUSD: Double = 0.00000020

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusSection
            earningsSection
            recommendedSection
            if !appState.activeDownloads.isEmpty {
                transferSection
            }
            catalogSection
        }
    }

    // MARK: status

    private var statusSection: some View {
        TealeSection(prompt: appState.companionText("supply.status", fallback: "status")) {
            TealeStats {
                TealeStatRow(
                    label: appState.companionText("common.state", fallback: "State"),
                    value: appState.companionState.displayText,
                    note: appState.companionState.statusLine,
                    valueColor: appState.companionState.chipColor
                )
                TealeStatRow(label: appState.companionText("supply.machine", fallback: "Machine"), value: appState.companionDeviceName)
                TealeStatRow(label: appState.companionText("supply.ram", fallback: "RAM"), value: appState.companionRAMLabel)
                TealeStatRow(label: appState.companionText("supply.backend", fallback: "Backend"), value: appState.companionBackendLabel)
                TealeStatRow(label: appState.companionText("supply.power", fallback: "Power"), value: appState.companionPowerLabel)
                TealeStatRow(
                    label: appState.companionText("common.model", fallback: "Model"),
                    value: appState.engineStatus.currentModel?.name ?? appState.companionText("common.noModelLoaded", fallback: "No model loaded")
                )
                TealeStatRow(
                    label: appState.companionText("wallet.relay", fallback: "Relay"),
                    value: appState.companionSupplyIdentityStatus.relayLabel,
                    note: "WAN node \(companionTruncatedIdentifier(appState.companionSupplyIdentityStatus.wanNodeID)) · identity \(appState.companionSupplyIdentityStatus.identityLabel)"
                )
                TealeStatRow(
                    label: appState.companionText("wallet.gatewayEligibility", fallback: "Gateway eligibility"),
                    value: appState.companionSupplyIdentityStatus.eligibilityLabel,
                    note: appState.companionSupplyIdentityStatus.summary
                )
            }
            if appState.engineStatus.isReady || appState.engineStatus.isGenerating {
                HStack(spacing: 10) {
                    TealeActionButton(title: appState.companionText("supply.unloadCurrent", fallback: "Unload current model")) {
                        Task { await appState.unloadModel() }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: earnings

    private var earningsSection: some View {
        TealeSection(prompt: appState.companionText("supply.earnings", fallback: "earnings")) {
            TealeStats {
                TealeStatRow(
                    label: appState.companionText("supply.availability", fallback: "Availability"),
                    value: availabilityRate,
                    note: appState.companionText(
                        "supply.availabilityNote",
                        fallback: "This is the projected gateway availability rate once relay connectivity and identity alignment are in place."
                    )
                )
                TealeStatRow(
                    label: appState.companionText("supply.servedInference", fallback: "Served inference"),
                    value: appState.companionText("supply.servedSplitValue", fallback: "95% / 5%"),
                    note: appState.companionText(
                        "supply.servedSplitNote",
                        fallback: "95% goes to this device and 5% goes to Teale when this machine serves the request."
                    )
                )
                TealeStatRow(label: appState.companionText("supply.session", fallback: "Session"), value: "\(appState.totalTokensGenerated) tokens served")
                TealeStatRow(
                    label: appState.companionText("common.wallet", fallback: "Wallet"),
                    value: gatewayWalletLabel,
                    note: appState.companionSupplyIdentityStatus.supplyWalletNote
                )
            }
            HStack {
                TealeActionButton(title: appState.companionText("supply.openWallet", fallback: "Open wallet"), primary: true) {
                    onNavigate(.wallet)
                }
            }
            .padding(.top, 4)
        }
    }

    private var availabilityRate: String {
        guard appState.companionSupplyIdentityStatus.localServingReady else {
            return appState.companionText("supply.waitingLoadedModel", fallback: "Waiting for a loaded model...")
        }
        guard let perTickCredits = availabilityCreditsPerTick else {
            return appState.companionText("supply.waitingPricing", fallback: "Waiting for live network pricing...")
        }

        let amount = appState.companionDisplayAmountString(
            credits: perTickCredits,
            includeUnit: true,
            compact: appState.companionDisplayUnit == .credits
        )
        if availabilityTickSeconds == 1 {
            return "+\(amount) / sec"
        }
        return "+\(amount) / \(availabilityTickSeconds) sec"
    }

    private var availabilityCreditsPerTick: Int64? {
        guard let prompt = loadedModelSummary?.promptUSDPerToken,
              let completion = loadedModelSummary?.completionUSDPerToken else {
            return nil
        }

        let combinedPrice = max(0, prompt) + max(0, completion)
        let reference = hermesReferencePromptUSD + hermesReferenceCompletionUSD
        guard reference > 0 else { return nil }
        if combinedPrice <= 0 {
            return 1
        }
        return max(1, Int64((combinedPrice / reference).rounded()))
    }

    private var gatewayWalletLabel: String {
        if let balanceCredits = gatewayState.walletBalance?.balanceCredits {
            return appState.companionDisplayAmountString(credits: balanceCredits)
        }
        return companionTruncatedIdentifier(GatewayIdentity.shared.deviceID)
    }

    private var loadedModelSummary: CompanionNetworkModelSummary? {
        guard let currentModel = appState.engineStatus.currentModel else { return nil }
        return gatewayState.networkModels.first { candidate in
            currentModel.matchesIdentifier(candidate.id)
        }
    }

    // MARK: recommended

    private var recommendedSection: some View {
        TealeSection(prompt: appState.companionText("supply.recommended", fallback: "recommended")) {
            let recommendations = recommendedModels
            if recommendations.isEmpty {
                TealeStats {
                    TealeStatRow(label: appState.companionText("common.model", fallback: "Model"), value: appState.companionText("supply.noCompatibleModel", fallback: "No compatible model found"))
                    TealeStatRow(label: "Fit", value: appState.companionText("supply.machineDoesNotFit", fallback: "This machine doesn't fit the catalog."))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(recommendations) { recommendation in
                        RecommendationCard(recommendation: recommendation)
                    }
                }
            }
        }
    }

    private var recommendedModels: [SupplyRecommendation] {
        var items: [SupplyRecommendation] = []

        if let highestDemand = appState.companionHighestDemandModel() {
            items.append(
                SupplyRecommendation(
                    label: appState.companionText("supply.highestDemand", fallback: "Highest demand"),
                    detail: appState.companionText("supply.highestDemandDetail", fallback: "Matches the current demand ranking."),
                    model: highestDemand
                )
            )
        }

        if let largestFit = appState.companionLargestFitModel(),
           !items.contains(where: { $0.model.id == largestFit.id }) {
            items.append(
                SupplyRecommendation(
                    label: appState.companionText("supply.largestFit", fallback: "Largest fit"),
                    detail: appState.companionText("supply.largestFitDetail", fallback: "Uses the biggest catalog model this Mac can keep in memory."),
                    model: largestFit
                )
            )
        }

        return items
    }

    // MARK: transfer

    private var transferSection: some View {
        TealeSection(prompt: appState.companionText("supply.transfer", fallback: "transfer")) {
            ForEach(Array(appState.activeDownloads.keys.sorted()), id: \.self) { modelID in
                let fraction = appState.activeDownloads[modelID] ?? 0
                let name = ModelCatalog.allModels.first(where: { $0.id == modelID })?.name ?? modelID
                VStack(alignment: .leading, spacing: 6) {
                    TealeStatRow(
                        label: name,
                        value: "\(Int(fraction * 100))%",
                        note: appState.companionText("supply.fetchingWeights", fallback: "Fetching weights from HuggingFace")
                    )
                    ProgressView(value: fraction)
                        .tint(TealeDesign.teale)
                }
                .padding(.bottom, 4)
            }
        }
    }

    // MARK: catalog

    private var catalogSection: some View {
        TealeSection(prompt: appState.companionText("supply.catalog", fallback: "catalog")) {
            let models = appState.modelManager.catalog.availableModels(for: appState.hardware)
            if models.isEmpty {
                Text(appState.companionText("supply.noCompatibleModelsYet", fallback: "No compatible models are available for this device yet."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(models, id: \.id) { model in
                        CatalogRow(model: model)
                    }
                }
            }
        }
    }
}

private struct CatalogRow: View {
    @Environment(AppState.self) private var appState
    let model: ModelDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text("\(model.parameterCount) · \(Int(model.estimatedSizeGB)) GB · needs \(Int(model.requiredRAMGB)) GB · \(model.family) · demand #\(model.popularityRank)")
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
                Text(statusLine)
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.teale)
            }
            Spacer(minLength: 8)
            TealeActionButton(
                title: buttonLabel,
                primary: appState.engineStatus.currentModel?.id != model.id,
                disabled: buttonDisabled
            ) {
                buttonTap()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.45))
        .overlay(Rectangle().stroke(TealeDesign.border, lineWidth: 1))
    }

    private var statusLine: String {
        if appState.engineStatus.currentModel?.id == model.id { return "Serving now" }
        if appState.downloadedModelIDs.contains(model.id) { return "Downloaded" }
        if appState.activeDownloads[model.id] != nil {
            let pct = Int((appState.activeDownloads[model.id] ?? 0) * 100)
            return "Downloading \(pct)%"
        }
        return "Available"
    }

    private var buttonLabel: String {
        if appState.engineStatus.currentModel?.id == model.id { return "Serving" }
        if appState.downloadedModelIDs.contains(model.id) { return "Load" }
        if appState.activeDownloads[model.id] != nil { return "Downloading" }
        return "Download"
    }

    private var buttonDisabled: Bool {
        appState.engineStatus.currentModel?.id == model.id
            || appState.activeDownloads[model.id] != nil
    }

    private func buttonTap() {
        if appState.downloadedModelIDs.contains(model.id) {
            Task { await appState.loadModel(model) }
        } else {
            Task { await appState.downloadModel(model) }
        }
    }
}

private struct SupplyRecommendation: Identifiable {
    let label: String
    let detail: String
    let model: ModelDescriptor

    var id: String {
        "\(label)-\(model.id)"
    }
}

private struct RecommendationCard: View {
    @Environment(AppState.self) private var appState
    let recommendation: SupplyRecommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(recommendation.label.uppercased())
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.teale)
                .tracking(0.8)

            Text(recommendation.detail)
                .font(TealeDesign.monoSmall)
                .foregroundStyle(TealeDesign.muted)

            TealeStats {
                TealeStatRow(label: "Model", value: recommendation.model.name)
                TealeStatRow(
                    label: "Fit",
                    value: "\(Int(recommendation.model.estimatedSizeGB)) GB · needs \(Int(recommendation.model.requiredRAMGB)) GB RAM · you have \(Int(appState.hardware.totalRAMGB)) GB"
                )
                TealeStatRow(label: "Action", value: actionLabel)
            }

            HStack(spacing: 10) {
                TealeActionButton(
                    title: buttonLabel,
                    primary: true,
                    disabled: isButtonDisabled
                ) {
                    buttonTap()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.45))
        .overlay(Rectangle().stroke(TealeDesign.border, lineWidth: 1))
    }

    private var actionLabel: String {
        if appState.downloadedModelIDs.contains(recommendation.model.id) {
            if appState.engineStatus.currentModel?.id == recommendation.model.id {
                return "Serving now"
            }
            return "Load from disk"
        }
        if appState.activeDownloads[recommendation.model.id] != nil {
            return "Downloading"
        }
        return "Download and start supplying"
    }

    private var buttonLabel: String {
        if appState.engineStatus.currentModel?.id == recommendation.model.id { return "Serving now" }
        if appState.downloadedModelIDs.contains(recommendation.model.id) { return "Load and start supplying" }
        if appState.activeDownloads[recommendation.model.id] != nil {
            let pct = Int((appState.activeDownloads[recommendation.model.id] ?? 0) * 100)
            return "Downloading \(pct)%"
        }
        return "Download and start supplying"
    }

    private var isButtonDisabled: Bool {
        appState.engineStatus.currentModel?.id == recommendation.model.id
            || appState.activeDownloads[recommendation.model.id] != nil
    }

    private func buttonTap() {
        if appState.downloadedModelIDs.contains(recommendation.model.id) {
            Task { await appState.loadModel(recommendation.model) }
        } else {
            Task { await appState.downloadModel(recommendation.model) }
        }
    }
}
