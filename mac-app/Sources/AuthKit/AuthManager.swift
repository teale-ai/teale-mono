import CryptoKit
import Foundation
import GatewayKit
import Security
import SharedTypes

// MARK: - Gateway session token storage

/// Where the gateway account session token (`tsess_…`) lives.
protocol GatewaySessionTokenStore: Sendable {
    func read() -> String?
    func write(_ token: String) throws
    func delete()
}

/// 0600 file under Application Support. Debug builds only: unsigned dev
/// builds get a new code signature on every build, which would make the
/// Keychain prompt for access each time.
struct FileGatewaySessionTokenStore: GatewaySessionTokenStore {
    let fileURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("com.teale.app/auth", isDirectory: true)
        // Same (percent-encoded) name earlier builds wrote, so migration
        // finds the existing file.
        let name = "gateway-session-token"
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "gateway-session-token"
        self.fileURL = base.appendingPathComponent(name)
    }

    func read() -> String? {
        guard let data = try? Data(contentsOf: fileURL),
              let token = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        return token
    }

    func write(_ token: String) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(token.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func delete() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

enum GatewaySessionTokenStoreError: Error {
    case keychain(OSStatus)
}

/// Generic-password Keychain item. Used by signed (release) builds; the
/// Developer ID designated requirement is stable across updates, so the
/// main app and its relaunched/fleet-supply instances read it without
/// prompting.
struct KeychainGatewaySessionTokenStore: GatewaySessionTokenStore {
    let service: String
    let account: String

    init(service: String = "com.teale.app.gateway-session", account: String = "gateway-session-token") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8),
              !token.isEmpty else { return nil }
        return token
    }

    func write(_ token: String) throws {
        let data = Data(token.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw GatewaySessionTokenStoreError.keychain(status)
        }
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw GatewaySessionTokenStoreError.keychain(addStatus)
        }
    }

    func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// Keychain store that adopts (once) a token a previous build left in the
/// plaintext file, then deletes the file. If the Keychain write fails the
/// file is kept so the user stays signed in.
struct MigratingGatewaySessionTokenStore: GatewaySessionTokenStore {
    let primary: any GatewaySessionTokenStore
    let legacy: any GatewaySessionTokenStore

    func migrateIfNeeded() {
        guard let legacyToken = legacy.read() else { return }
        if primary.read() == nil {
            do {
                try primary.write(legacyToken)
            } catch {
                return
            }
        }
        legacy.delete()
    }

    func read() -> String? {
        primary.read() ?? legacy.read()
    }

    func write(_ token: String) throws {
        try primary.write(token)
        legacy.delete()
    }

    func delete() {
        primary.delete()
        legacy.delete()
    }
}

enum GatewaySessionTokenStores {
    static func makeDefault() -> any GatewaySessionTokenStore {
        #if DEBUG
        return FileGatewaySessionTokenStore()
        #else
        let store = MigratingGatewaySessionTokenStore(
            primary: KeychainGatewaySessionTokenStore(),
            legacy: FileGatewaySessionTokenStore()
        )
        store.migrateIfNeeded()
        return store
        #endif
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
    /// The raw gateway account id of the current session (`270e…` UUID or
    /// `email:{addr}`). `currentUser.id` is a derived local UUID and must NOT
    /// be sent back to the gateway as an account id.
    public private(set) var gatewayAccountUserID: String?
    public private(set) var devices: [DeviceRecord] = []
    public private(set) var currentDeviceID: UUID?

    // Device info — set by the app before registerDevice()
    public var deviceHardware: (chipName: String?, ramGB: Int?)?
    public var wanNodeID: String?

    private let gatewaySessions: GatewaySessionClient
    private let gatewayTokenStore: any GatewaySessionTokenStore
    private static let anonymousKey = "teale_anonymous_mode"

    public init(gatewayBaseURL: URL? = nil) {
        if let gatewayBaseURL {
            self.gatewaySessions = GatewaySessionClient(baseURL: gatewayBaseURL)
        } else {
            self.gatewaySessions = GatewaySessionClient()
        }
        self.gatewayTokenStore = GatewaySessionTokenStores.makeDefault()
    }

    /// The stored gateway account session token (`tsess_…`), if any. Sent
    /// as `X-Teale-Account-Session` on account-link calls (ownership proof).
    public func currentGatewaySessionToken() -> String? {
        gatewayTokenStore.read()
    }

    // Cancel tasks when no longer needed
    public func cleanup() {}

    // MARK: - Session Check

    /// Check for existing session on app launch.
    public func checkSession() async {
        if let token = gatewayTokenStore.read() {
            let sessions = gatewaySessions
            do {
                let info = try await withTimeout(seconds: 5) {
                    try await sessions.fetchSession(token: token)
                }
                finishGatewaySignIn(accountUserID: info.accountUserID, email: info.email)
                return
            } catch let GatewaySessionError.http(code, _) where code == 401 || code == 403 {
                // Definitively rejected server-side: drop the token.
                gatewayTokenStore.delete()
            } catch {
                // Network error, timeout, or 5xx: KEEP the token - a transient
                // failure must not sign the user out (this previously deleted
                // the persisted session on any 5s timeout).
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

    /// The session token carried by a gateway magic link
    /// (`teale://auth/session?token=…`), or nil for any other URL.
    public nonisolated static func sessionToken(fromDeepLink url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "teale",
              components.host?.lowercased() == "auth",
              components.path == "/session",
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty
        else { return nil }
        return token
    }

    /// Whether `url` is a gateway magic link this manager can adopt.
    public nonisolated static func isSessionDeepLink(_ url: URL) -> Bool {
        sessionToken(fromDeepLink: url) != nil
    }

    /// Handle an auth callback URL (teale://auth/session?token=…), adopting
    /// a gateway magic-link session minted outside the native flow. Returns
    /// true when the session was validated and this manager is signed in.
    @discardableResult
    public func handleOAuthCallback(url: URL) async -> Bool {
        guard let token = Self.sessionToken(fromDeepLink: url) else { return false }
        do {
            let info = try await gatewaySessions.fetchSession(token: token)
            try gatewayTokenStore.write(token)
            finishGatewaySignIn(accountUserID: info.accountUserID, email: info.email)
            return true
        } catch {
            authState = .error(error.localizedDescription)
            return false
        }
    }

    /// Adopt a `tsess_…` session minted outside the native login window -
    /// e.g. the companion web UI's email-code verify, which is proxied
    /// through the local daemon (RemoteControlBridge). Persists the token
    /// first so a later launch signs in even if the identity fetch fails.
    public func adoptGatewaySession(token: String) async {
        try? gatewayTokenStore.write(token)
        do {
            let info = try await gatewaySessions.fetchSession(token: token)
            finishGatewaySignIn(accountUserID: info.accountUserID, email: info.email)
        } catch {
            // Token is persisted; the next launch's checkSession() adopts it.
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
            try gatewayTokenStore.write(res.sessionToken)
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
        gatewayAccountUserID = accountUserID
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
        if let token = gatewayTokenStore.read() {
            try? await gatewaySessions.logout(token: token)
            gatewayTokenStore.delete()
        }
        currentUser = nil
        gatewayAccountUserID = nil
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
