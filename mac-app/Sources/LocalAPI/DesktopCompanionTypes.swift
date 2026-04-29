import Foundation
import SharedTypes
import PrivacyFilterKit

public protocol DesktopCompanionControlling: AnyObject {
    func desktop_snapshot() async throws -> DesktopCompanionAppSnapshot
    func desktop_set_privacy_filter_mode(_ mode: PrivacyFilterMode) async throws -> DesktopCompanionAppSnapshot
    func desktop_auth_session(access_token: String) async throws -> DesktopCompanionAuthSessionSnapshot
    func desktop_network_models() async throws -> [DesktopCompanionNetworkModelSnapshot]
    func desktop_network_stats() async throws -> DesktopCompanionNetworkStatsSnapshot
    func desktop_account_summary() async throws -> DesktopCompanionAccountSnapshot
    func desktop_account_api_keys() async throws -> DesktopCompanionAccountAPIKeysResponse
    func desktop_link_account(_ request: DesktopCompanionAccountLinkRequest) async throws -> DesktopCompanionAccountSnapshot
    func desktop_create_account_api_key(label: String?) async throws -> DesktopCompanionAccountAPIKeyMintedResponse
    func desktop_revoke_account_api_key(key_id: String) async throws -> DesktopCompanionAccountAPIKeyRevokeResponse
    func desktop_sweep_account_device(device_id: String) async throws -> DesktopCompanionAccountSweepResponse
    func desktop_remove_account_device(device_id: String) async throws -> DesktopCompanionAccountSnapshot
    func desktop_send_account_wallet(_ request: DesktopCompanionWalletSendRequest) async throws -> DesktopCompanionAccountSnapshot
    func desktop_refresh_wallet() async throws -> DesktopCompanionAppSnapshot
    func desktop_send_device_wallet(_ request: DesktopCompanionWalletSendRequest) async throws -> DesktopCompanionAppSnapshot
}

public struct DesktopCompanionDeviceSnapshot: Codable, Sendable {
    public var display_name: String
    public var hardware: HardwareCapability
    public var gpu_backend: String?
    public var on_ac: Bool

    public init(display_name: String, hardware: HardwareCapability, gpu_backend: String?, on_ac: Bool) {
        self.display_name = display_name
        self.hardware = hardware
        self.gpu_backend = gpu_backend
        self.on_ac = on_ac
    }
}

public struct DesktopCompanionTransferSnapshot: Codable, Sendable {
    public var model_id: String
    public var phase: String
    public var bytes_downloaded: UInt64
    public var bytes_total: UInt64?
    public var bytes_per_sec: UInt64?
    public var eta_seconds: UInt64?

    public init(
        model_id: String,
        phase: String,
        bytes_downloaded: UInt64,
        bytes_total: UInt64?,
        bytes_per_sec: UInt64?,
        eta_seconds: UInt64?
    ) {
        self.model_id = model_id
        self.phase = phase
        self.bytes_downloaded = bytes_downloaded
        self.bytes_total = bytes_total
        self.bytes_per_sec = bytes_per_sec
        self.eta_seconds = eta_seconds
    }
}

public struct DesktopCompanionModelSnapshot: Codable, Sendable {
    public var id: String
    public var display_name: String
    public var required_ram_gb: Double
    public var size_gb: Double
    public var demand_rank: UInt32
    public var recommended: Bool
    public var downloaded: Bool
    public var loaded: Bool
    public var download_progress: Double?
    public var last_error: String?

    public init(
        id: String,
        display_name: String,
        required_ram_gb: Double,
        size_gb: Double,
        demand_rank: UInt32,
        recommended: Bool,
        downloaded: Bool,
        loaded: Bool,
        download_progress: Double?,
        last_error: String?
    ) {
        self.id = id
        self.display_name = display_name
        self.required_ram_gb = required_ram_gb
        self.size_gb = size_gb
        self.demand_rank = demand_rank
        self.recommended = recommended
        self.downloaded = downloaded
        self.loaded = loaded
        self.download_progress = download_progress
        self.last_error = last_error
    }
}

public struct DesktopCompanionPrivacyFilterSnapshot: Codable, Sendable {
    public var mode: String
    public var helper_status: String
    public var helper_detail: String?

    public init(mode: String, helper_status: String, helper_detail: String?) {
        self.mode = mode
        self.helper_status = helper_status
        self.helper_detail = helper_detail
    }
}

public struct DesktopCompanionWalletSnapshot: Codable, Sendable {
    public var current_device_id: String?
    public var estimated_session_credits: Int64
    public var credits_today: Int64
    public var completed_requests: UInt64
    public var availability_credits_per_tick: Int64
    public var availability_tick_seconds: UInt64
    public var availability_rate_credits_per_minute: Int64
    public var supplying_since: UInt64?
    public var gateway_balance_credits: Int64?
    public var gateway_total_earned_credits: Int64?
    public var gateway_total_spent_credits: Int64?
    public var gateway_usdc_cents: Int64?
    public var gateway_synced_at: UInt64?
    public var gateway_sync_error: String?

