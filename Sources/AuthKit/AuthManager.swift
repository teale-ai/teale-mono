import Foundation
import SharedTypes
import Supabase
import Auth

// MARK: - Auth Manager

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

    private let client: SupabaseClient
    private var authListenerTask: Task<Void, Never>?
    private var lastSeenTimer: Task<Void, Never>?

    private static let anonymousKey = "teale_anonymous_mode"

    public init(config: SupabaseConfig) {
        self.client = SupabaseClient(
            supabaseURL: config.url,
            supabaseKey: config.anonKey
        )
    }

    // Cancel tasks when no longer needed
    public func cleanup() {
        authListenerTask?.cancel()
        lastSeenTimer?.cancel()
    }

    // MARK: - Session Check

    /// Check for existing session on app launch.
    public func checkSession() async {
        // Check if user previously chose anonymous mode
        if UserDefaults.standard.bool(forKey: Self.anonymousKey) {
            // Check if they also have a valid session (upgraded from anonymous)
            if let session = try? await client.auth.session {
                let profile = await loadProfile(userID: session.user.id)
                authState = .signedIn(profile)
                currentUser = profile
                await registerDevice()
                await fetchDevices()
                startLastSeenTimer()
                return
            }
            authState = .anonymous
            return
        }

        // Try to restore existing session
        do {
            let session = try await client.auth.session
            let profile = await loadProfile(userID: session.user.id)
            authState = .signedIn(profile)
            currentUser = profile
            await registerDevice()
            await fetchDevices()
            startLastSeenTimer()
        } catch {
            authState = .signedOut
        }
    }

    // MARK: - Anonymous Mode

    /// Continue without an account. Local wallet only.
    public func continueAnonymously() {
        UserDefaults.standard.set(true, forKey: Self.anonymousKey)
        authState = .anonymous
    }

    // MARK: - Sign In with Apple

    /// Sign in using an Apple ID token from ASAuthorizationAppleIDProvider.
    public func signInWithApple(idToken: String, nonce: String) async throws {
        authState = .signingIn
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: idToken,
                    nonce: nonce
                )
            )
            let profile = await ensureProfile(session: session)
            currentUser = profile
            authState = .signedIn(profile)
            UserDefaults.standard.set(true, forKey: Self.anonymousKey) // Keep app accessible on sign-out
            await registerDevice()
            await fetchDevices()
            startLastSeenTimer()
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - OAuth (GitHub, Google)

    /// Sign in with an OAuth provider (GitHub, Google, etc.)
    /// Opens the default browser for the OAuth flow; Supabase handles the redirect.
    public func signInWithOAuth(provider: Auth.Provider) async throws {
        authState = .signingIn
        do {
            let session = try await client.auth.signInWithOAuth(
                provider: provider,
                redirectTo: URL(string: "teale://auth/callback")
            )
            // OAuth opens browser — session is established via deep link callback
            // The auth state listener will pick up the session
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    /// Handle the OAuth callback URL (deep link from browser).
    public func handleOAuthCallback(url: URL) async {
        do {
            let session = try await client.auth.session(from: url)
            let profile = await ensureProfile(session: session)
            currentUser = profile
            authState = .signedIn(profile)
            UserDefaults.standard.set(true, forKey: Self.anonymousKey)
            await registerDevice()
            await fetchDevices()
            startLastSeenTimer()
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    // MARK: - Phone OTP

    /// Send an OTP code to a phone number.
    public func signInWithPhoneOTP(phone: String) async throws {
        authState = .signingIn
        try await client.auth.signInWithOTP(phone: phone)
    }

    /// Verify the OTP code received via SMS.
    public func verifyPhoneOTP(phone: String, code: String) async throws {
        do {
            let response = try await client.auth.verifyOTP(
                phone: phone,
                token: code,
                type: .sms
            )
            let profile = await ensureProfile(session: response.session!)
            currentUser = profile
            authState = .signedIn(profile)
            UserDefaults.standard.set(true, forKey: Self.anonymousKey)
            await registerDevice()
            await fetchDevices()
            startLastSeenTimer()
        } catch {
            authState = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Sign Out

    /// Sign out. Reverts to anonymous mode (app stays usable).
    public func signOut() async {
        try? await client.auth.signOut()
        currentUser = nil
        devices = []
        currentDeviceID = nil
        lastSeenTimer?.cancel()
        authState = .anonymous
    }

    // MARK: - Profile Management

    private func ensureProfile(session: Session) async -> UserProfile {
        let userID = session.user.id
        let phone = session.user.phone
        let email = session.user.email

        // Try to upsert profile
        let profile = UserProfile(
            id: userID,
            displayName: nil,
            phone: phone,
            email: email,
            createdAt: Date()
        )

        struct ProfileRow: Encodable {
            let id: UUID
            let display_name: String?
            let phone: String?
            let email: String?
        }

        let row = ProfileRow(
            id: userID,
            display_name: profile.displayName,
            phone: phone,
            email: email
        )

        _ = try? await client.from("profiles")
            .upsert(row, onConflict: "id")
            .execute()

        return await loadProfile(userID: userID)
    }

    private func loadProfile(userID: UUID) async -> UserProfile {
        struct ProfileResponse: Decodable {
            let id: UUID
            let display_name: String?
            let phone: String?
            let email: String?
            let created_at: String?
        }

        do {
            let response: ProfileResponse = try await client.from("profiles")
                .select()
                .eq("id", value: userID.uuidString)
                .single()
                .execute()
                .value

            return UserProfile(
                id: response.id,
                displayName: response.display_name,
                phone: response.phone,
                email: response.email,
                createdAt: ISO8601DateFormatter().date(from: response.created_at ?? "") ?? Date()
            )
        } catch {
            return UserProfile(id: userID)
        }
    }

    // MARK: - Device Management

    private func registerDevice() async {
        guard let user = currentUser else { return }

        let deviceName: String
        let platform: DevicePlatform
        #if os(macOS)
        deviceName = ProcessInfo.processInfo.hostName
        platform = .macos
        #else
        deviceName = await UIDevice.current.name
        platform = .ios
        #endif

        struct DeviceRow: Encodable {
            let user_id: UUID
            let device_name: String
            let platform: String
            let chip_name: String?
            let ram_gb: Int?
            let wan_node_id: String?
        }

        let row = DeviceRow(
            user_id: user.id,
            device_name: deviceName,
            platform: platform.rawValue,
            chip_name: deviceHardware?.chipName,
            ram_gb: deviceHardware?.ramGB,
            wan_node_id: wanNodeID
        )

        struct DeviceResponse: Decodable {
            let id: UUID
        }

        do {
            // Check if this device is already registered (match by wan_node_id or name+platform)
            if let nodeID = wanNodeID {
                let existing: [DeviceResponse] = try await client.from("devices")
                    .select("id")
                    .eq("wan_node_id", value: nodeID)
                    .eq("user_id", value: user.id.uuidString)
                    .execute()
                    .value

                if let device = existing.first {
                    // Update existing device
                    currentDeviceID = device.id

                    struct DeviceUpdate: Encodable {
                        let last_seen: String
                        let device_name: String
                        let is_active: Bool
                    }

                    let update = DeviceUpdate(
                        last_seen: ISO8601DateFormatter().string(from: Date()),
                        device_name: deviceName,
                        is_active: true
                    )
                    _ = try? await client.from("devices")
                        .update(update)
                        .eq("id", value: device.id.uuidString)
                        .execute()
                    return
                }
            }

            // Register new device
            let response: DeviceResponse = try await client.from("devices")
                .insert(row)
                .select("id")
                .single()
                .execute()
                .value

            currentDeviceID = response.id
        } catch {
            // Non-fatal — device registration is best-effort
        }
    }

    /// Fetch all devices for the current user.
    public func fetchDevices() async {
        guard let user = currentUser else { return }

        struct DeviceRow: Decodable {
            let id: UUID
            let user_id: UUID
            let device_name: String
            let platform: String
            let chip_name: String?
            let ram_gb: Int?
            let wan_node_id: String?
            let registered_at: String?
            let last_seen: String?
            let is_active: Bool
        }

        do {
            let rows: [DeviceRow] = try await client.from("devices")
                .select()
                .eq("user_id", value: user.id.uuidString)
                .eq("is_active", value: true)
                .order("last_seen", ascending: false)
                .execute()
                .value

            let formatter = ISO8601DateFormatter()
            devices = rows.map { row in
                DeviceRecord(
                    id: row.id,
                    userID: row.user_id,
                    deviceName: row.device_name,
                    platform: DevicePlatform(rawValue: row.platform) ?? .macos,
                    chipName: row.chip_name,
                    ramGB: row.ram_gb,
                    wanNodeID: row.wan_node_id,
                    registeredAt: formatter.date(from: row.registered_at ?? "") ?? Date(),
                    lastSeen: formatter.date(from: row.last_seen ?? "") ?? Date(),
                    isActive: row.is_active
                )
            }
        } catch {
            // Non-fatal
        }
    }

    /// Remove a device from the account (soft delete).
    public func removeDevice(id: UUID) async {
        struct DeactivateUpdate: Encodable {
            let is_active: Bool
        }
        _ = try? await client.from("devices")
            .update(DeactivateUpdate(is_active: false))
            .eq("id", value: id.uuidString)
            .execute()

        devices.removeAll { $0.id == id }
    }

    /// Transfer a device to another user by phone number.
    /// Returns the recipient's display name on success, or throws on failure.
    @discardableResult
    public func transferDevice(deviceID: UUID, toRecipientPhone: String) async throws -> String? {
        // Look up recipient
        struct ProfileLookup: Decodable {
            let id: UUID
            let display_name: String?
        }

        let recipients: [ProfileLookup] = try await client.from("profiles")
            .select("id, display_name")
            .eq("phone", value: toRecipientPhone)
            .execute()
            .value

        guard let recipient = recipients.first else {
            throw AuthError.recipientNotFound
        }

        // Call the atomic transfer RPC
        struct TransferParams: Encodable {
            let p_device_id: UUID
            let p_to_user_id: UUID
            let p_credits_at_transfer: Double
        }

        try await client.rpc(
            "transfer_device",
            params: TransferParams(
                p_device_id: deviceID,
                p_to_user_id: recipient.id,
                p_credits_at_transfer: 0 // Credits stay with original owner
            )
        ).execute()

        // Refresh device list
        await fetchDevices()
        return recipient.display_name
    }

    /// Look up a user by phone number (for transfer preview).
    public func lookupUser(phone: String) async -> UserProfile? {
        struct ProfileLookup: Decodable {
            let id: UUID
            let display_name: String?
            let phone: String?
        }

        guard let result: ProfileLookup = try? await client.from("profiles")
            .select("id, display_name, phone")
            .eq("phone", value: phone)
            .single()
            .execute()
            .value
        else { return nil }

        return UserProfile(id: result.id, displayName: result.display_name, phone: result.phone)
    }

    // MARK: - Last Seen Timer

    private func startLastSeenTimer() {
        lastSeenTimer?.cancel()
        lastSeenTimer = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300)) // 5 minutes
                guard !Task.isCancelled, let deviceID = currentDeviceID else { continue }
                struct LastSeenUpdate: Encodable {
                    let last_seen: String
                }
                _ = try? await client.from("devices")
                    .update(LastSeenUpdate(last_seen: ISO8601DateFormatter().string(from: Date())))
                    .eq("id", value: deviceID.uuidString)
                    .execute()
            }
        }
    }

    /// Update display name for the current user.
    public func updateDisplayName(_ name: String) async {
        guard let user = currentUser else { return }
        struct NameUpdate: Encodable {
            let display_name: String
        }
        _ = try? await client.from("profiles")
            .update(NameUpdate(display_name: name))
            .eq("id", value: user.id.uuidString)
            .execute()
        currentUser?.displayName = name
    }
}

// MARK: - Auth Errors

public enum AuthError: LocalizedError {
    case recipientNotFound
    case deviceNotOwned
    case notAuthenticated

    public var errorDescription: String? {
        switch self {
        case .recipientNotFound: return "No user found with that phone number"
        case .deviceNotOwned: return "You don't own this device"
        case .notAuthenticated: return "You must be signed in to perform this action"
        }
    }
}
