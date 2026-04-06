import Foundation

// MARK: - Auth State

public enum AuthState: Sendable {
    case signedOut
    case signingIn
    case signedIn(UserProfile)
    case anonymous
    case error(String)

    public var isAuthenticated: Bool {
        if case .signedIn = self { return true }
        return false
    }

    public var canUseApp: Bool {
        switch self {
        case .signedIn, .anonymous: return true
        default: return false
        }
    }
}

// MARK: - User Profile

public struct UserProfile: Codable, Sendable, Identifiable {
    public let id: UUID
    public var displayName: String?
    public var phone: String?
    public var email: String?
    public var createdAt: Date

    public init(id: UUID, displayName: String? = nil, phone: String? = nil, email: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.phone = phone
        self.email = email
        self.createdAt = createdAt
    }
}

// MARK: - Device Record

public struct DeviceRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public var userID: UUID
    public var deviceName: String
    public var platform: DevicePlatform
    public var chipName: String?
    public var ramGB: Int?
    public var wanNodeID: String?
    public var registeredAt: Date
    public var lastSeen: Date
    public var isActive: Bool

    public init(
        id: UUID = UUID(),
        userID: UUID,
        deviceName: String,
        platform: DevicePlatform,
        chipName: String? = nil,
        ramGB: Int? = nil,
        wanNodeID: String? = nil,
        registeredAt: Date = Date(),
        lastSeen: Date = Date(),
        isActive: Bool = true
    ) {
        self.id = id
        self.userID = userID
        self.deviceName = deviceName
        self.platform = platform
        self.chipName = chipName
        self.ramGB = ramGB
        self.wanNodeID = wanNodeID
        self.registeredAt = registeredAt
        self.lastSeen = lastSeen
        self.isActive = isActive
    }
}

public enum DevicePlatform: String, Codable, Sendable {
    case macos
    case ios
}

// MARK: - Device Transfer

public struct DeviceTransferRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public var deviceID: UUID
    public var fromUserID: UUID
    public var toUserID: UUID
    public var transferredAt: Date

    public init(id: UUID = UUID(), deviceID: UUID, fromUserID: UUID, toUserID: UUID, transferredAt: Date = Date()) {
        self.id = id
        self.deviceID = deviceID
        self.fromUserID = fromUserID
        self.toUserID = toUserID
        self.transferredAt = transferredAt
    }
}