    public init(
        current_device_id: String?,
        estimated_session_credits: Int64,
        credits_today: Int64,
        completed_requests: UInt64,
        availability_credits_per_tick: Int64,
        availability_tick_seconds: UInt64,
        availability_rate_credits_per_minute: Int64,
        supplying_since: UInt64?,
        gateway_balance_credits: Int64?,
        gateway_total_earned_credits: Int64?,
        gateway_total_spent_credits: Int64?,
        gateway_usdc_cents: Int64?,
        gateway_synced_at: UInt64?,
        gateway_sync_error: String?
    ) {
        self.current_device_id = current_device_id
        self.estimated_session_credits = estimated_session_credits
        self.credits_today = credits_today
        self.completed_requests = completed_requests
        self.availability_credits_per_tick = availability_credits_per_tick
        self.availability_tick_seconds = availability_tick_seconds
        self.availability_rate_credits_per_minute = availability_rate_credits_per_minute
        self.supplying_since = supplying_since
        self.gateway_balance_credits = gateway_balance_credits
        self.gateway_total_earned_credits = gateway_total_earned_credits
        self.gateway_total_spent_credits = gateway_total_spent_credits
        self.gateway_usdc_cents = gateway_usdc_cents
        self.gateway_synced_at = gateway_synced_at
        self.gateway_sync_error = gateway_sync_error
    }
}

public struct DesktopCompanionWalletTransactionSnapshot: Codable, Sendable {
    public var id: Int64
    public var device_id: String
    public var type: String
    public var amount: Int64
    public var timestamp: Int64
    public var refRequestID: String?
    public var note: String?

    public init(
        id: Int64,
        device_id: String,
        type: String,
        amount: Int64,
        timestamp: Int64,
        refRequestID: String?,
        note: String?
    ) {
        self.id = id
        self.device_id = device_id
        self.type = type
        self.amount = amount
        self.timestamp = timestamp
        self.refRequestID = refRequestID
        self.note = note
    }
}

public struct DesktopCompanionAppSnapshot: Codable, Sendable {
    public var app_version: String
    public var service_state: String
    public var state_reason: String?
    public var device: DesktopCompanionDeviceSnapshot
    public var auth: RemoteAuthConfigSnapshot
    public var demand: RemoteDemandSnapshot
    public var privacy_filter: DesktopCompanionPrivacyFilterSnapshot
    public var wallet: DesktopCompanionWalletSnapshot
    public var wallet_transactions: [DesktopCompanionWalletTransactionSnapshot]
    public var loaded_model_id: String?
    public var models: [DesktopCompanionModelSnapshot]
    public var active_transfer: DesktopCompanionTransferSnapshot?

    public init(
        app_version: String,
        service_state: String,
        state_reason: String?,
        device: DesktopCompanionDeviceSnapshot,
        auth: RemoteAuthConfigSnapshot,
        demand: RemoteDemandSnapshot,
        privacy_filter: DesktopCompanionPrivacyFilterSnapshot,
        wallet: DesktopCompanionWalletSnapshot,
        wallet_transactions: [DesktopCompanionWalletTransactionSnapshot],
        loaded_model_id: String?,
        models: [DesktopCompanionModelSnapshot],
        active_transfer: DesktopCompanionTransferSnapshot?
    ) {
        self.app_version = app_version
        self.service_state = service_state
        self.state_reason = state_reason
        self.device = device
        self.auth = auth
        self.demand = demand
        self.privacy_filter = privacy_filter
        self.wallet = wallet
        self.wallet_transactions = wallet_transactions
        self.loaded_model_id = loaded_model_id
        self.models = models
        self.active_transfer = active_transfer
    }
}

public struct DesktopCompanionNetworkModelSnapshot: Codable, Sendable {
    public var id: String
    public var context_length: UInt32?
    public var device_count: UInt32
    public var ttft_ms_p50: UInt32?
    public var tps_p50: Float?
    public var pricing_prompt: String?
    public var pricing_completion: String?

    public init(
        id: String,
        context_length: UInt32?,
        device_count: UInt32,
        ttft_ms_p50: UInt32?,
        tps_p50: Float?,
        pricing_prompt: String?,
        pricing_completion: String?
    ) {
        self.id = id
        self.context_length = context_length
        self.device_count = device_count
        self.ttft_ms_p50 = ttft_ms_p50
        self.tps_p50 = tps_p50
        self.pricing_prompt = pricing_prompt
        self.pricing_completion = pricing_completion
    }
}

