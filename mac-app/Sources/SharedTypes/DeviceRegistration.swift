import Foundation

// MARK: - Device Registration (multi-device support, Phase 2+)

public struct DeviceInfo: Codable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var hardware: HardwareCapability
    public var registeredAt: Date
    public var lastSeenAt: Date
    public var isCurrentDevice: Bool
    public var connectionQuality: ConnectionQuality?
    public var loadedModels: [String]

    public init(
        id: UUID = UUID(),
        name: String,
        hardware: HardwareCapability,
        registeredAt: Date = Date(),
        lastSeenAt: Date = Date(),
        isCurrentDevice: Bool = true,
        connectionQuality: ConnectionQuality? = nil,
        loadedModels: [String] = []
    ) {
        self.id = id
        self.name = name
        self.hardware = hardware
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
        self.isCurrentDevice = isCurrentDevice
        self.connectionQuality = connectionQuality
        self.loadedModels = loadedModels
    }
}

// MARK: - Account (stub for Phase 3)

public struct AccountInfo: Codable, Sendable {
    public var id: UUID
    public var email: String?
    public var devices: [DeviceInfo]
    public var balance: Double

    public init(id: UUID = UUID(), email: String? = nil, devices: [DeviceInfo] = [], balance: Double = 0) {
        self.id = id
        self.email = email
        self.devices = devices
        self.balance = balance
    }
}
