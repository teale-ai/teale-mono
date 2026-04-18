import SwiftUI
import SharedTypes

// MARK: - Local Models View

/// Model browser for downloading and loading models on-device.
struct LocalModelsView: View {
    @Environment(CompanionAppState.self) private var appState

    var body: some View {
        List {
            // Device info
            Section {
                HStack {
                    Label(appState.hardware.chipName, systemImage: "cpu")
                    Spacer()
                    Text("\(Int(appState.hardware.totalRAMGB)) GB RAM")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Label("Available for models", systemImage: "memorychip")
                    Spacer()
                    Text("\(Int(appState.hardware.availableRAMForModelsGB)) GB")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Device")
            }

            // Currently loaded model
            if let loaded = appState.localModel {
                Section {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(loaded.name)
                                .font(.headline)
                            Text("\(loaded.parameterCount) \(loaded.quantization.displayName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unload") {
                            Task { await appState.unloadLocalModel() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                    }
                } header: {
                    Text("Loaded Model")
                }
            }

            // Loading indicator
            if appState.isLoadingModel {
                Section {
                    VStack(spacing: 8) {
                        if let progress = appState.loadingProgress, progress > 0 && progress < 1.0 {
                            ProgressView(value: progress)
                            Text("\(appState.loadingPhase) — \(Int(progress * 100))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView()
                            Text(appState.loadingPhase.isEmpty ? "Preparing..." : appState.loadingPhase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Loading")
                }
            }

            // Available models
            Section {
                ForEach(appState.modelManager.compatibleModels) { model in
                    ModelCell(model: model)
                }
            } header: {
                Text("Compatible Models")
            } footer: {
                Text("Models are downloaded from HuggingFace and run locally on your device using Apple's MLX framework.")
            }
        }
        .navigationTitle("On-Device Models")
        .task {
            await appState.refreshDownloadedModels()
        }
    }
}

// MARK: - Model Cell

private struct ModelCell: View {
    @Environment(CompanionAppState.self) private var appState
    let model: ModelDescriptor

    private var isDownloaded: Bool {
        appState.downloadedModelIDs.contains(model.id)
    }

    private var isDownloading: Bool {
        appState.activeDownloads[model.id] != nil
    }

    private var isLoaded: Bool {
        appState.localModel?.id == model.id
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(model.name)
                    .font(.body.weight(.medium))
                Spacer()
                if isLoaded {
                    Text("LOADED")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.2))
                        .foregroundStyle(.green)
                        .clipShape(Capsule())
                } else if isDownloaded {
                    Text("READY")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(.secondary.opacity(0.2))
                        .foregroundStyle(.secondary)
                        .clipShape(Capsule())
                }
            }

            Text(model.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Label(model.parameterCount, systemImage: "cpu")
                Label(model.quantization.displayName, systemImage: "slider.horizontal.3")
                Label(String(format: "%.1f GB", model.estimatedSizeGB), systemImage: "arrow.down.circle")
                Label(String(format: "%.0f GB", model.requiredRAMGB), systemImage: "memorychip")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            // Action
            if isLoaded {
                // Already loaded, no action needed
            } else if isDownloading {
                if let progress = appState.activeDownloads[model.id] {
                    ProgressView(value: progress)
                    Text("Downloading... \(Int(progress * 100))%")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else if isDownloaded {
                Button {
                    Task { await appState.loadLocalModel(model) }
                } label: {
                    Label("Load into Memory", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            } else {
                Button {
                    Task { await appState.downloadModel(model) }
                } label: {
                    Label("Download (\(String(format: "%.1f", model.estimatedSizeGB)) GB)", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
