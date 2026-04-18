import Foundation
import SharedTypes
import LocalAPI

@MainActor
final class RemoteControlBridge: @unchecked Sendable, LocalAppControlling {
    private unowned let appState: AppState

    init(appState: AppState) {
        self.appState = appState
    }

    func remoteSnapshot() async -> RemoteAppSnapshot {
        await appState.refreshDownloadedModels()

        let loadedModel = await appState.engine.loadedModel
        let compatibleModels = appState.modelManager.compatibleModels
        let downloaded = appState.downloadedModelIDs
        let downloading = appState.modelManager.downloadingModels

        let models = compatibleModels.map { model in
            RemoteModelSnapshot(
                id: model.id,
                name: model.name,
                huggingFaceRepo: model.huggingFaceRepo,
                downloaded: downloaded.contains(model.id),
                loaded: loadedModel?.id == model.id,
                downloadingProgress: downloading[model.id]
            )
        }

        return RemoteAppSnapshot(
            appVersion: appVersion(),
            loadedModelID: loadedModel?.id,
            loadedModelRepo: loadedModel?.huggingFaceRepo,
            engineStatus: String(describing: appState.engineStatus),
            isServerRunning: appState.isServerRunning,
            settings: RemoteSettingsSnapshot(
                clusterEnabled: appState.clusterEnabled,
                wanEnabled: appState.wanEnabled,
                wanRelayURL: appState.wanRelayURL,
                wanBusy: appState.isWANBusy,
                wanLastError: appState.wanLastError,
                maxStorageGB: appState.maxStorageGB,
                orgCapacityReservation: appState.clusterManager.orgCapacityReservation,
                clusterPasscodeSet: appState.clusterManager.passcode?.isEmpty == false,
                allowNetworkAccess: appState.allowNetworkAccess
            ),
            models: models
        )
    }

    func remoteLoadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot {
        let model = try resolveModel(request.model)
        let isDownloaded = await appState.modelManager.isDownloaded(model)

        if !isDownloaded {
            guard request.downloadIfNeeded == true else {
                throw RemoteControlError.modelNotDownloaded(request.model)
            }
            try await downloadModel(model)
        }

        try await loadModel(model)
        return await remoteSnapshot()
    }

    func remoteDownloadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot {
        let model = try resolveModel(request.model)
        try await downloadModel(model)
        return await remoteSnapshot()
    }

    func remoteUnloadModel() async -> RemoteAppSnapshot {
        await appState.unloadModel()
        return await remoteSnapshot()
    }

    func remoteUpdateSettings(_ update: RemoteSettingsUpdate) async throws -> RemoteAppSnapshot {
        if let maxStorageGB = update.maxStorageGB {
            guard (5...200).contains(maxStorageGB) else {
                throw RemoteControlError.invalidSetting("max_storage_gb must be between 5 and 200")
            }
            appState.maxStorageGB = maxStorageGB
        }

        if let wanRelayURL = update.wanRelayURL {
            guard URL(string: wanRelayURL) != nil else {
                throw RemoteControlError.invalidSetting("wan_relay_url must be a valid URL")
            }
            appState.wanRelayURL = wanRelayURL
        }

        if let orgCapacityReservation = update.orgCapacityReservation {
            guard (0...1).contains(orgCapacityReservation) else {
                throw RemoteControlError.invalidSetting("org_capacity_reservation must be between 0 and 1")
            }
            appState.clusterManager.orgCapacityReservation = orgCapacityReservation
        }

        if let clusterPasscode = update.clusterPasscode {
            appState.clusterManager.passcode = clusterPasscode.isEmpty ? nil : clusterPasscode
        }

        if let clusterEnabled = update.clusterEnabled {
            appState.clusterEnabled = clusterEnabled
        }

        if let wanEnabled = update.wanEnabled {
            appState.wanEnabled = wanEnabled
            // enableWAN() fires an async Task internally; we return immediately
            // and the caller can poll GET /v1/app to check wanBusy/wanLastError.
        }

        return await remoteSnapshot()
    }

    private func resolveModel(_ value: String) throws -> ModelDescriptor {
        if let model = appState.modelManager.compatibleModels.first(where: { $0.id == value || $0.huggingFaceRepo == value }) {
            return model
        }
        throw RemoteControlError.modelNotFound(value)
    }

    private func downloadModel(_ descriptor: ModelDescriptor) async throws {
        appState.activeDownloads[descriptor.id] = 0
        do {
            try await appState.modelManager.downloadModel(descriptor)
            appState.activeDownloads.removeValue(forKey: descriptor.id)
            appState.downloadedModelIDs.insert(descriptor.id)
        } catch {
            appState.activeDownloads.removeValue(forKey: descriptor.id)
            throw error
        }
    }

    private func loadModel(_ descriptor: ModelDescriptor) async throws {
        if case .ready = appState.engineStatus {
            await appState.engine.unloadModel()
        }

        appState.selectedModel = descriptor
        appState.engineStatus = .loadingModel(descriptor)
        appState.loadingPhase = "Preparing…"
        appState.loadingProgress = 0

        do {
            try await appState.engine.loadModel(descriptor) { [weak appState] progress in
                Task { @MainActor in
                    appState?.loadingPhase = progress.phase.rawValue
                    appState?.loadingProgress = progress.fractionCompleted
                }
            }

            appState.loadingPhase = ""
            appState.loadingProgress = nil
            appState.engineStatus = .ready(descriptor)
            if appState.wanEnabled {
                await appState.wanManager.updateLocalLoadedModels([descriptor.huggingFaceRepo])
            }
            await appState.refreshDownloadedModels()
        } catch {
            appState.loadingPhase = ""
            appState.loadingProgress = nil
            appState.engineStatus = .error(error.localizedDescription)
            throw error
        }
    }

    private func appVersion() -> String {
        BuildVersion.display
    }
}
