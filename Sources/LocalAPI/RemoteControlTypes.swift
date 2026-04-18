import Foundation
import SharedTypes

public protocol LocalAppControlling: AnyObject {
    func remoteSnapshot() async -> RemoteAppSnapshot
    func remoteLoadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot
    func remoteDownloadModel(_ request: RemoteModelControlRequest) async throws -> RemoteAppSnapshot
    func remoteUnloadModel() async -> RemoteAppSnapshot
    func remoteUpdateSettings(_ update: RemoteSettingsUpdate) async throws -> RemoteAppSnapshot
}

public struct RemoteAppSnapshot: Codable, Sendable {
    public var appVersion: String
    public var loadedModelID: String?
    public var loadedModelRepo: String?
    public var engineStatus: String
    public var isServerRunning: Bool
    public var settings: RemoteSettingsSnapshot
    public var models: [RemoteModelSnapshot]

    public init(
        appVersion: String,
        loadedModelID: String?,
        loadedModelRepo: String?,
        engineStatus: String,
        isServerRunning: Bool,
        settings: RemoteSettingsSnapshot,
        models: [RemoteModelSnapshot]
    ) {
        self.appVersion = appVersion
        self.loadedModelID = loadedModelID
        self.loadedModelRepo = loadedModelRepo
        self.engineStatus = engineStatus
        self.isServerRunning = isServerRunning
        self.settings = settings
        self.models = models
    }
}

public struct RemoteSettingsSnapshot: Codable, Sendable {
    public var clusterEnabled: Bool
    public var wanEnabled: Bool
    public var wanRelayURL: String
    public var wanBusy: Bool
    public var wanLastError: String?
    public var maxStorageGB: Double
    public var orgCapacityReservation: Double
    public var clusterPasscodeSet: Bool
    public var allowNetworkAccess: Bool

    public init(
        clusterEnabled: Bool,
        wanEnabled: Bool,
        wanRelayURL: String,
        wanBusy: Bool = false,
        wanLastError: String? = nil,
        maxStorageGB: Double,
        orgCapacityReservation: Double,
        clusterPasscodeSet: Bool,
        allowNetworkAccess: Bool
    ) {
        self.clusterEnabled = clusterEnabled
        self.wanEnabled = wanEnabled
        self.wanRelayURL = wanRelayURL
        self.wanBusy = wanBusy
        self.wanLastError = wanLastError
        self.maxStorageGB = maxStorageGB
        self.orgCapacityReservation = orgCapacityReservation
        self.clusterPasscodeSet = clusterPasscodeSet
        self.allowNetworkAccess = allowNetworkAccess
    }
}

public struct RemoteModelSnapshot: Codable, Sendable {
    public var id: String
    public var name: String
    public var huggingFaceRepo: String
    public var downloaded: Bool
    public var loaded: Bool
    public var downloadingProgress: Double?

    public init(
        id: String,
        name: String,
        huggingFaceRepo: String,
        downloaded: Bool,
        loaded: Bool,
        downloadingProgress: Double?
    ) {
        self.id = id
        self.name = name
        self.huggingFaceRepo = huggingFaceRepo
        self.downloaded = downloaded
        self.loaded = loaded
        self.downloadingProgress = downloadingProgress
    }
}

public struct RemoteModelControlRequest: Codable, Sendable {
    public var model: String
    public var downloadIfNeeded: Bool?

    enum CodingKeys: String, CodingKey {
        case model
        case downloadIfNeeded = "download_if_needed"
    }

    public init(model: String, downloadIfNeeded: Bool? = nil) {
        self.model = model
        self.downloadIfNeeded = downloadIfNeeded
    }
}

public struct RemoteSettingsUpdate: Codable, Sendable {
    public var clusterEnabled: Bool?
    public var wanEnabled: Bool?
    public var wanRelayURL: String?
    public var maxStorageGB: Double?
    public var orgCapacityReservation: Double?
    public var clusterPasscode: String?

    enum CodingKeys: String, CodingKey {
        case clusterEnabled = "cluster_enabled"
        case wanEnabled = "wan_enabled"
        case wanRelayURL = "wan_relay_url"
        case maxStorageGB = "max_storage_gb"
        case orgCapacityReservation = "org_capacity_reservation"
        case clusterPasscode = "cluster_passcode"
    }

    public init(
        clusterEnabled: Bool? = nil,
        wanEnabled: Bool? = nil,
        wanRelayURL: String? = nil,
        maxStorageGB: Double? = nil,
        orgCapacityReservation: Double? = nil,
        clusterPasscode: String? = nil
    ) {
        self.clusterEnabled = clusterEnabled
        self.wanEnabled = wanEnabled
        self.wanRelayURL = wanRelayURL
        self.maxStorageGB = maxStorageGB
        self.orgCapacityReservation = orgCapacityReservation
        self.clusterPasscode = clusterPasscode
    }
}

public enum RemoteControlError: LocalizedError, Sendable {
    case unsupported
    case modelNotFound(String)
    case modelNotDownloaded(String)
    case invalidSetting(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            return "Remote control is not enabled for this app instance"
        case .modelNotFound(let model):
            return "Model not found: \(model)"
        case .modelNotDownloaded(let model):
            return "Model is not downloaded: \(model)"
        case .invalidSetting(let message):
            return message
        }
    }
}
