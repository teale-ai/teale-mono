import SwiftUI
import AppCore
import SharedTypes
import ModelManager
import AppKit

struct CompanionDemandView: View {
    @Environment(AppState.self) private var appState
    @Environment(CompanionGatewayState.self) private var gatewayState
    @State private var bearerCopied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            localSection
            networkModelsSection
            networkSection
        }
    }

    // MARK: local

    private var localBaseURL: String {
        "http://127.0.0.1:\(appState.serverPort)"
    }

    private var localModelID: String {
        appState.engineStatus.currentModel?.openrouterId
            ?? appState.engineStatus.currentModel?.name
            ?? "No local model loaded"
    }

    private var localCurlSnippet: String {
        guard let modelID = appState.engineStatus.currentModel?.openrouterId
            ?? appState.engineStatus.currentModel?.huggingFaceRepo else {
            return "Waiting for a local model..."
        }
        return """
        curl \(localBaseURL)/v1/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{
            "model": "\(modelID)",
            "messages": [{"role":"user","content":"Hi"}]
          }'
        """
    }

    private var localSection: some View {
        TealeSection(prompt: appState.companionText("demand.local", fallback: "local inference")) {
            TealeStats {
                TealeStatRow(label: appState.companionText("demand.baseURL", fallback: "Base URL"), value: localBaseURL)
                TealeStatRow(label: appState.companionText("common.model", fallback: "Model"), value: localModelID)
            }
            TealeCodeBlock(text: localCurlSnippet)
                .padding(.top, 10)
            HStack {
                TealeActionButton(title: appState.companionText("demand.copyLocalCurl", fallback: "Copy local curl")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(localCurlSnippet, forType: .string)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: teale network models

    private var networkModelsSection: some View {
        TealeSection(prompt: appState.companionText("demand.networkModels", fallback: "teale network models")) {
            let rows = gatewayState.networkModels
            if rows.isEmpty {
                Text(appState.companionText("demand.noLiveModels", fallback: "No live network model data yet."))
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(rows, id: \.id) { model in
                        NetworkModelRow(model: model)
                    }
                }
            }
        }
    }

    // MARK: teale network (curl)

    private var gatewayBase: String { companionGatewayAPIBaseURL(for: appState.gatewayFallbackURL).absoluteString }

    private var networkCurlSnippet: String {
        return """
        curl \(gatewayBase)/chat/completions \\
          -H "Authorization: Bearer $TEALE_API_KEY" \\
          -H "Content-Type: application/json" \\
          -d '{
            "model": "\(gatewayState.selectedNetworkModelID)",
            "messages": [{"role":"user","content":"Hi"}]
          }'
        """
    }

    private var networkSection: some View {
        TealeSection(prompt: appState.companionText("demand.network", fallback: "teale network")) {
            TealeStats {
                TealeStatRow(label: appState.companionText("demand.baseURL", fallback: "Base URL"), value: gatewayBase)
                bearerRow
                TealeStatRow(label: appState.companionText("demand.selected", fallback: "Selected"), value: gatewayState.selectedNetworkModelID)
            }
            TealeCodeBlock(text: networkCurlSnippet)
                .padding(.top, 10)
            HStack(spacing: 10) {
                TealeActionButton(title: appState.companionText("demand.copyBearer", fallback: "Copy device bearer")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(gatewayState.bearerToken, forType: .string)
                }
                TealeActionButton(title: appState.companionText("demand.copyNetworkCurl", fallback: "Copy network curl")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(networkCurlSnippet, forType: .string)
                }
            }
            .padding(.top, 6)
        }
    }

    private var bearerRow: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(appState.companionText("demand.bearer", fallback: "Device bearer").uppercased())
                .font(TealeDesign.monoSmall)
                .tracking(0.9)
                .foregroundStyle(TealeDesign.muted)
                .frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Button(action: copyBearer) {
                    Text(maskedBearer)
                        .font(TealeDesign.mono)
                        .foregroundStyle(gatewayState.bearerToken.isEmpty ? TealeDesign.muted : TealeDesign.teale)
                }
                .buttonStyle(.plain)
                .disabled(gatewayState.bearerToken.isEmpty)

                Text(bearerNote)
                    .font(TealeDesign.monoSmall)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 0)
        }
    }

    private var maskedBearer: String {
        guard !gatewayState.bearerToken.isEmpty else { return "..." }
        return "•••" + String(gatewayState.bearerToken.suffix(4))
    }

    private var bearerNote: String {
        if gatewayState.bearerToken.isEmpty {
            return appState.companionText(
                "demand.waitingBearer",
                fallback: "Waiting for the device bearer token from the gateway wallet sync."
            )
        }
        if bearerCopied {
            return appState.companionText("demand.bearerCopied", fallback: "Bearer token copied.")
        }
        return appState.companionText(
            "demand.requestsSpend",
            fallback: "This rotating device bearer is for Teale app transport and debugging. Use a human-account API key from Account for persistent direct gateway clients.",
            replacements: ["unit": appState.companionDisplaySpendUnitLabel]
        )
    }

    private func copyBearer() {
        guard !gatewayState.bearerToken.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(gatewayState.bearerToken, forType: .string)
        bearerCopied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            bearerCopied = false
        }
    }
}

private struct NetworkModelRow: View {
    @Environment(AppState.self) private var appState
    let model: CompanionNetworkModelSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(appState.companionShortModelLabel(model.id))
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text(model.id)
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.deviceCount) \(appState.companionText("demand.liveDevices", fallback: "live device(s)"))")
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
                if let pricing = appState.companionDisplayPricePerMillionLabel(
                    promptUSDPerToken: model.promptUSDPerToken,
                    completionUSDPerToken: model.completionUSDPerToken
                ) {
                    Text(pricing)
                        .font(TealeDesign.monoTiny)
                        .foregroundStyle(TealeDesign.teale)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }
}