public struct DesktopCompanionNetworkStatsSnapshot: Codable, Sendable {
    public var total_devices: Int
    public var total_ram_gb: Double
    public var total_models: Int
    public var avg_ttft_ms: UInt32?
    public var avg_tps: Float?
    public var total_credits_earned: Int64
    public var total_credits_spent: Int64
    public var total_usdc_distributed_cents: Int64
}

public struct DesktopCompanionAccountLinkRequest: Codable, Sendable {
    public var accountUserID: String
    public var displayName: String?
    public var phone: String?
    public var email: String?
    public var githubUsername: String?
}

public struct DesktopCompanionAccountDeviceSnapshot: Codable, Sendable {
    public var device_id: String
    public var device_name: String?
    public var platform: String?
    public var linked_at: Int64
    public var last_seen: Int64
    public var wallet_balance_credits: Int64
    public var wallet_usdc_cents: Int64
}

public struct DesktopCompanionAccountLedgerSnapshot: Codable, Sendable {
    public var id: Int64
    public var account_user_id: String
    public var asset: String
    public var amount: Int64
    public var type: String
    public var timestamp: Int64
    public var device_id: String?
    public var note: String?
}

public struct DesktopCompanionAccountSnapshot: Codable, Sendable {
    public var account_user_id: String
    public var balance_credits: Int64
    public var usdc_cents: Int64
    public var display_name: String?
    public var phone: String?
    public var email: String?
    public var github_username: String?
    public var devices: [DesktopCompanionAccountDeviceSnapshot]
    public var transactions: [DesktopCompanionAccountLedgerSnapshot]
}

public struct DesktopCompanionAccountAPIKeySnapshot: Codable, Sendable {
    public var keyID: String
    public var tokenPreview: String
    public var label: String?
    public var createdAt: Int64
    public var lastUsedAt: Int64?
    public var revokedAt: Int64?
}

public struct DesktopCompanionAccountAPIKeysResponse: Codable, Sendable {
    public var keys: [DesktopCompanionAccountAPIKeySnapshot]
}

public struct DesktopCompanionAccountAPIKeyMintedResponse: Codable, Sendable {
    public var keyID: String
    public var token: String
    public var label: String?
    public var createdAt: Int64
}

public struct DesktopCompanionAccountAPIKeyRevokeResponse: Codable, Sendable {
    public var revoked: Bool
}

public struct DesktopCompanionAccountSweepResponse: Codable, Sendable {
    public var swept_credits: Int64
    public var swept_usdc_cents: Int64
    public var account: DesktopCompanionAccountSnapshot
}

public struct DesktopCompanionWalletSendRequest: Codable, Sendable {
    public var asset: String
    public var recipient: String
    public var amount: Int64
    public var memo: String?
}

public struct DesktopCompanionAuthSessionSnapshot: Codable, Sendable {
    public var user: DesktopCompanionAuthUserSnapshot
    public var identities: [DesktopCompanionAuthIdentitySnapshot]
    public var devices: [DesktopCompanionSupabaseDeviceSnapshot]

    public init(
        user: DesktopCompanionAuthUserSnapshot,
        identities: [DesktopCompanionAuthIdentitySnapshot],
        devices: [DesktopCompanionSupabaseDeviceSnapshot]
    ) {
        self.user = user
        self.identities = identities
        self.devices = devices
    }
}

public struct DesktopCompanionAuthUserSnapshot: Codable, Sendable {
    public var id: String
    public var phone: String?
    public var email: String?
    public var app_metadata: [String: String]?
    public var user_metadata: [String: String]?
    public var identities: [DesktopCompanionAuthIdentitySnapshot]

    public init(
        id: String,
        phone: String?,
        email: String?,
        app_metadata: [String: String]?,
        user_metadata: [String: String]?,
        identities: [DesktopCompanionAuthIdentitySnapshot]
    ) {
        self.id = id
        self.phone = phone
        self.email = email
        self.app_metadata = app_metadata
        self.user_metadata = user_metadata
        self.identities = identities
    }
}

public struct DesktopCompanionAuthIdentitySnapshot: Codable, Sendable {
    public var id: String?
    public var provider: String
    public var identity_data: [String: String]?
    public var email: String?

    public init(id: String?, provider: String, identity_data: [String: String]?, email: String?) {
        self.id = id
        self.provider = provider
        self.identity_data = identity_data
        self.email = email
    }
}

public struct DesktopCompanionSupabaseDeviceSnapshot: Codable, Sendable {
    public var id: String
    public var user_id: String
    public var device_name: String?
    public var platform: String?
    public var chip_name: String?
    public var ram_gb: Int64?
    public var wan_node_id: String?
    public var registered_at: String?
    public var last_seen: String?
    public var is_active: Bool?
}
