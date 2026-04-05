import SwiftUI
import SharedTypes

struct ModelBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header with search
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models...", text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary)

            Divider()

            // Model list
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(filteredModels) { model in
                        ModelRowView(model: model)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                }
            }

            Divider()

            // Footer with cache info
            HStack {
                Text("\(appState.modelManager.compatibleModels.count) models available for your hardware")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(appState.hardware.availableRAMForModelsGB)) GB available")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .navigationTitle("Models")
    }

    private var filteredModels: [ModelDescriptor] {
        let models = appState.modelManager.compatibleModels
        if searchText.isEmpty { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.family.localizedCaseInsensitiveContains(searchText)
        }
    }
}

// MARK: - Model Row

struct ModelRowView: View {
    @Environment(AppState.self) private var appState
    let model: ModelDescriptor
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        HStack(spacing: 12) {
            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(model.name)
                        .font(.body.bold())
                    if isCurrentlyLoaded {
                        Text("LOADED")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.2))
                            .foregroundStyle(.green)
                            .clipShape(Capsule())
                    }
                }

                Text(model.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label(model.parameterCount, systemImage: "cpu")
                    Label(model.quantization.displayName, systemImage: "slider.horizontal.3")
                    Label(String(format: "%.1f GB", model.estimatedSizeGB), systemImage: "externaldrive")
                    Label(String(format: "%.0f GB RAM", model.requiredRAMGB), systemImage: "memorychip")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            // Actions
            VStack(alignment: .trailing, spacing: 4) {
                if isCurrentlyLoaded {
                    Button("Unload") {
                        Task { await appState.unloadModel() }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if isDownloading {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let progress = appState.loadingProgress, progress > 0 && progress < 1.0 {
                            ProgressView(value: progress)
                                .frame(width: 80)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(appState.loadingPhase.isEmpty ? "Loading…" : appState.loadingPhase)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(minWidth: 90)
                } else {
                    Button("Load") {
                        Task { await loadModel() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }

        if let error = downloadError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var isCurrentlyLoaded: Bool {
        appState.selectedModel?.id == model.id
    }

    private func loadModel() async {
        isDownloading = true
        downloadError = nil
        await appState.loadModel(model)
        isDownloading = false

        if case .error(let msg) = appState.engineStatus {
            downloadError = msg
        }
    }
}
