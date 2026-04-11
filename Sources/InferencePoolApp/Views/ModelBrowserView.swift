import SwiftUI
import AppCore
import SharedTypes
import ModelManager

struct ModelBrowserView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var switchConfirmModel: ModelDescriptor?
    @State private var showLocalModels: Bool = false
    @State private var showFolderPicker: Bool = false
    @State private var localModelError: String?

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
                TextField(appState.loc("models.search"), text: $searchText)
                    .textFieldStyle(.plain)
            }
            .padding(8)
            .background(.quaternary)

            Divider()

            // Model list with ranking sections
            ScrollView {
                LazyVStack(spacing: 1) {
                    // Local models section
                    if showLocalModels && !appState.scannedLocalModels.isEmpty {
                        localModelsSection
                    }

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

            // Footer
            HStack {
                Text(String(format: appState.loc("models.available"), appState.modelManager.compatibleModels.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

                // Import local model button
                Menu {
                    Button {
                        appState.scanLocalModels()
                        showLocalModels = true
                    } label: {
                        Label("Scan for Local Models", systemImage: "magnifyingglass")
                    }

                    Button {
                        showFolderPicker = true
                    } label: {
                        Label("Import from Folder...", systemImage: "folder")
                    }
                } label: {
                    Label("Import", systemImage: "square.and.arrow.down")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text(String(format: appState.loc("models.gbAvailable"), Int(appState.hardware.availableRAMForModelsGB)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
        .navigationTitle(appState.loc("models.title"))
        .alert(appState.loc("models.switchModel"), isPresented: Binding(
            get: { switchConfirmModel != nil },
            set: { if !$0 { switchConfirmModel = nil } }
        )) {
            Button(appState.loc("models.cancel"), role: .cancel) {
                switchConfirmModel = nil
            }
            Button(appState.loc("models.switchButton")) {
                if let model = switchConfirmModel {
                    switchConfirmModel = nil
                    Task { await appState.loadModel(model) }
                }
            }
        } message: {
            if let model = switchConfirmModel {
                Text(String(format: appState.loc("models.switchConfirm"), model.name))
            }
        }
        .alert(appState.loc("models.downloadComplete"), isPresented: Binding(
            get: { appState.justDownloadedModel != nil },
            set: { if !$0 { appState.justDownloadedModel = nil } }
        )) {
            Button(appState.loc("models.notNow"), role: .cancel) {
                appState.justDownloadedModel = nil
            }
            Button(appState.loc("models.load")) {
                if let model = appState.justDownloadedModel {
                    appState.justDownloadedModel = nil
                    Task { await appState.loadModel(model) }
                }
            }
        } message: {
            if let model = appState.justDownloadedModel {
                Text(String(format: appState.loc("models.readyToLoad"), model.name))
            }
        }
        .alert("Import Error", isPresented: Binding(
            get: { localModelError != nil },
            set: { if !$0 { localModelError = nil } }
        )) {
            Button("OK") { localModelError = nil }
        } message: {
            if let error = localModelError {
                Text(error)
            }
        }
        .fileImporter(
            isPresented: $showFolderPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFolderSelection(result)
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

    // MARK: - Local Models Section

    @ViewBuilder
    private var localModelsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Label("Local Models", systemImage: "internaldrive")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(appState.scannedLocalModels.count) found")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button {
                    showLocalModels = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ForEach(filteredLocalModels) { localModel in
                LocalModelRowView(localModel: localModel)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            }

            Divider()
                .padding(.vertical, 4)
        }
    }

    // MARK: - Filtering


    private var filteredModels: [ModelDescriptor] {
        let models = appState.modelManager.compatibleModels
        if searchText.isEmpty { return models }
        return models.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.family.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredLocalModels: [LocalModelInfo] {
        if searchText.isEmpty { return appState.scannedLocalModels }
        return appState.scannedLocalModels.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
        }
    }

    // MARK: - Folder Selection

    private func handleFolderSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }

            // Start accessing security-scoped resource
            guard url.startAccessingSecurityScopedResource() else {
                localModelError = "Could not access the selected folder."
                return
            }
            defer { url.stopAccessingSecurityScopedResource() }

            let scanner = LocalModelScanner()
            if let localModel = scanner.validateDirectory(url) {
                Task { await appState.loadLocalModel(localModel) }
            } else {
                localModelError = "The selected folder doesn't contain a valid MLX model. Expected safetensors files and config.json."
            }
        case .failure(let error):
            localModelError = error.localizedDescription
        }
    }
}

// MARK: - Local Model Row

struct LocalModelRowView: View {
    @Environment(AppState.self) private var appState
    let localModel: LocalModelInfo
    @State private var error: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(localModel.name)
                        .font(.body.bold())
                    sourceBadge
                }

                Text(localModel.path.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 8) {
                    if let config = localModel.configJSON {
                        Label(config.parameterCountString, systemImage: "cpu")
                        if let type = config.modelType {
                            Label(type, systemImage: "brain")
                        }
                    }
                    Label(String(format: "%.1f GB", localModel.sizeGB), systemImage: "externaldrive")
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer()

            Button("Load") {
                Task {
                    error = nil
                    await appState.loadLocalModel(localModel)
                    if case .error(let msg) = appState.engineStatus {
                        error = msg
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }

        if let error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private var sourceBadge: some View {
        let (text, color): (String, Color) = {
            switch localModel.source {
            case .huggingFaceCache: return ("HF", .blue)
            case .lmStudio: return ("LMS", .purple)
            case .tealeCache: return ("TEALE", .green)
            case .custom: return ("LOCAL", .orange)
            }
        }()
        return Text(text)
            .font(.caption2.weight(.medium))
            .fixedSize()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

// MARK: - Model Row (catalog models)

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
            badge(appState.loc("models.loaded"), color: .green)
        } else if isCurrentlyLoading {
            let phase = appState.loadingPhase.lowercased()
            if phase.contains("verif") {
                badge(appState.loc("models.checking"), color: .yellow)
            } else {
                badge(appState.loc("models.loading"), color: .blue)
            }
        } else if isDownloading {
            badge(appState.loc("models.downloading"), color: .orange)
        } else if isDownloaded {
            badge(appState.loc("models.ready"), color: .secondary)
        }
    }

    // MARK: - Action Buttons

    @ViewBuilder
    private var actionView: some View {
        if isCurrentlyLoaded {
            // Loaded — offer unload
            Button(appState.loc("models.unload")) {
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
                    Text(appState.loadingPhase.isEmpty ? appState.loc("models.preparing") : appState.loadingPhase)
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
            Button(appState.loc("models.load")) {
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
                Label(appState.loc("models.download"), systemImage: "arrow.down.circle")
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
