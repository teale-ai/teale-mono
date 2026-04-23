import SwiftUI
import AppCore
import SharedTypes
import ModelManager

struct CompanionSupplyView: View {
    @Environment(AppState.self) private var appState
    let onNavigate: (CompanionTab) -> Void

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
        TealeSection(prompt: "status") {
            TealeStats {
                TealeStatRow(
                    label: "State",
                    value: appState.companionState.displayText,
                    note: appState.companionState.statusLine,
                    valueColor: appState.companionState.chipColor
                )
                TealeStatRow(label: "Machine", value: appState.companionDeviceName)
                TealeStatRow(label: "RAM", value: appState.companionRAMLabel)
                TealeStatRow(label: "Backend", value: appState.companionBackendLabel)
                TealeStatRow(label: "Power", value: appState.companionPowerLabel)
                TealeStatRow(
                    label: "Model",
                    value: appState.engineStatus.currentModel?.name ?? "No model loaded"
                )
            }
            if appState.engineStatus.isReady || appState.engineStatus.isGenerating {
                HStack(spacing: 10) {
                    TealeActionButton(title: "Unload current model") {
                        Task { await appState.unloadModel() }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: earnings

    private var earningsSection: some View {
        TealeSection(prompt: "earnings") {
            TealeStats {
                TealeStatRow(label: "Rate", value: earningRate)
                TealeStatRow(label: "Session", value: "\(appState.totalTokensGenerated) tokens served")
                TealeStatRow(
                    label: "Wallet",
                    value: appState.wallet.balance.description,
                    note: "The wallet view shows the balance grow in real time."
                )
            }
            HStack {
                TealeActionButton(title: "Open wallet", primary: true) {
                    onNavigate(.wallet)
                }
            }
            .padding(.top, 4)
        }
    }

    private var earningRate: String {
        guard appState.engineStatus.isReady || appState.engineStatus.isGenerating else {
            return "Waiting for a loaded model..."
        }
        return "Earning while serving"
    }

    // MARK: recommended

    private var recommendedSection: some View {
        TealeSection(prompt: "recommended") {
            if let rec = appState.companionRecommendedModel() {
                TealeStats {
                    TealeStatRow(label: "Model", value: rec.name)
                    TealeStatRow(
                        label: "Fit",
                        value: "\(Int(rec.estimatedSizeGB)) GB · needs \(Int(rec.requiredRAMGB)) GB RAM · you have \(Int(appState.hardware.totalRAMGB)) GB"
                    )
                    TealeStatRow(label: "Action", value: recommendedActionLabel(for: rec))
                }
                HStack(spacing: 10) {
                    TealeActionButton(
                        title: recommendedButtonLabel(for: rec),
                        primary: true,
                        disabled: recommendedButtonDisabled(for: rec)
                    ) {
                        recommendedButtonTap(for: rec)
                    }
                }
                .padding(.top, 4)
            } else {
                TealeStats {
                    TealeStatRow(label: "Model", value: "No compatible model found")
                    TealeStatRow(label: "Fit", value: "This machine doesn't fit the catalog — need more RAM.")
                }
            }
        }
    }

    private func recommendedActionLabel(for rec: ModelDescriptor) -> String {
        if appState.downloadedModelIDs.contains(rec.id) {
            if appState.engineStatus.currentModel?.id == rec.id {
                return "Serving now"
            }
            return "Load from disk"
        }
        if appState.activeDownloads[rec.id] != nil {
            return "Downloading"
        }
        return "Download and start supplying"
    }

    private func recommendedButtonLabel(for rec: ModelDescriptor) -> String {
        if appState.engineStatus.currentModel?.id == rec.id { return "Serving now" }
        if appState.downloadedModelIDs.contains(rec.id) { return "Load and start supplying" }
        if appState.activeDownloads[rec.id] != nil {
            let pct = Int((appState.activeDownloads[rec.id] ?? 0) * 100)
            return "Downloading \(pct)%"
        }
        return "Download and start supplying"
    }

    private func recommendedButtonDisabled(for rec: ModelDescriptor) -> Bool {
        appState.engineStatus.currentModel?.id == rec.id
            || appState.activeDownloads[rec.id] != nil
    }

    private func recommendedButtonTap(for rec: ModelDescriptor) {
        if appState.downloadedModelIDs.contains(rec.id) {
            Task { await appState.loadModel(rec) }
        } else {
            Task { await appState.downloadModel(rec) }
        }
    }

    // MARK: transfer

    private var transferSection: some View {
        TealeSection(prompt: "transfer") {
            ForEach(Array(appState.activeDownloads.keys.sorted()), id: \.self) { modelID in
                let fraction = appState.activeDownloads[modelID] ?? 0
                let name = ModelCatalog.allModels.first(where: { $0.id == modelID })?.name ?? modelID
                VStack(alignment: .leading, spacing: 6) {
                    TealeStatRow(
                        label: name,
                        value: "\(Int(fraction * 100))%",
                        note: "Fetching weights from HuggingFace"
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
        TealeSection(prompt: "catalog") {
            let models = appState.modelManager.catalog.availableModels(for: appState.hardware)
            if models.isEmpty {
                Text("No compatible models for this device yet.")
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
                Text("\(model.parameterCount) · \(Int(model.estimatedSizeGB)) GB · needs \(Int(model.requiredRAMGB)) GB · \(model.family)")
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
