import CryptoKit
import Foundation
import GatewayKit
import SharedTypes

// MARK: - File-based auth token storage (avoids Keychain prompts on unsigned apps)

private struct FileAuthStorage: @unchecked Sendable {
    private let directory: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        self.directory = appSupport.appendingPathComponent("com.teale.app/auth", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func store(key: String, value: Data) throws {
        let url = directory.appendingPathComponent(safeFileName(key))
        try value.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func retrieve(key: String) throws -> Data? {
        let url = directory.appendingPathComponent(safeFileName(key))
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func remove(key: String) throws {
        let url = directory.appendingPathComponent(safeFileName(key))
        try? FileManager.default.removeItem(at: url)
    }

    private func safeFileName(_ key: String) -> String {
        key.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? key
    }
}

// MARK: - Auth Manager

/// Gateway-native passwordless auth (email code + magic link, `tsess_…`
/// account sessions). Supabase auth (Apple / phone / OAuth) is removed:
/// the Supabase project that backed it is gone and email/gateway auth is
/// the sign-in story going forward.
@MainActor
@Observable
public final class AuthManager {
    public private(set) var authState: AuthState = .signedOut
    public private(set) var currentUser: UserProfile?
    public private(set) var devices: [DeviceRecord] = []
    public private(set) var currentDeviceID: UUID?

    // Device info — set by the app before registerDevice()
    public var deviceHardware: (chipName: String?, ramGB: Int?)?
    public var wanNodeID: String?

    private let gatewaySessions: GatewaySessionClient
    private let gatewayTokenStore = FileAuthStorage()
    private static let gatewayTokenKey = "gateway-session-token"
    private static let anonymousKey = "teale_anonymous_mode"

    public init(gatewayBaseURL: URL? = nil) {
        if let gatewayBaseURL {
            self.gatewaySessions = GatewaySessionClient(baseURL: gatewayBaseURL)
        } else {
            self.gatewaySessions = GatewaySessionClient()
        }
    }

    // Cancel tasks when no longer needed
    public func cleanup() {}

    // MARK: - Session Check

    /// Check for existing session on app launch.
    public func checkSession() async {
        if let stored = try? gatewayTokenStore.retrieve(key: Self.gatewayTokenKey),
           let token = String(data: stored, encoding: .utf8), !token.isEmpty {
            let sessions = gatewaySessions
            do {
                let info = try await withTimeout(seconds: 5) {
                    try await sessions.fetchSession(token: token)
                }
                finishGatewaySignIn(accountUserID: info.accountUserID, email: info.email)
                return
            } catch {
                // Dead or unreachable session: drop it and fall through.
                try? gatewayTokenStore.remove(key: Self.gatewayTokenKey)
            }
        }

        if UserDefaults.standard.bool(forKey: Self.anonymousKey) {
            authState = .anonymous
            return
        }

        authState = .signedOut
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CancellationError()
            }
            guard let result = try await group.next() else {
                throw CancellationError()
            }
            group.cancelAll()
            return result
        }
    }

    // MARK: - Anonymous Mode

    /// Continue without an account. Local wallet only.
    public func continueAnonymously() {
        UserDefaults.standard.set(true, forKey: Self.anonymousKey)
        authState = .anonymous
    }

    // MARK: - Deep Link Session Adoption

    /// Handle an auth callback URL (teale://auth/session?token=…), adopting
    /// a gateway magic-link session minted outside the native flow.
    public func handleOAuthCallback(url: URL) async {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == "teale",
              components.host == "auth",
              components.path == "/session",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value
        else { return }
        do {
            let info = try await gatewaySessions.fetchSession(token: token)
            try gatewayTokenStore.store(key: Self.gatewayTokenKey, value: Data(token.utf8))
            finishGatewaySignIn(accountUserID: info.accountUserID, email: info.email)
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - Email Code Login

    /// Send a login code to an email address.
    /// Gateway-native: one email carries both a 6-digit code and a magic
    /// link (teale://auth/session?token=…).
    public func signInWithEmailOTP(email: String) async throws {
        authState = .signingIn
        do {
            try await gatewaySessions.requestEmailLogin(email: email)
            authState = .signedOut
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    /// Verify the code received via email.
    public func verifyEmailOTP(email: String, code: String) async throws {
        do {
            let res = try await gatewaySessions.verifyEmailLogin(
                email: email,
                code: code,
                deviceID: GatewayIdentity.shared.deviceID,
                deviceName: ProcessInfo.processInfo.hostName
            )
            try gatewayTokenStore.store(key: Self.gatewayTokenKey, value: Data(res.sessionToken.utf8))
            finishGatewaySignIn(accountUserID: res.accountUserID, email: res.email)
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    /// Complete a gateway-native email sign-in.
    private func finishGatewaySignIn(accountUserID: String, email: String?) {
        let profile = UserProfile(
            id: Self.accountUUID(for: accountUserID),
            displayName: nil,
            phone: nil,
            email: email,
            createdAt: Date()
        )
        currentUser = profile
        authState = .signedIn(profile)
        UserDefaults.standard.set(true, forKey: Self.anonymousKey)
    }

    /// Stable UUID for a gateway account id. UUID account ids pass through
    /// unchanged; `email:{addr}` ids get a deterministic RFC 4122 v5 UUID so
    /// the same account always maps to the same local profile id.
    static func accountUUID(for accountUserID: String) -> UUID {
        if let uuid = UUID(uuidString: accountUserID) { return uuid }
        var hasher = Insecure.SHA1()
        var namespace = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!.uuid
        withUnsafeBytes(of: &namespace) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(accountUserID.utf8))
        var bytes = Array(hasher.finalize().prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        let uuid: uuid_t = (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        )
        return UUID(uuid: uuid)
    }

    // MARK: - Sign Out

    /// Sign out. Reverts to anonymous mode (app stays usable).
    public func signOut() async {
        if let stored = try? gatewayTokenStore.retrieve(key: Self.gatewayTokenKey),
           let token = String(data: stored, encoding: .utf8), !token.isEmpty {
            try? await gatewaySessions.logout(token: token)
            try? gatewayTokenStore.remove(key: Self.gatewayTokenKey)
        }
        currentUser = nil
        devices = []
        currentDeviceID = nil
        authState = .anonymous
    }

    // MARK: - Device Registry (disabled)

    /// The device registry lived in Supabase tables (profiles / devices /
    /// transfer_device RPC) and went away with the Supabase backend. These
    /// methods keep their signatures so the management UI compiles and runs,
    /// but they are inert until gateway account endpoints replace them.
    /// Signed-in identity, wallet, and credits are unaffected.

    /// Fetch all devices for the current user. Inert: returns an empty list.
    public func fetchDevices() async {
        devices = []
        currentDeviceID = nil
    }

    /// Remove a device from the account. Inert: removes locally only.
    public func removeDevice(id: UUID) async {
        devices.removeAll { $0.id == id }
    }

    /// Transfer a device to another user. Unavailable without the Supabase
    /// registry; will return with gateway account endpoints.
    @discardableResult
    public func transferDevice(deviceID: UUID, toRecipientPhone: String) async throws -> String? {
        throw AuthError.transferUnavailable
    }

    /// Look up a user by phone number. Inert: always nil.
    public func lookupUser(phone: String) async -> UserProfile? {
        nil
    }

    /// Update display name for the current user (local only until the
    /// gateway profile endpoint lands).
    public func updateDisplayName(_ name: String) async {
        currentUser?.displayName = name
    }
}

// MARK: - Auth Errors

public enum AuthError: LocalizedError {
    case recipientNotFound
    case deviceNotOwned
    case notAuthenticated
    case transferUnavailable

    public var errorDescription: String? {
        switch self {
        case .recipientNotFound: return "No user found with that phone number"
        case .deviceNotOwned: return "You don't own this device"
        case .notAuthenticated: return "You must be signed in to perform this action"
        case .transferUnavailable: return "Device transfer is unavailable while the device registry moves to the gateway"
        }
    }
}
