import SwiftUI
import SharedTypes

struct ModelBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var switchConfirmModel: ModelDescriptor?

    private var topModels: [ModelDescriptor] {
        appState.modelManager.catalog.topModels(for: appState.hardware)
    }

    private var otherModels: [ModelDescriptor] {
        let topIDs = Set(topModels.map(\.id))
        return filteredModels.filter { !topIDs.contains($0.id) }
    }

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

            // Model list with ranking sections
            ScrollView {
                LazyVStack(spacing: 1) {
                    // Top models section — only show when not searching
                    if searchText.isEmpty && !topModels.isEmpty {
                        sectionHeader(
                            title: "Most In-Demand",
                            subtitle: "Popular models on the network",
                            icon: "flame.fill",
                            color: .orange
                        )

                        ForEach(Array(topModels.enumerated()), id: \.element.id) { index, model in
                            HStack(spacing: 0) {
                                Text("#\(index + 1)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(.orange)
                                    .frame(width: 28, alignment: .center)

                                ModelRowView(
                                    model: model,
                                    onSwitchRequest: { switchConfirmModel = $0 }
                                )
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.orange.opacity(0.03))
                        }

                        sectionHeader(
                            title: "All Models",
                            subtitle: "Compatible with your \(appState.hardware.chipName)",
                            icon: "square.grid.2x2",
                            color: .secondary
                        )
                    }

                    ForEach(searchText.isEmpty ? otherModels : filteredModels) { model in
                        ModelRowView(
                            model: model,
                            onSwitchRequest: { switchConfirmModel = $0 }
                        )
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
        .alert("Switch Model?", isPresented: Binding(
            get: { switchConfirmModel != nil },
            set: { if !$0 { switchConfirmModel = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                switchConfirmModel = nil
            }
            Button("Switch") {
                if let model = switchConfirmModel {
                    switchConfirmModel = nil
                    Task { await appState.loadModel(model) }
                }
            }
        } message: {
            if let model = switchConfirmModel {
                Text("This will unload the current model and load \(model.name).")
            }
        }
        .alert("Download Complete", isPresented: Binding(
            get: { appState.justDownloadedModel != nil },
            set: { if !$0 { appState.justDownloadedModel = nil } }
        )) {
            Button("Not Now", role: .cancel) {
                appState.justDownloadedModel = nil
            }
            Button("Load") {
                if let model = appState.justDownloadedModel {
                    appState.justDownloadedModel = nil
                    Task { await appState.loadModel(model) }
                }
            }
        } message: {
            if let model = appState.justDownloadedModel {
                Text("\(model.name) is ready. Load it now? This will unload the current model.")
            }
        }
    }

    private func sectionHeader(title: String, subtitle: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.caption)
            Text(title)
                .font(.caption.weight(.semibold))
            Text("— \(subtitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.quaternary.opacity(0.5))
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
    var onSwitchRequest: (ModelDescriptor) -> Void
    @State private var error: String?

    private var isDownloaded: Bool {
        appState.downloadedModelIDs.contains(model.id)
    }

    private var isDownloading: Bool {
        appState.activeDownloads[model.id] != nil
    }

    private var downloadProgress: Double? {
        appState.activeDownloads[model.id]
    }

    private var isCurrentlyLoaded: Bool {
        if case .ready(let loaded) = appState.engineStatus {
            return loaded.id == model.id
        }
        return false
    }

    private var isCurrentlyLoading: Bool {
        if case .loadingModel(let loading) = appState.engineStatus {
            return loading.id == model.id
        }
        return false
    }

    /// Another model is currently loaded (not this one)
    private var hasOtherModelLoaded: Bool {
        if case .ready(let loaded) = appState.engineStatus {
            return loaded.id != model.id
        }
        return false
    }

    /// Engine is busy loading or generating
    private var isEngineOccupied: Bool {
        switch appState.engineStatus {
        case .loadingModel, .generating: return true
        default: return false
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            // Model info
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.name)
                        .font(.body.bold())
                    statusBadge
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
            actionView
        }

        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        if isCurrentlyLoaded {
            badge("LOADED", color: .green)
        } else if isCurrentlyLoading {
            let phase = appState.loadingPhase.lowercased()
            if phase.contains("verif") {
                badge("CHECKING", color: .yellow)
            } else {
                badge("LOADING", color: .blue)
            }
        } else if isDownloading {
            badge("DL", color: .orange)
        } else if isDownloaded {
            badge("READY", color: .secondary)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionView: some View {
        if isCurrentlyLoaded {
            // Loaded — offer unload
            Button("Unload") {
                Task { await appState.unloadModel() }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        } else if isCurrentlyLoading {
            // Loading weights into GPU
            VStack(alignment: .trailing, spacing: 3) {
                let phase = appState.loadingPhase.lowercased()
                let isWeightLoading = phase.contains("loading") || phase.contains("warming")
                if let progress = appState.loadingProgress,
                   progress > 0 && progress < 1.0 && !isWeightLoading {
                    ProgressView(value: progress)
                        .frame(width: 80)
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.loadingPhase.isEmpty ? "Preparing…" : appState.loadingPhase)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 90)

        } else if isDownloading {
            // Downloading files — show progress with size
            VStack(alignment: .trailing, spacing: 3) {
                if let progress = downloadProgress, progress > 0 && progress < 1.0 {
                    ProgressView(value: progress)
                        .frame(width: 100)
                    Text(downloadSizeText(progress: progress))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                        .controlSize(.small)
                    Text("Starting…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 110)

        } else if isDownloaded {
            // On disk — load into memory
            Button("Load") {
                if hasOtherModelLoaded || isEngineOccupied {
                    onSwitchRequest(model)
                } else {
                    Task {
                        error = nil
                        await appState.loadModel(model)
                        if case .error(let msg) = appState.engineStatus {
                            error = msg
                        }
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        } else {
            // Not downloaded — download only (no alert, no load)
            Button {
                Task {
                    error = nil
                    await appState.downloadModel(model)
                }
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func downloadSizeText(progress: Double) -> String {
        let totalGB = model.estimatedSizeGB
        let downloadedGB = totalGB * progress
        if totalGB < 1.0 {
            return String(format: "%.0f / %.0f MB", downloadedGB * 1024, totalGB * 1024)
        }
        return String(format: "%.1f / %.1f GB", downloadedGB, totalGB)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}
