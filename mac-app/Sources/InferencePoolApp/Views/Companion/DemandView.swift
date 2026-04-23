import SwiftUI
import AppCore
import SharedTypes
import ModelManager
import AppKit

struct CompanionDemandView: View {
    @Environment(AppState.self) private var appState

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
        TealeSection(prompt: "local inference") {
            TealeStats {
                TealeStatRow(label: "Base URL", value: localBaseURL)
                TealeStatRow(label: "Model", value: localModelID)
            }
            TealeCodeBlock(text: localCurlSnippet)
                .padding(.top, 10)
            HStack {
                TealeActionButton(title: "Copy local curl") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(localCurlSnippet, forType: .string)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: teale network models

    private var networkModelsSection: some View {
        TealeSection(prompt: "teale network models") {
            let rows = appState.modelManager.catalog.availableModels(for: appState.hardware)
            if rows.isEmpty {
                Text("Loading live gateway models...")
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

    private var gatewayBase: String { appState.gatewayFallbackURL }

    private var networkCurlSnippet: String {
        let token = appState.gatewayAPIKey.isEmpty ? "$GATEWAY_TOKEN" : appState.gatewayAPIKey
        return """
        curl \(gatewayBase)/v1/chat/completions \\
          -H "Authorization: Bearer \(token)" \\
          -H "Content-Type: application/json" \\
          -d '{
            "model": "\(appState.companionSelectedGatewayModel)",
            "messages": [{"role":"user","content":"Hi"}]
          }'
        """
    }

    private var networkSection: some View {
        TealeSection(prompt: "teale network") {
            TealeStats {
                TealeStatRow(label: "Base URL", value: gatewayBase)
                TealeStatRow(
                    label: "Bearer",
                    value: appState.companionGatewayBearerLabel,
                    note: "Requests deduct from Teale credits once a gateway bearer is configured."
                )
                TealeStatRow(label: "Selected", value: appState.companionSelectedGatewayModel)
            }
            TealeCodeBlock(text: networkCurlSnippet)
                .padding(.top, 10)
            HStack(spacing: 10) {
                TealeActionButton(title: "Copy bearer token") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.gatewayAPIKey, forType: .string)
                }
                TealeActionButton(title: "Copy network curl") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(networkCurlSnippet, forType: .string)
                }
            }
            .padding(.top, 6)
        }
    }
}

private struct NetworkModelRow: View {
    let model: ModelDescriptor

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                    .font(TealeDesign.mono)
                    .foregroundStyle(TealeDesign.text)
                Text(model.openrouterId ?? model.huggingFaceRepo)
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.parameterCount) · \(model.family)")
                    .font(TealeDesign.monoTiny)
                    .foregroundStyle(TealeDesign.muted)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Rectangle().stroke(TealeDesign.border.opacity(0.6), lineWidth: 1))
    }
}
