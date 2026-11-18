//! Localhost control API for the Windows/Linux desktop companion.
//!
//! Bound to `127.0.0.1` only. This server powers both the tray icon and the
//! embedded desktop companion UI. Legacy `/status`, `/pause`, and `/resume`
//! remain for back-compat with earlier tray-only pilots.
//!
//! Browser access policy (every route, including `OPTIONS`):
//!   * requests without an `Origin` header (tray native code, CLI, curl) are
//!     served as before;
//!   * requests with an `Origin` are served only for the bundled companion UI
//!     (`teale://localhost`, `http(s)://teale.localhost`) or the exact origin
//!     of `TEALE_DESKTOP_WEB_URL`; anything else gets 403, so a website open
//!     in the user's browser cannot read the device token or move funds;
//!   * the `Host` header must name loopback on the control port (DNS-rebinding
//!     guard).
//!
//! The shared web bundle calls the Mac LocalAPI paths (`/v1/desktop/app/*`);
//! they are served here as aliases of `/v1/app/*`.

use std::borrow::Cow;
use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use futures_util::StreamExt;
use serde::de::DeserializeOwned;
use serde::{Deserialize, Serialize};
use serde_json::json;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Mutex;
use tracing::{info, warn};
use url::Url;

use crate::account_session::{AccountSession, AccountSessionStore, ACCOUNT_SESSION_HEADER};
use crate::cluster::NodeRuntimeState;
use crate::config::LlamaConfig;
use crate::hardware::HardwareCapability;
use crate::model_registry::{PersistedRegistry, RegistryStore};
use crate::privacy_filter::{
    PreparedPrivacyRequest, PrivacyFilterMode, PrivacyFilterService, PrivacyFilterSnapshot,
    StreamingPlaceholderRestorer,
};
use crate::swap::SwapManager;
use crate::windows_model_catalog::{
    availability_credits_per_tick_for_id, compatible_models, context_for_model, model_by_id,
    recommended_model, WindowsCatalogModel, AVAILABILITY_TICK_SECONDS,
};
use teale_protocol::openai::ChatCompletionRequest;

const MAX_HTTP_BODY_BYTES: usize = 1024 * 1024;
const MAX_HTTP_HEADER_BYTES: usize = 16 * 1024;

/// Origins the bundled companion UI runs under: wry serves the custom
/// `teale://` protocol as `teale://localhost` (WebKitGTK) or as
/// `http(s)://teale.localhost` (WebView2 on Windows).
const BUNDLED_UI_ORIGINS: &[&str] = &[
    "teale://localhost",
    "http://teale.localhost",
    "https://teale.localhost",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServiceState {
    Starting,
    NeedsModel,
    Downloading,
    Loading,
    Offline,
    Serving,
    PausedUser,
    PausedBattery,
    Error,
}

impl ServiceState {
    fn as_str(self) -> &'static str {
        match self {
            ServiceState::Starting => "starting",
            ServiceState::NeedsModel => "needs_model",
            ServiceState::Downloading => "downloading",
            ServiceState::Loading => "loading",
            ServiceState::Offline => "offline",
            ServiceState::Serving => "serving",
            ServiceState::PausedUser => "paused_user",
            ServiceState::PausedBattery => "paused_battery",
            ServiceState::Error => "error",
        }
    }

    fn legacy_state(self) -> &'static str {
        match self {
            ServiceState::Serving => "supplying",
            ServiceState::Error => "error",
            _ => "paused",
        }
    }

    fn legacy_paused_reason(self) -> Option<&'static str> {
        match self {
            ServiceState::PausedUser => Some("user"),
            ServiceState::PausedBattery => Some("battery"),
            ServiceState::Downloading => Some("downloading"),
            ServiceState::Loading => Some("loading"),
            ServiceState::Offline => Some("offline"),
            ServiceState::NeedsModel => Some("needs_model"),
            ServiceState::Starting => Some("starting"),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct DeviceSnapshot {
    pub display_name: String,
    pub hardware: HardwareCapability,
    pub gpu_backend: Option<String>,
    pub on_ac: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct TransferSnapshot {
    pub model_id: String,
    pub phase: String,
    pub bytes_downloaded: u64,
    pub bytes_total: Option<u64>,
    pub bytes_per_sec: Option<u64>,
    pub eta_seconds: Option<u64>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ModelSnapshot {
    pub id: String,
    pub display_name: String,
    pub required_ram_gb: f64,
    pub size_gb: f64,
    pub demand_rank: u32,
    pub recommended: bool,
    pub downloaded: bool,
    pub loaded: bool,
    pub download_progress: Option<f64>,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct WalletSnapshot {
    pub current_device_id: Option<String>,
    pub estimated_session_credits: i64,
    pub credits_today: i64,
    pub completed_requests: u64,
    pub availability_credits_per_tick: i64,
    pub availability_tick_seconds: u64,
    pub availability_rate_credits_per_minute: i64,
    pub supplying_since: Option<u64>,
    pub gateway_balance_credits: Option<i64>,
    pub gateway_total_earned_credits: Option<i64>,
    pub gateway_total_spent_credits: Option<i64>,
    pub gateway_usdc_cents: Option<i64>,
    pub gateway_synced_at: Option<u64>,
    pub gateway_sync_error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WalletTransactionSnapshot {
    pub id: i64,
    pub device_id: String,
    #[serde(rename = "type")]
    pub type_: String,
    pub amount: i64,
    pub timestamp: i64,
    #[serde(rename = "refRequestID")]
    pub ref_request_id: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone)]
pub struct GatewayWalletState {
    pub device_id: String,
    pub balance_credits: i64,
    pub total_earned_credits: i64,
    pub total_spent_credits: i64,
    pub usdc_cents: i64,
    pub synced_at: u64,
}

/// Sign-in state for the companion UI. `configured` is the legacy Supabase
/// flag and is always false now: the UI signs in with the gateway email code
/// and hydrates from `gateway_account_user_id` / `gateway_email`.
#[derive(Debug, Clone, Serialize)]
pub struct AuthConfigSnapshot {
    pub configured: bool,
    pub gateway_account_user_id: Option<String>,
    pub gateway_email: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct DemandSnapshot {
    pub local_base_url: String,
    pub local_model_id: Option<String>,
    pub network_base_url: String,
    pub network_bearer_token: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkModelSnapshot {
    pub id: String,
    pub context_length: Option<u32>,
    pub device_count: u32,
    pub ttft_ms_p50: Option<u32>,
    pub tps_p50: Option<f32>,
    pub pricing_prompt: Option<String>,
    pub pricing_completion: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct NetworkStatsSnapshot {
    #[serde(alias = "totalDevices")]
    pub total_devices: usize,
    #[serde(alias = "totalRamGB")]
    pub total_ram_gb: f64,
    #[serde(alias = "totalModels")]
    pub total_models: usize,
    #[serde(alias = "avgTtftMs")]
    pub avg_ttft_ms: Option<u32>,
    #[serde(alias = "avgTps")]
    pub avg_tps: Option<f32>,
    #[serde(alias = "totalCreditsEarned")]
    pub total_credits_earned: i64,
    #[serde(alias = "totalCreditsSpent")]
    pub total_credits_spent: i64,
    #[serde(alias = "totalUsdcDistributedCents")]
    pub total_usdc_distributed_cents: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountSnapshot {
    pub account_user_id: String,
    pub balance_credits: i64,
    pub usdc_cents: i64,
    pub display_name: Option<String>,
    pub phone: Option<String>,
    pub email: Option<String>,
    pub github_username: Option<String>,
    pub devices: Vec<AccountDeviceSnapshot>,
    pub transactions: Vec<AccountLedgerSnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountDeviceSnapshot {
    pub device_id: String,
    pub device_name: Option<String>,
    pub platform: Option<String>,
    pub linked_at: i64,
    pub last_seen: i64,
    pub wallet_balance_credits: i64,
    pub wallet_usdc_cents: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountLedgerSnapshot {
    pub id: i64,
    pub account_user_id: String,
    pub asset: String,
    pub amount: i64,
    #[serde(rename = "type")]
    pub type_: String,
    pub timestamp: i64,
    pub device_id: Option<String>,
    pub note: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountApiKeySnapshot {
    #[serde(rename = "keyID")]
    pub key_id: String,
    #[serde(rename = "tokenPreview")]
    pub token_preview: String,
    pub label: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
    #[serde(rename = "lastUsedAt")]
    pub last_used_at: Option<i64>,
    #[serde(rename = "revokedAt")]
    pub revoked_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountApiKeysResponse {
    pub keys: Vec<AccountApiKeySnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountApiKeyMintedResponse {
    #[serde(rename = "keyID")]
    pub key_id: String,
    pub token: String,
    pub label: Option<String>,
    #[serde(rename = "createdAt")]
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountApiKeyRevokeResponse {
    pub revoked: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct AppSnapshot {
    pub app_version: String,
    /// Live relay-registration state of this node's earning path. The
    /// desktop/remote wallet views key relayConnected off this - fleet boxes
    /// run with the Swift WAN stack disabled, so the Swift-side relay status
    /// is always dark there.
    pub relay_connected: bool,
    pub service_state: String,
    pub state_reason: Option<String>,
    /// False while the user paused supply (tray Pause / companion toggle).
    pub supply_enabled: bool,
    pub device: DeviceSnapshot,
    pub auth: AuthConfigSnapshot,
    pub demand: DemandSnapshot,
    pub privacy_filter: PrivacyFilterSnapshot,
    pub wallet: WalletSnapshot,
    pub wallet_transactions: Vec<WalletTransactionSnapshot>,
    pub loaded_model_id: Option<String>,
    pub models: Vec<ModelSnapshot>,
    pub active_transfer: Option<TransferSnapshot>,
}

#[derive(Debug, Serialize)]
pub(crate) struct LegacyStatusDTO {
    state: String,
    supplying_since: Option<String>,
    requests_today: u64,
    credits_today: i64,
    on_ac: bool,
    paused_reason: Option<String>,
    /// 0-100, mirrors the heartbeat field the gateway scheduler sees. 0
    /// means the node is self-throttled (CPU-busy / idle-only gating).
    throttle_level: u32,
}

#[derive(Debug, Deserialize)]
struct ModelControlRequest {
    model: String,
}

#[derive(Debug, Deserialize)]
struct AccountLinkRequest {
    #[serde(rename = "accountUserID")]
    account_user_id: String,
    #[serde(rename = "displayName")]
    display_name: Option<String>,
    phone: Option<String>,
    email: Option<String>,
    #[serde(rename = "githubUsername")]
    github_username: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AccountDeviceControlRequest {
    #[serde(rename = "deviceID")]
    device_id: String,
}

#[derive(Debug, Deserialize)]
struct AccountApiKeyCreateRequest {
    label: Option<String>,
}

#[derive(Debug, Deserialize)]
struct AccountApiKeyRevokeRequest {
    #[serde(rename = "keyID")]
    key_id: String,
}

#[derive(Debug, Deserialize)]
struct SupplySetRequest {
    enabled: bool,
}

#[derive(Debug, Deserialize)]
struct EmailCodeRequest {
    email: String,
}

#[derive(Debug, Deserialize)]
struct EmailCodeVerifyRequest {
    email: String,
    code: String,
}

#[derive(Debug, Deserialize)]
struct GatewayEmailVerifyResponse {
    #[serde(rename = "sessionToken")]
    session_token: String,
    #[serde(rename = "accountUserID")]
    account_user_id: String,
    email: String,
    #[serde(rename = "expiresAt", default)]
    expires_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct GatewaySolvencyResponse {
    #[serde(rename = "treasuryAddress")]
    treasury_address: String,
    #[serde(rename = "explorerUrl")]
    explorer_url: String,
}

/// One key from the gateway's `GET /v1/keys`.
#[derive(Debug, Deserialize)]
struct GatewayApiKey {
    #[serde(rename = "keyID")]
    key_id: String,
    #[serde(default)]
    prefix: String,
    #[serde(default)]
    name: Option<String>,
    #[serde(rename = "createdAt", default)]
    created_at: i64,
    #[serde(rename = "lastUsedAt", default)]
    last_used_at: Option<i64>,
}

#[derive(Debug, Deserialize)]
struct GatewayApiKeyList {
    keys: Vec<GatewayApiKey>,
}

#[derive(Debug, Deserialize)]
struct GatewayApiKeyMinted {
    #[serde(flatten)]
    key: GatewayApiKey,
    token: String,
}

impl From<GatewayApiKey> for AccountApiKeySnapshot {
    fn from(key: GatewayApiKey) -> Self {
        let token_preview = if key.prefix.is_empty() {
            "-".to_string()
        } else {
            format!("{}...", key.prefix)
        };
        Self {
            key_id: key.key_id,
            token_preview,
            label: key.name,
            created_at: key.created_at,
            last_used_at: key.last_used_at,
            revoked_at: None,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ChatProvider {
    Local,
    Network,
    /// Route to a Private Inference Network peer (the prompt travels only
    /// on the encrypted device-to-device connection).
    Pin,
}

#[derive(Debug, Clone, Deserialize)]
struct AppChatRequest {
    provider: ChatProvider,
    #[serde(flatten)]
    request: ChatCompletionRequest,
}

#[derive(Debug, Clone, Deserialize)]
struct PrivacyFilterModeUpdateRequest {
    mode: PrivacyFilterMode,
}

#[derive(Debug, Serialize, Deserialize)]
struct AccountSweepResponse {
    swept_credits: i64,
    swept_usdc_cents: i64,
    account: AccountSnapshot,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct WalletSendRequest {
    asset: String,
    recipient: String,
    amount: i64,
    memo: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GatewayWalletBalanceResponse {
    #[serde(rename = "deviceID")]
    device_id: String,
    balance_credits: i64,
    total_earned_credits: i64,
    total_spent_credits: i64,
    usdc_cents: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct GatewayWalletTransactionsResponse {
    transactions: Vec<WalletTransactionSnapshot>,
}

#[derive(Debug)]
struct ParsedHttpRequest {
    method: String,
    path: String,
    host: Option<String>,
    origin: Option<String>,
    body: Vec<u8>,
}

#[derive(Debug, Clone)]
struct InFlightTransfer {
    model_id: String,
    phase: String,
    started_at: Instant,
    bytes_downloaded: u64,
    bytes_total: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct GatewayModelsResponse {
    data: Vec<GatewayModelEntry>,
}

#[derive(Debug, Deserialize)]
struct GatewayModelEntry {
    id: String,
    context_length: Option<u32>,
    pricing: Option<GatewayPricing>,
    metrics: Option<GatewayModelMetrics>,
    loaded_device_count: Option<u32>,
}

#[derive(Debug, Deserialize)]
struct GatewayPricing {
    prompt: String,
    completion: String,
}

#[derive(Debug, Deserialize)]
struct GatewayModelMetrics {
    ttft_ms_p50: Option<u32>,
    tps_p50: Option<f32>,
}

#[derive(Debug, Deserialize)]
struct GatewayNetworkResponse {
    devices: Vec<GatewayNetworkDevice>,
}

#[derive(Debug, Deserialize)]
struct GatewayNetworkDevice {
    #[serde(rename = "loadedModels")]
    loaded_models: Vec<String>,
    #[serde(rename = "isAvailable")]
    is_available: bool,
    #[serde(rename = "heartbeatStale")]
    heartbeat_stale: bool,
}

impl InFlightTransfer {
    fn snapshot(&self) -> TransferSnapshot {
        let elapsed = self.started_at.elapsed().as_secs().max(1);
        let bytes_per_sec = self.bytes_downloaded / elapsed;
        let eta_seconds = match (self.bytes_total, bytes_per_sec) {
            (Some(total), rate) if rate > 0 && total > self.bytes_downloaded => {
                Some((total - self.bytes_downloaded) / rate)
            }
            _ => None,
        };

        TransferSnapshot {
            model_id: self.model_id.clone(),
            phase: self.phase.clone(),
            bytes_downloaded: self.bytes_downloaded,
            bytes_total: self.bytes_total,
            bytes_per_sec: Some(bytes_per_sec),
            eta_seconds,
        }
    }
}

#[derive(Debug, Default, Clone)]
struct RuntimeInner {
    registry: PersistedRegistry,
    download_progress: HashMap<String, f64>,
    active_transfer: Option<InFlightTransfer>,
    loading_model_id: Option<String>,
    gateway_wallet: Option<GatewayWalletState>,
    gateway_device_token: Option<String>,
    wallet_transactions: Vec<WalletTransactionSnapshot>,
    gateway_wallet_error: Option<String>,
    last_fatal_error: Option<String>,
    initializing: bool,
    /// Gateway account session minted by the email-code sign-in.
    account_session: Option<AccountSession>,
}

/// Shared state between the node runtime and the companion app API.
#[derive(Clone)]
pub struct StatusState {
    pub requests_today: Arc<AtomicU64>,
    pub credits_today: Arc<std::sync::atomic::AtomicI64>,
    pub supplying_since: Arc<AtomicU64>,
    display_name: String,
    hardware: HardwareCapability,
    model_dir: PathBuf,
    registry_store: RegistryStore,
    swap: Arc<SwapManager>,
    llama_template: Option<LlamaConfig>,
    account_sessions: AccountSessionStore,
    relay_url: String,
    node_state: Arc<NodeRuntimeState>,
    relay_connected: Arc<AtomicBool>,
    privacy_filter: PrivacyFilterService,
    inner: Arc<Mutex<RuntimeInner>>,
    /// Private Inference Network runtime; None when PIN is not configured.
    pin: Arc<std::sync::RwLock<Option<Arc<crate::pin::runtime::PinRuntime>>>>,
}

impl StatusState {
    pub fn new(
        display_name: String,
        hardware: HardwareCapability,
        model_dir: PathBuf,
        registry_store: RegistryStore,
        registry: PersistedRegistry,
        swap: Arc<SwapManager>,
        llama_template: Option<LlamaConfig>,
        account_sessions: AccountSessionStore,
        relay_url: String,
        node_state: Arc<NodeRuntimeState>,
    ) -> Self {
        let initializing = registry.active_model_id.is_none();
        let account_session = account_sessions.load();
        if account_session.is_some() {
            info!(
                "loaded gateway account session from {}",
                account_sessions.path().display()
            );
        }
        Self {
            requests_today: Arc::new(AtomicU64::new(0)),
            credits_today: Arc::new(std::sync::atomic::AtomicI64::new(0)),
            supplying_since: Arc::new(AtomicU64::new(0)),
            display_name,
            hardware,
            model_dir,
            registry_store,
            swap,
            llama_template,
            account_sessions,
            relay_url,
            node_state,
            relay_connected: Arc::new(AtomicBool::new(false)),
            privacy_filter: PrivacyFilterService::new().expect("privacy filter client init"),
            pin: Arc::new(std::sync::RwLock::new(None)),
            inner: Arc::new(Mutex::new(RuntimeInner {
                registry,
                initializing,
                account_session,
                ..Default::default()
            })),
        }
    }

    pub fn mark_supplying_now(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.supplying_since.store(now, Ordering::SeqCst);
    }

    pub async fn clear_starting(&self) {
        self.inner.lock().await.initializing = false;
    }

    pub async fn snapshot(&self) -> AppSnapshot {
        let current_model_id = self.swap.current_model_id().await;
        let backend_ready = self.swap.is_ready().await;
        let recommended = recommended_model(self.hardware.total_ram_gb).map(|m| m.id.to_string());
        let on_ac = self.node_state.on_ac_power.load(Ordering::SeqCst);
        let relay_connected = self.relay_connected.load(Ordering::SeqCst);
        let inner = self.inner.lock().await.clone();
        let service_state = self.resolve_state(
            &inner,
            current_model_id.as_deref(),
            on_ac,
            backend_ready,
            relay_connected,
        );
        let state_reason = self.state_reason(&inner, service_state, backend_ready, relay_connected);
        let privacy_filter = self
            .privacy_filter
            .snapshot(inner.registry.privacy_filter_mode)
            .await;

        AppSnapshot {
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            relay_connected,
            service_state: service_state.as_str().to_string(),
            state_reason,
            supply_enabled: !self.node_state.user_paused.load(Ordering::SeqCst),
            device: DeviceSnapshot {
                display_name: self.display_name.clone(),
                hardware: self.hardware.clone(),
                gpu_backend: self.hardware.gpu_backend.clone(),
                on_ac,
            },
            auth: auth_snapshot(&inner),
            demand: self.demand_snapshot(&inner, current_model_id.clone()),
            privacy_filter,
            wallet: self.wallet_snapshot(&inner, service_state, current_model_id.as_deref()),
            wallet_transactions: inner.wallet_transactions.clone(),
            loaded_model_id: current_model_id.clone(),
            models: compatible_models(self.hardware.total_ram_gb)
                .into_iter()
                .map(|model| {
                    self.model_snapshot(
                        &inner,
                        &model,
                        current_model_id.as_deref(),
                        recommended.as_deref(),
                    )
                })
                .collect(),
            active_transfer: inner
                .active_transfer
                .as_ref()
                .map(InFlightTransfer::snapshot),
        }
    }

    pub(crate) async fn legacy_status(&self) -> LegacyStatusDTO {
        let current_model_id = self.swap.current_model_id().await;
        let backend_ready = self.swap.is_ready().await;
        let on_ac = self.node_state.on_ac_power.load(Ordering::SeqCst);
        let relay_connected = self.relay_connected.load(Ordering::SeqCst);
        let inner = self.inner.lock().await;
        let state = self.resolve_state(
            &inner,
            current_model_id.as_deref(),
            on_ac,
            backend_ready,
            relay_connected,
        );
        LegacyStatusDTO {
            state: state.legacy_state().to_string(),
            supplying_since: self.supplying_since_secs().map(|secs| secs.to_string()),
            requests_today: self.live_requests_today(),
            credits_today: self.live_credits_today(state, current_model_id.as_deref()),
            on_ac,
            paused_reason: state
                .legacy_paused_reason()
                .map(str::to_string)
                .or_else(|| {
                    let throttled = self.node_state.throttle_level.load(Ordering::SeqCst) == 0;
                    (throttled && on_ac).then(|| "system-busy".to_string())
                }),
            throttle_level: self.node_state.throttle_level.load(Ordering::SeqCst),
        }
    }

    pub async fn pause_supply(&self) {
        self.node_state.user_paused.store(true, Ordering::SeqCst);
    }

    pub async fn resume_supply(&self) {
        self.node_state.user_paused.store(false, Ordering::SeqCst);
    }

    pub fn set_pin_runtime(&self, runtime: Arc<crate::pin::runtime::PinRuntime>) {
        *self.pin.write().expect("pin lock") = Some(runtime);
    }

    pub fn pin_runtime(&self) -> Option<Arc<crate::pin::runtime::PinRuntime>> {
        self.pin.read().expect("pin lock").clone()
    }

    pub(crate) fn node_state_handle(&self) -> Arc<NodeRuntimeState> {
        self.node_state.clone()
    }

    /// Models with a verified file on disk (for PIN policy reconciliation).
    pub async fn downloaded_model_ids(&self) -> Vec<String> {
        let inner = self.inner.lock().await;
        inner
            .registry
            .models
            .iter()
            .filter(|(_, record)| {
                record
                    .downloaded_file_path
                    .as_deref()
                    .is_some_and(|path| Path::new(path).exists())
            })
            .map(|(id, _)| id.clone())
            .collect()
    }

    pub async fn start_download(self: &Arc<Self>, model_id: &str) -> anyhow::Result<()> {
        let model = self.validate_catalog_model(model_id)?;

        {
            let mut inner = self.inner.lock().await;
            if let Some(transfer) = &inner.active_transfer {
                if transfer.model_id != model.id {
                    anyhow::bail!("another model download is already in progress");
                }
                return Ok(());
            }
            let record = inner
                .registry
                .models
                .entry(model.id.to_string())
                .or_default();
            if record
                .downloaded_file_path
                .as_deref()
                .is_some_and(|path| Path::new(path).exists())
            {
                return Ok(());
            }
            record.last_error = None;
            inner.last_fatal_error = None;
            inner.download_progress.insert(model.id.to_string(), 0.0);
            inner.active_transfer = Some(InFlightTransfer {
                model_id: model.id.to_string(),
                phase: "downloading".to_string(),
                started_at: Instant::now(),
                bytes_downloaded: 0,
                bytes_total: None,
            });
            self.registry_store.save(&inner.registry)?;
        }

        let state = Arc::clone(self);
        tokio::spawn(async move {
            if let Err(e) = state.download_model_task(model).await {
                warn!("download task failed: {e}");
            }
        });

        Ok(())
    }

    pub async fn load_model(&self, model_id: &str) -> anyhow::Result<()> {
        let model = self.validate_catalog_model(model_id)?;
        let path = {
            let mut inner = self.inner.lock().await;
            let record = inner
                .registry
                .models
                .entry(model.id.to_string())
                .or_default();
            let Some(path) = record.downloaded_file_path.clone() else {
                anyhow::bail!("model is not downloaded");
            };
            if !Path::new(&path).exists() {
                anyhow::bail!("downloaded model file is missing");
            }
            record.last_error = None;
            inner.loading_model_id = Some(model.id.to_string());
            inner.last_fatal_error = None;
            self.registry_store.save(&inner.registry)?;
            path
        };

        let request_id = uuid::Uuid::new_v4().to_string();
        let context_size = context_for_model(
            &model,
            self.hardware.total_ram_gb,
            self.hardware.gpu_backend.as_deref(),
        );
        let result = self
            .swap
            .load_local_model(request_id, model.id.to_string(), path, Some(context_size))
            .await;

        let mut inner = self.inner.lock().await;
        inner.loading_model_id = None;
        match result {
            Ok(_) => {
                inner.registry.active_model_id = Some(model.id.to_string());
                inner.last_fatal_error = None;
                self.registry_store.save(&inner.registry)?;
                self.mark_supplying_now();
                Ok(())
            }
            Err(err) => {
                inner.last_fatal_error = Some(err.reason.clone());
                inner
                    .registry
                    .models
                    .entry(model.id.to_string())
                    .or_default()
                    .last_error = Some(err.reason.clone());
                self.registry_store.save(&inner.registry)?;
                anyhow::bail!(err.reason)
            }
        }
    }

    pub async fn unload_model(&self) -> anyhow::Result<()> {
        self.swap.unload_current().await;
        let mut inner = self.inner.lock().await;
        inner.registry.active_model_id = None;
        inner.last_fatal_error = None;
        self.registry_store.save(&inner.registry)?;
        Ok(())
    }

    pub async fn mark_on_ac_power(&self, on_ac: bool) {
        self.node_state.on_ac_power.store(on_ac, Ordering::SeqCst);
    }

    pub async fn set_last_error(&self, message: impl Into<String>) {
        self.inner.lock().await.last_fatal_error = Some(message.into());
    }

    pub async fn clear_last_error(&self) {
        self.inner.lock().await.last_fatal_error = None;
    }

    pub fn mark_relay_connected(&self, connected: bool) {
        self.relay_connected.store(connected, Ordering::SeqCst);
    }

    pub async fn set_gateway_wallet(
        &self,
        wallet: GatewayWalletState,
        device_token: Option<String>,
        transactions: Vec<WalletTransactionSnapshot>,
    ) {
        let mut inner = self.inner.lock().await;
        inner.gateway_wallet = Some(wallet);
        inner.gateway_device_token = device_token;
        inner.wallet_transactions = transactions;
        inner.gateway_wallet_error = None;
    }

    pub async fn set_gateway_wallet_error(&self, message: impl Into<String>) {
        self.inner.lock().await.gateway_wallet_error = Some(message.into());
    }

    pub async fn privacy_filter_mode(&self) -> PrivacyFilterMode {
        self.inner.lock().await.registry.privacy_filter_mode
    }

    pub async fn set_privacy_filter_mode(&self, mode: PrivacyFilterMode) -> anyhow::Result<()> {
        let mut inner = self.inner.lock().await;
        inner.registry.privacy_filter_mode = mode;
        self.registry_store.save(&inner.registry)?;
        Ok(())
    }

    fn validate_catalog_model(&self, model_id: &str) -> anyhow::Result<WindowsCatalogModel> {
        let Some(model) = model_by_id(model_id) else {
            anyhow::bail!("unknown model id");
        };
        if model.required_ram_gb > self.hardware.total_ram_gb {
            anyhow::bail!("model requires more RAM than this device has");
        }
        Ok(model)
    }

    fn model_snapshot(
        &self,
        inner: &RuntimeInner,
        model: &WindowsCatalogModel,
        loaded_model_id: Option<&str>,
        recommended_id: Option<&str>,
    ) -> ModelSnapshot {
        let record = inner.registry.models.get(model.id);
        let downloaded = record
            .and_then(|r| r.downloaded_file_path.as_deref())
            .is_some_and(|path| Path::new(path).exists());
        ModelSnapshot {
            id: model.id.to_string(),
            display_name: model.display_name.to_string(),
            required_ram_gb: model.required_ram_gb,
            size_gb: model.size_gb,
            demand_rank: model.demand_rank,
            recommended: recommended_id == Some(model.id),
            downloaded,
            loaded: loaded_model_id == Some(model.id),
            download_progress: inner.download_progress.get(model.id).copied(),
            last_error: record.and_then(|r| r.last_error.clone()),
        }
    }

    fn resolve_state(
        &self,
        inner: &RuntimeInner,
        loaded_model_id: Option<&str>,
        on_ac: bool,
        backend_ready: bool,
        relay_connected: bool,
    ) -> ServiceState {
        if inner.initializing {
            return ServiceState::Starting;
        }
        if inner.active_transfer.is_some() {
            return ServiceState::Downloading;
        }
        if inner.loading_model_id.is_some() {
            return ServiceState::Loading;
        }
        if self.node_state.user_paused.load(Ordering::SeqCst) {
            return ServiceState::PausedUser;
        }
        if self.node_state.battery_gated && !on_ac {
            return ServiceState::PausedBattery;
        }
        if loaded_model_id.is_some() {
            if !backend_ready || !relay_connected {
                return ServiceState::Offline;
            }
            return ServiceState::Serving;
        }
        if inner.last_fatal_error.is_some() {
            return ServiceState::Error;
        }
        ServiceState::NeedsModel
    }

    fn state_reason(
        &self,
        inner: &RuntimeInner,
        state: ServiceState,
        backend_ready: bool,
        relay_connected: bool,
    ) -> Option<String> {
        match state {
            ServiceState::Starting => Some("Teale is starting up.".to_string()),
            ServiceState::NeedsModel => Some("Download a model to start supplying.".to_string()),
            ServiceState::Downloading => inner
                .active_transfer
                .as_ref()
                .map(|transfer| format!("Downloading {}.", transfer.model_id)),
            ServiceState::Loading => inner
                .loading_model_id
                .as_ref()
                .map(|id| format!("Loading {}.", id)),
            ServiceState::Offline => {
                if !backend_ready {
                    Some("Model is loaded, but the local backend is not ready yet.".to_string())
                } else if !relay_connected {
                    Some(
                        inner.last_fatal_error.clone().unwrap_or_else(|| {
                            "Relay is offline. Waiting to reconnect.".to_string()
                        }),
                    )
                } else {
                    Some("Teale is offline.".to_string())
                }
            }
            ServiceState::Serving => Some("Ready to serve inference.".to_string()),
            ServiceState::PausedUser => Some("Supply is paused by you.".to_string()),
            ServiceState::PausedBattery => Some("Plug in AC power to resume supply.".to_string()),
            ServiceState::Error => inner.last_fatal_error.clone(),
        }
    }

    fn wallet_snapshot(
        &self,
        inner: &RuntimeInner,
        service_state: ServiceState,
        current_model_id: Option<&str>,
    ) -> WalletSnapshot {
        let (availability_credits_per_tick, availability_rate_credits_per_minute) =
            current_model_id
                .map(|model_id| {
                    let per_tick = availability_credits_per_tick_for_id(model_id);
                    (per_tick, per_tick * (60 / AVAILABILITY_TICK_SECONDS) as i64)
                })
                .unwrap_or((0, 0));

        WalletSnapshot {
            current_device_id: inner
                .gateway_wallet
                .as_ref()
                .map(|wallet| wallet.device_id.clone()),
            estimated_session_credits: self
                .estimated_availability_credits(service_state, current_model_id),
            credits_today: self.live_credits_today(service_state, current_model_id),
            completed_requests: self.live_requests_today(),
            availability_credits_per_tick,
            availability_tick_seconds: AVAILABILITY_TICK_SECONDS,
            availability_rate_credits_per_minute,
            supplying_since: self.supplying_since_secs(),
            gateway_balance_credits: inner
                .gateway_wallet
                .as_ref()
                .map(|wallet| wallet.balance_credits),
            gateway_total_earned_credits: inner
                .gateway_wallet
                .as_ref()
                .map(|wallet| wallet.total_earned_credits),
            gateway_total_spent_credits: inner
                .gateway_wallet
                .as_ref()
                .map(|wallet| wallet.total_spent_credits),
            gateway_usdc_cents: inner
                .gateway_wallet
                .as_ref()
                .map(|wallet| wallet.usdc_cents),
            gateway_synced_at: inner.gateway_wallet.as_ref().map(|wallet| wallet.synced_at),
            gateway_sync_error: inner.gateway_wallet_error.clone(),
        }
    }

    fn demand_snapshot(
        &self,
        inner: &RuntimeInner,
        local_model_id: Option<String>,
    ) -> DemandSnapshot {
        let local_port = self
            .llama_template
            .as_ref()
            .map(|cfg| cfg.port)
            .unwrap_or(11436);
        DemandSnapshot {
            local_base_url: format!("http://127.0.0.1:{local_port}/v1"),
            local_model_id,
            network_base_url: relay_to_gateway_base_url(&self.relay_url),
            network_bearer_token: inner.gateway_device_token.clone(),
        }
    }

    async fn network_models_snapshot(&self) -> anyhow::Result<Vec<NetworkModelSnapshot>> {
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let models_url = format!("{gateway_base_url}/models");
        let network_url = format!("{gateway_base_url}/network");

        let client = gateway_client(Duration::from_secs(10))?;

        let models = client
            .get(&models_url)
            .send()
            .await
            .with_context(|| format!("GET {models_url}"))?
            .error_for_status()
            .with_context(|| format!("gateway models request failed at {models_url}"))?
            .json::<GatewayModelsResponse>()
            .await
            .context("decode gateway models response")?;

        let device_token = {
            let inner = self.inner.lock().await;
            inner.gateway_device_token.clone()
        };

        let mut device_counts = HashMap::<String, u32>::new();
        if let Some(token) = device_token {
            if let Ok(response) = client.get(&network_url).bearer_auth(token).send().await {
                if let Ok(response) = response.error_for_status() {
                    if let Ok(network) = response.json::<GatewayNetworkResponse>().await {
                        for device in network.devices {
                            if !device.is_available || device.heartbeat_stale {
                                continue;
                            }
                            for model_id in device.loaded_models {
                                *device_counts.entry(model_id).or_insert(0) += 1;
                            }
                        }
                    }
                }
            }
        }

        Ok(models
            .data
            .into_iter()
            .map(|model| NetworkModelSnapshot {
                device_count: std::cmp::max(
                    model.loaded_device_count.unwrap_or(0),
                    device_counts.get(&model.id).copied().unwrap_or(0),
                ),
                ttft_ms_p50: model
                    .metrics
                    .as_ref()
                    .and_then(|metrics| metrics.ttft_ms_p50),
                tps_p50: model.metrics.as_ref().and_then(|metrics| metrics.tps_p50),
                pricing_prompt: model.pricing.as_ref().map(|pricing| pricing.prompt.clone()),
                pricing_completion: model
                    .pricing
                    .as_ref()
                    .map(|pricing| pricing.completion.clone()),
                id: model.id,
                context_length: model.context_length,
            })
            .collect())
    }

    async fn network_stats_snapshot(&self) -> anyhow::Result<NetworkStatsSnapshot> {
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/network/stats");
        let client = gateway_client(Duration::from_secs(10))?;
        client
            .get(&url)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?
            .error_for_status()
            .with_context(|| format!("network stats request failed at {url}"))?
            .json::<NetworkStatsSnapshot>()
            .await
            .context("decode network stats response")
    }

    async fn request_email_code(&self, email: &str) -> anyhow::Result<serde_json::Value> {
        let email = email.trim();
        if email.is_empty() {
            anyhow::bail!("email is required");
        }
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/auth/email/request");
        let client = gateway_client(Duration::from_secs(20))?;
        let response = client
            .post(&url)
            .json(&json!({ "email": email }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        gateway_ok(response, "email code request")
            .await?
            .json::<serde_json::Value>()
            .await
            .context("decode email code request response")
    }

    /// Consume an email code, persist the minted gateway session (the link
    /// ownership proof) and answer in the shape the web bundle expects:
    /// `{ accountUserID, email }`.
    async fn verify_email_code(
        &self,
        payload: EmailCodeVerifyRequest,
    ) -> anyhow::Result<serde_json::Value> {
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/auth/email/verify");
        let device_id = {
            let inner = self.inner.lock().await;
            inner
                .gateway_wallet
                .as_ref()
                .map(|wallet| wallet.device_id.clone())
        };
        let client = gateway_client(Duration::from_secs(20))?;
        let response = client
            .post(&url)
            .json(&json!({
                "email": payload.email.trim(),
                "code": payload.code.trim(),
                "deviceId": device_id,
                "deviceName": self.display_name,
            }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        let verified = gateway_ok(response, "email code verify")
            .await?
            .json::<GatewayEmailVerifyResponse>()
            .await
            .context("decode email code verify response")?;

        let session = AccountSession {
            session_token: verified.session_token,
            account_user_id: verified.account_user_id.clone(),
            email: Some(verified.email.clone()),
            expires_at: verified.expires_at,
        };
        self.account_sessions
            .save(&session)
            .context("persist gateway account session")?;
        self.inner.lock().await.account_session = Some(session);

        Ok(json!({
            "accountUserID": verified.account_user_id,
            "email": verified.email,
        }))
    }

    /// Revoke the gateway session (best effort) and forget it locally.
    async fn sign_out(&self) {
        let session = self.inner.lock().await.account_session.take();
        if let Some(session) = session {
            let url = format!("{}/auth/logout", relay_to_gateway_base_url(&self.relay_url));
            match gateway_client(Duration::from_secs(10)) {
                Ok(client) => {
                    if let Err(err) = client
                        .post(&url)
                        .bearer_auth(&session.session_token)
                        .send()
                        .await
                    {
                        warn!("gateway session revoke failed: {err}");
                    }
                }
                Err(err) => warn!("gateway session revoke skipped: {err:#}"),
            }
        }
        if let Err(err) = self.account_sessions.clear() {
            warn!("could not remove the persisted account session: {err:#}");
        }
    }

    async fn link_account(&self, payload: AccountLinkRequest) -> anyhow::Result<AccountSnapshot> {
        let token = self.gateway_device_token().await?;
        let session_token = self
            .inner
            .lock()
            .await
            .account_session
            .as_ref()
            .map(|session| session.session_token.clone());
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/link");
        let client = gateway_client(Duration::from_secs(15))?;
        let body = json!({
            "accountUserID": payload.account_user_id,
            "deviceName": self.display_name,
            "platform": std::env::consts::OS,
            "displayName": payload.display_name,
            "phone": payload.phone,
            "email": payload.email,
            "githubUsername": payload.github_username,
        });
        let mut request = client.post(&url).bearer_auth(token).json(&body);
        // Ownership proof for the gateway (see account_session.rs). Without
        // it the gateway only allows linking to a brand-new account.
        if let Some(session_token) = session_token {
            request = request.header(ACCOUNT_SESSION_HEADER, session_token);
        }
        let response = request
            .send()
            .await
            .with_context(|| format!("POST {url} (account link)"))?;
        gateway_ok(response, "account link")
            .await?
            .json::<AccountSnapshot>()
            .await
            .context("decode account link response")
    }

    async fn request_withdrawal(
        &self,
        payload: serde_json::Value,
    ) -> anyhow::Result<serde_json::Value> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/wallet/withdraw");
        let client = gateway_client(Duration::from_secs(20))?;
        let response = client
            .post(&url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        let record = gateway_ok(response, "withdrawal request")
            .await?
            .json::<serde_json::Value>()
            .await
            .context("decode withdrawal response")?;
        if let Err(err) = self.refresh_gateway_wallet_snapshot().await {
            warn!("wallet refresh after withdrawal failed: {err:#}");
        }
        Ok(record)
    }

    async fn account_withdrawals(&self) -> anyhow::Result<serde_json::Value> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/wallet/withdrawals");
        let client = gateway_client(Duration::from_secs(10))?;
        let response = client
            .get(&url)
            .bearer_auth(token)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            anyhow::bail!("account not linked");
        }
        gateway_ok(response, "withdrawals")
            .await?
            .json::<serde_json::Value>()
            .await
            .context("decode withdrawals response")
    }

    async fn deposit_info(&self) -> anyhow::Result<serde_json::Value> {
        let url = format!("{}/solvency", relay_to_gateway_base_url(&self.relay_url));
        let client = gateway_client(Duration::from_secs(10))?;
        let response = client
            .get(&url)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        let solvency = gateway_ok(response, "solvency")
            .await?
            .json::<GatewaySolvencyResponse>()
            .await
            .context("decode solvency response")?;
        let account = self.account_snapshot().await?;
        Ok(json!({
            "treasuryAddress": solvency.treasury_address,
            "memo": format!("teale:deposit:{}", account.account_user_id),
            "explorerUrl": solvency.explorer_url,
        }))
    }

    async fn account_snapshot(&self) -> anyhow::Result<AccountSnapshot> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/summary");
        let client = gateway_client(Duration::from_secs(10))?;
        let response = client
            .get(&url)
            .bearer_auth(token)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            anyhow::bail!("account not linked");
        }
        response
            .error_for_status()
            .with_context(|| format!("account summary failed at {url}"))?
            .json::<AccountSnapshot>()
            .await
            .context("decode account summary response")
    }

    async fn sweep_account_device(&self, device_id: &str) -> anyhow::Result<AccountSweepResponse> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/sweep");
        let client = gateway_client(Duration::from_secs(20))?;
        let response = client
            .post(&url)
            .bearer_auth(token)
            .json(&json!({ "deviceID": device_id }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        response
            .error_for_status()
            .with_context(|| format!("account sweep failed at {url}"))?
            .json::<AccountSweepResponse>()
            .await
            .context("decode account sweep response")
    }

    async fn remove_account_device(&self, device_id: &str) -> anyhow::Result<AccountSnapshot> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/devices/remove");
        let client = gateway_client(Duration::from_secs(10))?;
        let response = client
            .post(&url)
            .bearer_auth(token)
            .json(&json!({ "deviceID": device_id }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        response
            .error_for_status()
            .with_context(|| format!("remove device failed at {url}"))?
            .json::<AccountSnapshot>()
            .await
            .context("decode remove device response")
    }

    async fn refresh_gateway_wallet_snapshot(&self) -> anyhow::Result<()> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let client = gateway_client(Duration::from_secs(20))?;

        let balance_url = format!("{gateway_base_url}/wallet/balance");
        let balance = client
            .get(&balance_url)
            .bearer_auth(&token)
            .send()
            .await
            .with_context(|| format!("GET {balance_url}"))?
            .error_for_status()
            .with_context(|| format!("wallet balance request failed at {balance_url}"))?
            .json::<GatewayWalletBalanceResponse>()
            .await
            .context("decode wallet balance response")?;

        let tx_url = format!("{gateway_base_url}/wallet/transactions?limit=25");
        let transactions = client
            .get(&tx_url)
            .bearer_auth(&token)
            .send()
            .await
            .with_context(|| format!("GET {tx_url}"))?
            .error_for_status()
            .with_context(|| format!("wallet transactions request failed at {tx_url}"))?
            .json::<GatewayWalletTransactionsResponse>()
            .await
            .context("decode wallet transactions response")?;

        self.set_gateway_wallet(
            GatewayWalletState {
                device_id: balance.device_id,
                balance_credits: balance.balance_credits,
                total_earned_credits: balance.total_earned_credits,
                total_spent_credits: balance.total_spent_credits,
                usdc_cents: balance.usdc_cents,
                synced_at: SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0),
            },
            Some(token),
            transactions.transactions,
        )
        .await;

        Ok(())
    }

    // API keys live under the gateway's `/v1/keys` (there is no
    // `/v1/account/api-keys`); map them to the snapshot shape the web
    // bundle renders (`keyID`, `tokenPreview`, `label`).
    async fn account_api_keys(&self) -> anyhow::Result<AccountApiKeysResponse> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/keys");
        let client = gateway_client(Duration::from_secs(10))?;
        let response = client
            .get(&url)
            .bearer_auth(token)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        if response.status() == reqwest::StatusCode::NOT_FOUND {
            anyhow::bail!("account not linked");
        }
        let list = gateway_ok(response, "account api key list")
            .await?
            .json::<GatewayApiKeyList>()
            .await
            .context("decode account api key list response")?;
        Ok(AccountApiKeysResponse {
            keys: list.keys.into_iter().map(Into::into).collect(),
        })
    }

    async fn create_account_api_key(
        &self,
        payload: AccountApiKeyCreateRequest,
    ) -> anyhow::Result<AccountApiKeyMintedResponse> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/keys");
        let client = gateway_client(Duration::from_secs(15))?;
        let name = payload
            .label
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty());
        let response = client
            .post(&url)
            .bearer_auth(token)
            .json(&json!({ "name": name }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        let minted = gateway_ok(response, "account api key create")
            .await?
            .json::<GatewayApiKeyMinted>()
            .await
            .context("decode account api key create response")?;
        Ok(AccountApiKeyMintedResponse {
            key_id: minted.key.key_id,
            token: minted.token,
            label: minted.key.name,
            created_at: minted.key.created_at,
        })
    }

    async fn revoke_account_api_key(
        &self,
        key_id: &str,
    ) -> anyhow::Result<AccountApiKeyRevokeResponse> {
        if !is_safe_path_segment(key_id) {
            anyhow::bail!("invalid key id");
        }
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/keys/{key_id}");
        let client = gateway_client(Duration::from_secs(10))?;
        let response = client
            .delete(&url)
            .bearer_auth(token)
            .send()
            .await
            .with_context(|| format!("DELETE {url}"))?;
        gateway_ok(response, "account api key revoke").await?;
        Ok(AccountApiKeyRevokeResponse { revoked: true })
    }

    async fn force_refresh_gateway_wallet(&self) -> anyhow::Result<AppSnapshot> {
        self.refresh_gateway_wallet_snapshot().await?;
        Ok(self.snapshot().await)
    }

    async fn send_device_wallet(&self, payload: WalletSendRequest) -> anyhow::Result<AppSnapshot> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/wallet/send");
        let client = gateway_client(Duration::from_secs(20))?;
        client
            .post(&url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
            .with_context(|| format!("POST {url}"))?
            .error_for_status()
            .with_context(|| format!("wallet send failed at {url}"))?;
        self.refresh_gateway_wallet_snapshot().await?;
        Ok(self.snapshot().await)
    }

    async fn send_account_wallet(
        &self,
        payload: WalletSendRequest,
    ) -> anyhow::Result<AccountSnapshot> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/send");
        let client = gateway_client(Duration::from_secs(20))?;
        client
            .post(&url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
            .with_context(|| format!("POST {url}"))?
            .error_for_status()
            .with_context(|| format!("account send failed at {url}"))?;
        self.refresh_gateway_wallet_snapshot().await?;
        self.account_snapshot().await
    }

    async fn gateway_device_token(&self) -> anyhow::Result<String> {
        let inner = self.inner.lock().await;
        inner
            .gateway_device_token
            .clone()
            .filter(|token| !token.trim().is_empty())
            .ok_or_else(|| anyhow::anyhow!("waiting for the gateway device token"))
    }

    fn supplying_since_secs(&self) -> Option<u64> {
        match self.supplying_since.load(Ordering::SeqCst) {
            0 => None,
            secs => Some(secs),
        }
    }

    fn live_requests_today(&self) -> u64 {
        self.requests_today
            .load(Ordering::SeqCst)
            .max(self.node_state.completed_requests.load(Ordering::SeqCst))
    }

    fn live_credits_today(
        &self,
        service_state: ServiceState,
        current_model_id: Option<&str>,
    ) -> i64 {
        self.credits_today
            .load(Ordering::SeqCst)
            .max(self.estimated_availability_credits(service_state, current_model_id))
    }

    fn estimated_availability_credits(
        &self,
        service_state: ServiceState,
        current_model_id: Option<&str>,
    ) -> i64 {
        if service_state != ServiceState::Serving {
            return 0;
        }

        // Models missing from the local catalog (e.g. fleet models served
        // from Mac nodes) still earn availability display at the floor rate
        // rather than reporting a hard 0; the gateway ledger remains the
        // source of truth for actual earnings.
        let Some(credits_per_tick) = current_model_id.map(availability_credits_per_tick_for_id)
        else {
            return 0;
        };

        let Some(supplying_since) = self.supplying_since_secs() else {
            return 0;
        };

        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(supplying_since);
        let elapsed_ticks = now
            .saturating_sub(supplying_since)
            .div_euclid(AVAILABILITY_TICK_SECONDS);
        elapsed_ticks as i64 * credits_per_tick
    }

    async fn download_model_task(
        self: Arc<Self>,
        model: WindowsCatalogModel,
    ) -> anyhow::Result<()> {
        let final_path = self.model_dir.join(model.file_name);
        tokio::fs::create_dir_all(&self.model_dir).await?;
        let client = download_client()?;

        let mut errors = Vec::new();
        for url in model.download_urls {
            let part_path = final_path.with_extension("part");
            let result = self
                .download_from_url(&client, &model, url, &part_path)
                .await;
            match result {
                Ok(()) => {
                    tokio::fs::rename(&part_path, &final_path).await?;
                    {
                        let mut inner = self.inner.lock().await;
                        inner.active_transfer = None;
                        inner.download_progress.remove(model.id);
                        inner.last_fatal_error = None;
                        inner
                            .registry
                            .models
                            .entry(model.id.to_string())
                            .or_default()
                            .downloaded_file_path = Some(final_path.to_string_lossy().to_string());
                        self.registry_store.save(&inner.registry)?;
                    }

                    if self.swap.current_model_id().await.is_none() {
                        if let Err(e) = self.load_model(model.id).await {
                            self.set_last_error(format!("downloaded but failed to load: {e}"))
                                .await;
                        }
                    }
                    return Ok(());
                }
                Err(e) => {
                    errors.push(format!("{url}: {e:#}"));
                    let _ = tokio::fs::remove_file(&part_path).await;
                }
            }
        }

        let message = if errors.is_empty() {
            "download failed".to_string()
        } else {
            errors.join(" | ")
        };
        let mut inner = self.inner.lock().await;
        inner.active_transfer = None;
        inner.loading_model_id = None;
        inner.download_progress.remove(model.id);
        inner.last_fatal_error = Some(message.clone());
        inner
            .registry
            .models
            .entry(model.id.to_string())
            .or_default()
            .last_error = Some(message.clone());
        self.registry_store.save(&inner.registry)?;
        anyhow::bail!(message)
    }

    async fn download_from_url(
        &self,
        client: &reqwest::Client,
        model: &WindowsCatalogModel,
        url: &str,
        part_path: &Path,
    ) -> anyhow::Result<()> {
        let mut response = client.get(url).send().await?;
        if !response.status().is_success() {
            anyhow::bail!("download returned {}", response.status());
        }

        let mut file = tokio::fs::File::create(part_path).await?;
        let total = response.content_length();
        {
            let mut inner = self.inner.lock().await;
            if let Some(transfer) = &mut inner.active_transfer {
                transfer.bytes_total = total;
            }
        }

        let mut downloaded = 0u64;
        let mut hasher = Sha256::new();
        while let Some(chunk) = response.chunk().await? {
            file.write_all(&chunk).await?;
            hasher.update(&chunk);
            downloaded += chunk.len() as u64;
            let progress = match total {
                Some(total) if total > 0 => downloaded as f64 / total as f64,
                _ => 0.0,
            };
            let mut inner = self.inner.lock().await;
            inner
                .download_progress
                .insert(model.id.to_string(), progress);
            if let Some(transfer) = &mut inner.active_transfer {
                transfer.bytes_downloaded = downloaded;
                transfer.bytes_total = total;
            }
        }
        file.flush().await?;
        drop(file);
        // Only a complete, hash-verified file is renamed into place by the
        // caller; anything else is deleted and the next URL is tried.
        verify_download(model, downloaded, total, &hex::encode(hasher.finalize()))
    }
}

fn download_client() -> anyhow::Result<reqwest::Client> {
    let builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(30))
        .user_agent(format!("teale-node/{}", env!("CARGO_PKG_VERSION")));
    #[cfg(windows)]
    let builder = builder.use_native_tls();
    #[cfg(not(windows))]
    let builder = builder.use_rustls_tls();
    Ok(builder.build()?)
}

fn gateway_client(timeout: Duration) -> anyhow::Result<reqwest::Client> {
    let builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(10))
        .timeout(timeout)
        .user_agent(format!("teale-node/{}", env!("CARGO_PKG_VERSION")));
    #[cfg(windows)]
    let builder = builder.use_native_tls();
    #[cfg(not(windows))]
    let builder = builder.use_rustls_tls();
    Ok(builder.build()?)
}

/// Non-2xx answer from the gateway. Kept typed so the local API can relay the
/// gateway's status to the companion UI (e.g. 400 for a wrong email code, 403
/// `account_session_required` for an unproven account link).
#[derive(Debug)]
struct GatewayHttpError {
    status: u16,
    message: String,
}

impl std::fmt::Display for GatewayHttpError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for GatewayHttpError {}

/// Pass a successful gateway response through; turn anything else into a
/// `GatewayHttpError` carrying the gateway's own error message.
async fn gateway_ok(response: reqwest::Response, what: &str) -> anyhow::Result<reqwest::Response> {
    let status = response.status();
    if status.is_success() {
        return Ok(response);
    }
    let body = response.text().await.unwrap_or_default();
    let detail = gateway_error_detail(&body);
    Err(GatewayHttpError {
        status: status.as_u16(),
        message: format!("{what} failed ({status}): {detail}"),
    }
    .into())
}

/// Human-readable message from a gateway error body
/// (`{"error":{"message":..,"code":..}}`), falling back to the raw text.
fn gateway_error_detail(body: &str) -> String {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(body) else {
        return body.trim().to_string();
    };
    let error = value.get("error").unwrap_or(&value);
    if let Some(text) = error.as_str() {
        return text.to_string();
    }
    let message = error.get("message").and_then(|m| m.as_str());
    let code = error.get("code").and_then(|c| c.as_str());
    match (message, code) {
        (Some(message), Some(code)) if !message.contains(code) => format!("{message} ({code})"),
        (Some(message), _) => message.to_string(),
        (None, Some(code)) => code.to_string(),
        (None, None) => body.trim().to_string(),
    }
}

/// Map a failed gateway call to a local status line, preserving the
/// gateway's 4xx status where it is meaningful to the UI.
fn gateway_failure(err: anyhow::Error) -> (&'static str, String) {
    let status = match err.downcast_ref::<GatewayHttpError>().map(|e| e.status) {
        Some(400) => "400 Bad Request",
        Some(401) => "401 Unauthorized",
        Some(403) => "403 Forbidden",
        Some(404) => "404 Not Found",
        Some(409) => "409 Conflict",
        Some(422) => "422 Unprocessable Entity",
        Some(429) => "429 Too Many Requests",
        _ => "502 Bad Gateway",
    };
    (status, format!("{err:#}"))
}

/// Like `gateway_failure`, but "account not linked" is a plain 404 the web
/// bundle treats as "no account yet".
fn account_failure(err: anyhow::Error) -> (&'static str, String) {
    if err.to_string().contains("account not linked") {
        ("404 Not Found", "account not linked".to_string())
    } else {
        gateway_failure(err)
    }
}

/// Key ids are interpolated into a gateway URL path.
fn is_safe_path_segment(value: &str) -> bool {
    let allowed = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '-';
    !value.is_empty() && value.chars().all(allowed)
}

fn auth_snapshot(inner: &RuntimeInner) -> AuthConfigSnapshot {
    let session = inner.account_session.as_ref();
    AuthConfigSnapshot {
        configured: false,
        gateway_account_user_id: session.map(|s| s.account_user_id.clone()),
        gateway_email: session.and_then(|s| s.email.clone()),
    }
}

/// Check a finished model download against the catalog before it is moved
/// into place: the byte count must match the server's Content-Length and the
/// catalog size, and the SHA-256 must match the pinned hash when one exists.
fn verify_download(
    model: &WindowsCatalogModel,
    downloaded: u64,
    content_length: Option<u64>,
    sha256_hex: &str,
) -> anyhow::Result<()> {
    if let Some(expected) = content_length {
        if downloaded != expected {
            anyhow::bail!("download truncated: got {downloaded} of {expected} bytes");
        }
    }
    if model.size_bytes > 0 && downloaded != model.size_bytes {
        anyhow::bail!(
            "downloaded {downloaded} bytes but {} should be {} bytes",
            model.file_name,
            model.size_bytes
        );
    }
    if !model.sha256.is_empty() && !model.sha256.eq_ignore_ascii_case(sha256_hex) {
        anyhow::bail!(
            "checksum mismatch for {}: expected sha256 {}, got {sha256_hex}",
            model.file_name,
            model.sha256
        );
    }
    Ok(())
}

fn json_ok<T: Serialize>(value: &T) -> Result<HttpResponse, (&'static str, String)> {
    serde_json::to_string(value)
        .map(|body| HttpResponse::json("200 OK", body))
        .map_err(|e| ("500 Internal Server Error", e.to_string()))
}

fn parse_json<T: DeserializeOwned>(body: &[u8], what: &str) -> Result<T, (&'static str, String)> {
    serde_json::from_slice(body)
        .map_err(|e| ("400 Bad Request", format!("invalid {what} payload: {e}")))
}

/// The web bundle uses the Mac LocalAPI prefix `/v1/desktop/app`; serve it
/// from the same handlers as `/v1/app`.
fn canonical_path(path: &str) -> Cow<'_, str> {
    match path.strip_prefix("/v1/desktop/app") {
        Some(rest) if rest.is_empty() || rest.starts_with('/') || rest.starts_with('?') => {
            Cow::Owned(format!("/v1/app{rest}"))
        }
        _ => Cow::Borrowed(path),
    }
}

const CORS_ALLOWED_ORIGIN_LINES: &str = concat!(
    "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n",
    "Access-Control-Allow-Headers: Content-Type, Accept, Authorization\r\n",
    "Access-Control-Max-Age: 600\r\n",
);

/// CORS outcome for one request.
#[derive(Debug, Clone, PartialEq, Eq)]
enum Cors {
    /// No `Origin` header: native client, no CORS headers needed.
    NoOrigin,
    /// Allowed browser origin, echoed back verbatim.
    Allowed(String),
}

impl Cors {
    /// Header lines (each ending in CRLF) for a response to this request.
    /// `Access-Control-Allow-Private-Network` is deliberately never sent.
    fn header_lines(&self) -> String {
        let mut lines = String::from("Vary: Origin\r\n");
        if let Cors::Allowed(origin) = self {
            lines.push_str("Access-Control-Allow-Origin: ");
            lines.push_str(origin);
            lines.push_str("\r\n");
            lines.push_str(CORS_ALLOWED_ORIGIN_LINES);
        }
        lines
    }
}

/// Who may talk to the control API (see the module docs).
#[derive(Debug, Clone)]
struct ServerPolicy {
    port: u16,
    /// Exact origin of `TEALE_DESKTOP_WEB_URL`, when set.
    extra_origin: Option<String>,
}

impl ServerPolicy {
    fn from_env(port: u16) -> Self {
        let extra_origin = std::env::var("TEALE_DESKTOP_WEB_URL")
            .ok()
            .and_then(|raw| web_origin(&raw));
        Self { port, extra_origin }
    }

    fn authorize(&self, host: Option<&str>, origin: Option<&str>) -> Result<Cors, HttpResponse> {
        if !host_allowed(host, self.port) {
            return Err(forbidden("host not allowed"));
        }
        match origin {
            None => Ok(Cors::NoOrigin),
            Some(origin) if self.origin_allowed(origin) => Ok(Cors::Allowed(origin.to_string())),
            Some(_) => Err(forbidden("origin not allowed")),
        }
    }

    fn origin_allowed(&self, origin: &str) -> bool {
        BUNDLED_UI_ORIGINS.contains(&origin) || self.extra_origin.as_deref() == Some(origin)
    }
}

fn forbidden(reason: &str) -> HttpResponse {
    HttpResponse::json("403 Forbidden", json!({ "error": reason }).to_string())
}

/// `scheme://host[:port]` of a URL, or None for opaque origins.
fn web_origin(raw: &str) -> Option<String> {
    let url = Url::parse(raw.trim()).ok()?;
    let origin = url.origin();
    origin.is_tuple().then(|| origin.ascii_serialization())
}

/// DNS-rebinding guard: only loopback names on our own port.
fn host_allowed(host: Option<&str>, port: u16) -> bool {
    let Some(host) = host.map(|h| h.trim().to_ascii_lowercase()) else {
        return false;
    };
    host == format!("127.0.0.1:{port}")
        || host == format!("localhost:{port}")
        || host == format!("[::1]:{port}")
}

fn sse_headers(cors: &Cors) -> String {
    format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream; charset=utf-8\r\n\
         Connection: close\r\nCache-Control: no-store\r\n{}\r\n",
        cors.header_lines()
    )
}

fn relay_to_gateway_base_url(relay_url: &str) -> String {
    let Ok(mut relay) = Url::parse(relay_url) else {
        return "https://gateway.teale.com/v1".to_string();
    };

    let scheme = match relay.scheme() {
        "ws" => "http",
        "wss" => "https",
        "http" => "http",
        "https" => "https",
        _ => "https",
    };
    let host = relay.host_str().unwrap_or("relay.teale.com");
    let gateway_host = host.replacen("relay.", "gateway.", 1);
    let _ = relay.set_scheme(scheme);
    let _ = relay.set_host(Some(&gateway_host));
    relay.set_path("/v1");
    relay.set_query(None);
    relay.set_fragment(None);
    relay.to_string().trim_end_matches('/').to_string()
}

fn find_headers_end(buffer: &[u8]) -> Option<usize> {
    buffer.windows(4).position(|window| window == b"\r\n\r\n")
}

async fn read_http_request(
    stream: &mut tokio::net::TcpStream,
) -> Result<Option<ParsedHttpRequest>, (&'static str, String)> {
    let mut buffer = Vec::<u8>::new();
    let mut headers_end = None;

    loop {
        let mut chunk = [0u8; 4096];
        let read = stream
            .read(&mut chunk)
            .await
            .map_err(|e| ("400 Bad Request", format!("could not read request: {e}")))?;
        if read == 0 {
            if buffer.is_empty() {
                return Ok(None);
            }
            return Err((
                "400 Bad Request",
                "request ended before headers completed".to_string(),
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);

        if headers_end.is_none() {
            headers_end = find_headers_end(&buffer);
        }

        if headers_end.is_some() {
            break;
        }
        if buffer.len() > MAX_HTTP_HEADER_BYTES {
            return Err((
                "431 Request Header Fields Too Large",
                "request headers exceeded the local control API limit".to_string(),
            ));
        }
    }

    let headers_end = headers_end.expect("headers end checked above");
    let body_start = headers_end + 4;
    let header_text = std::str::from_utf8(&buffer[..headers_end]).map_err(|e| {
        (
            "400 Bad Request",
            format!("request headers were not utf-8: {e}"),
        )
    })?;
    let mut lines = header_text.split("\r\n");
    let request_line = lines.next().unwrap_or_default();
    let mut parts = request_line.split_whitespace();
    let method = parts
        .next()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            (
                "400 Bad Request",
                "request line was missing an HTTP method".to_string(),
            )
        })?
        .to_string();
    let path = parts
        .next()
        .filter(|value| !value.is_empty())
        .ok_or_else(|| {
            (
                "400 Bad Request",
                "request line was missing a request path".to_string(),
            )
        })?
        .to_string();

    let mut content_length = 0usize;
    let mut host = None;
    let mut origin = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse::<usize>().map_err(|e| {
                    (
                        "400 Bad Request",
                        format!("invalid Content-Length header: {e}"),
                    )
                })?;
            } else if name.eq_ignore_ascii_case("host") {
                host = Some(value.trim().to_string());
            } else if name.eq_ignore_ascii_case("origin") {
                origin = Some(value.trim().to_string());
            }
        }
    }

    if content_length > MAX_HTTP_BODY_BYTES {
        return Err((
            "413 Payload Too Large",
            format!("request body exceeded {} bytes", MAX_HTTP_BODY_BYTES),
        ));
    }

    while buffer.len() < body_start + content_length {
        let mut chunk = [0u8; 4096];
        let read = stream.read(&mut chunk).await.map_err(|e| {
            (
                "400 Bad Request",
                format!("could not read request body: {e}"),
            )
        })?;
        if read == 0 {
            return Err((
                "400 Bad Request",
                "request ended before the full body was received".to_string(),
            ));
        }
        buffer.extend_from_slice(&chunk[..read]);
        if buffer.len() > body_start + content_length {
            break;
        }
    }

    Ok(Some(ParsedHttpRequest {
        method,
        path,
        host,
        origin,
        body: buffer[body_start..body_start + content_length].to_vec(),
    }))
}

async fn proxy_chat_completion(
    body: &[u8],
    state: Arc<StatusState>,
) -> Result<ProxiedChatResponse, (&'static str, String)> {
    let payload: AppChatRequest = serde_json::from_slice(body)
        .map_err(|e| ("400 Bad Request", format!("invalid chat payload: {e}")))?;

    let mut request = payload.request;
    request.stream = Some(true);
    request.stream_options = Some(json!({ "include_usage": true }));

    let (url, bearer_token, prepared) = match payload.provider {
        ChatProvider::Pin => {
            return Err((
                "500 Internal Server Error",
                "pin provider must be handled before proxying".to_string(),
            ))
        }
        ChatProvider::Local => {
            let loaded_model_id = state
                .swap
                .current_model_id()
                .await
                .ok_or_else(|| ("409 Conflict", "no local model is loaded".to_string()))?;
            request.model = Some(loaded_model_id);
            let port = state
                .llama_template
                .as_ref()
                .map(|config| config.port)
                .unwrap_or(11436);
            (
                format!("http://127.0.0.1:{port}/v1/chat/completions"),
                None,
                PreparedPrivacyRequest {
                    request,
                    placeholder_map: HashMap::new(),
                },
            )
        }
        ChatProvider::Network => {
            if request
                .model
                .as_ref()
                .map(|model| model.trim().is_empty())
                .unwrap_or(true)
            {
                return Err((
                    "400 Bad Request",
                    "`model` is required for network chat".to_string(),
                ));
            }
            let token = state
                .gateway_device_token()
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            let mode = state.privacy_filter_mode().await;
            let prepared = state
                .privacy_filter
                .prepare_request(request, mode)
                .await
                .map_err(map_privacy_prepare_error)?;
            (
                format!(
                    "{}/chat/completions",
                    relay_to_gateway_base_url(&state.relay_url)
                ),
                Some(token),
                prepared,
            )
        }
    };

    let client = gateway_client(Duration::from_secs(600)).map_err(|e| {
        (
            "500 Internal Server Error",
            format!("chat client init failed: {e:#}"),
        )
    })?;
    let mut builder = client
        .post(&url)
        .header("Accept", "text/event-stream")
        .json(&prepared.request);
    if let Some(token) = bearer_token {
        builder = builder.bearer_auth(token);
    }
    if prepared.is_filtered() {
        builder = builder.header("X-Teale-Privacy-Filtered", "1");
    }

    let response = builder
        .send()
        .await
        .with_context(|| format!("POST {url}"))
        .map_err(|e| {
            (
                "502 Bad Gateway",
                format!("chat proxy request failed: {e:#}"),
            )
        })?;

    if !response.status().is_success() {
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        return Err((
            "502 Bad Gateway",
            format!("upstream chat returned {status}: {text}"),
        ));
    }

    Ok(ProxiedChatResponse {
        response,
        restorer: prepared.streaming_restorer(),
    })
}

#[derive(Debug)]
struct ProxiedChatResponse {
    response: reqwest::Response,
    restorer: Option<StreamingPlaceholderRestorer>,
}

async fn write_sse_response<W: AsyncWrite + Unpin>(
    writer: &mut W,
    proxied: ProxiedChatResponse,
    cors: &Cors,
) -> Result<(), (&'static str, String)> {
    let headers = sse_headers(cors);
    writer.write_all(headers.as_bytes()).await.map_err(|e| {
        (
            "500 Internal Server Error",
            format!("could not write SSE headers: {e}"),
        )
    })?;

    let mut restorer = proxied.restorer;
    let mut stream = proxied.response.bytes_stream();
    let mut buffer = String::new();
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(bytes) => {
                buffer.push_str(&String::from_utf8_lossy(&bytes));
                buffer = buffer.replace('\r', "");

                while let Some(boundary) = buffer.find("\n\n") {
                    let raw_event = buffer[..boundary].to_string();
                    buffer = buffer[boundary + 2..].to_string();
                    for rendered in render_sse_event(&raw_event, restorer.as_mut()) {
                        if let Err(err) = writer.write_all(rendered.as_bytes()).await {
                            warn!("chat proxy write failed: {err}");
                            return Ok(());
                        }
                    }
                }
            }
            Err(err) => {
                warn!("chat proxy stream failed: {err:#}");
                return Ok(());
            }
        }
    }

    if !buffer.is_empty() {
        for rendered in render_sse_event(&buffer, restorer.as_mut()) {
            if let Err(err) = writer.write_all(rendered.as_bytes()).await {
                warn!("chat proxy write failed: {err}");
                return Ok(());
            }
        }
    } else if let Some(restorer) = restorer.as_mut() {
        let trailing = restorer.finish();
        if !trailing.is_empty() {
            let rendered = synthetic_sse_content_event(trailing);
            if let Err(err) = writer.write_all(rendered.as_bytes()).await {
                warn!("chat proxy write failed: {err}");
                return Ok(());
            }
        }
    }

    let _ = writer.flush().await;
    Ok(())
}

fn map_privacy_prepare_error(error: anyhow::Error) -> (&'static str, String) {
    let message = error.to_string();
    if message.contains("currently supports only")
        || message.contains("does not support tool")
        || message.contains("supports only plain text")
    {
        ("400 Bad Request", message)
    } else {
        (
            "503 Service Unavailable",
            format!("privacy filter unavailable: {message}"),
        )
    }
}

fn render_sse_event(
    raw_event: &str,
    restorer: Option<&mut StreamingPlaceholderRestorer>,
) -> Vec<String> {
    let data = raw_event
        .lines()
        .filter_map(|line| line.strip_prefix("data:"))
        .map(|line| line.trim_start())
        .collect::<Vec<_>>()
        .join("\n");

    if data.is_empty() {
        return vec![format!("{raw_event}\n\n")];
    }

    if data == "[DONE]" {
        let mut rendered = Vec::new();
        if let Some(restorer) = restorer {
            let trailing = restorer.finish();
            if !trailing.is_empty() {
                rendered.push(synthetic_sse_content_event(trailing));
            }
        }
        rendered.push("data: [DONE]\n\n".to_string());
        return rendered;
    }

    let Ok(mut payload) = serde_json::from_str::<serde_json::Value>(&data) else {
        return vec![format!("{raw_event}\n\n")];
    };

    if let Some(restorer) = restorer {
        restore_stream_payload(&mut payload, restorer);
    }

    match serde_json::to_string(&payload) {
        Ok(body) => vec![format!("data: {body}\n\n")],
        Err(_) => vec![format!("{raw_event}\n\n")],
    }
}

fn restore_stream_payload(
    payload: &mut serde_json::Value,
    restorer: &mut StreamingPlaceholderRestorer,
) {
    let terminal = payload
        .get("choices")
        .and_then(|value| value.as_array())
        .and_then(|choices| choices.first())
        .and_then(|choice| choice.get("finish_reason"))
        .is_some_and(|value| !value.is_null());

    let Some(choice) = payload
        .get_mut("choices")
        .and_then(|value| value.as_array_mut())
        .and_then(|choices| choices.first_mut())
    else {
        return;
    };

    let Some(delta) = choice
        .get_mut("delta")
        .and_then(|value| value.as_object_mut())
    else {
        if terminal {
            let trailing = restorer.consume("", true);
            if !trailing.is_empty() {
                choice["delta"] = json!({ "content": trailing });
            }
        }
        return;
    };

    let restored = if let Some(content) = delta.get("content").and_then(|value| value.as_str()) {
        restorer.consume(content, terminal)
    } else if terminal {
        restorer.consume("", true)
    } else {
        String::new()
    };

    if !restored.is_empty() || delta.contains_key("content") {
        delta.insert("content".to_string(), serde_json::Value::String(restored));
    }
}

fn synthetic_sse_content_event(content: String) -> String {
    format!(
        "data: {}\n\n",
        json!({ "choices": [{ "delta": { "content": content }, "finish_reason": null }] })
    )
}

/// Stream a PIN completion as SSE. The prompt goes peer-to-peer over the
/// encrypted transport; only the SSE framing happens here.
async fn handle_pin_chat(
    stream: &mut tokio::net::TcpStream,
    body: &[u8],
    state: Arc<StatusState>,
    cors: &Cors,
) -> Result<(), (&'static str, String)> {
    let payload: AppChatRequest = serde_json::from_slice(body)
        .map_err(|e| ("400 Bad Request", format!("invalid chat payload: {e}")))?;
    let model = payload
        .request
        .model
        .clone()
        .filter(|m| !m.trim().is_empty())
        .ok_or((
            "400 Bad Request",
            "`model` is required for pin chat".to_string(),
        ))?;
    let runtime = state
        .pin_runtime()
        .ok_or(("409 Conflict", "no private network configured".to_string()))?;

    let mut pin_stream = crate::pin::client::pin_completion(
        &runtime.manager,
        &runtime.identity,
        &model,
        payload.request,
    )
    .await
    .map_err(|e| ("502 Bad Gateway", format!("pin completion failed: {e:#}")))?;

    let headers = sse_headers(cors);
    stream
        .write_all(headers.as_bytes())
        .await
        .map_err(|e| ("500 Internal Server Error", e.to_string()))?;

    while let Some(chunk) = pin_stream.chunks.recv().await {
        let frame = format!("data: {chunk}\n\n");
        if stream.write_all(frame.as_bytes()).await.is_err() {
            return Ok(()); // client hung up
        }
    }
    if let Ok(crate::pin::client::PinStreamEnd::Error(message)) = pin_stream.end.await {
        let frame = format!(
            "data: {}\n\n",
            json!({ "error": { "message": message, "source": "pin" } })
        );
        let _ = stream.write_all(frame.as_bytes()).await;
    }
    let _ = stream.write_all(b"data: [DONE]\n\n").await;
    Ok(())
}

async fn handle_chat_proxy(
    stream: &mut tokio::net::TcpStream,
    body: &[u8],
    state: Arc<StatusState>,
    cors: &Cors,
) -> Result<(), (&'static str, String)> {
    let response = proxy_chat_completion(body, state).await?;
    write_sse_response(stream, response, cors).await
}

impl crate::pin::runtime::ModelOps for Arc<StatusState> {
    async fn loaded_models(&self) -> Vec<String> {
        self.swap.loaded_models().await
    }
    async fn downloaded_models(&self) -> Vec<String> {
        self.downloaded_model_ids().await
    }
    async fn ensure_download(&self, model_id: &str) -> anyhow::Result<()> {
        self.start_download(model_id).await
    }
    async fn ensure_loaded(&self, model_id: &str) -> anyhow::Result<()> {
        self.load_model(model_id).await
    }
}

async fn route_pins(
    method: &str,
    subpath: &str,
    body: &[u8],
    state: Arc<StatusState>,
) -> Result<HttpResponse, (&'static str, String)> {
    let Some(runtime) = state.pin_runtime() else {
        return Err(("409 Conflict", "no private network configured".to_string()));
    };
    let manager = &runtime.manager;
    let bad = |e: anyhow::Error| ("502 Bad Gateway", format!("{e:#}"));
    let parse_body = |body: &[u8]| -> Result<serde_json::Value, (&'static str, String)> {
        if body.is_empty() {
            Ok(json!({}))
        } else {
            serde_json::from_slice(body)
                .map_err(|e| ("400 Bad Request", format!("invalid JSON body: {e}")))
        }
    };
    let proxy_status = |status: u16| -> &'static str {
        match status {
            200..=299 => "200 OK",
            403 => "403 Forbidden",
            404 => "404 Not Found",
            409 => "409 Conflict",
            _ => "502 Bad Gateway",
        }
    };

    match (method, subpath) {
        // Overview: local membership state + staff view from the gateway.
        ("GET", "") | ("GET", "/") => {
            let staff = manager
                .proxy("GET", "/v1/pins", None)
                .await
                .map(|(_, body)| body.get("staff").cloned().unwrap_or(json!([])))
                .unwrap_or(json!([]));
            let response = json!({
                "networks": runtime.manager.snapshot(),
                "staff": staff,
                "deviceId": runtime.identity.node_id(),
                "wgPubkey": runtime.identity.wg_pubkey_hex(),
                "settings": runtime.settings(),
                "pendingUsageBatches": runtime.usage.pending_batches(),
            });
            Ok(HttpResponse::json("200 OK", response.to_string()))
        }
        ("POST", "/join") => {
            let payload = parse_body(body)?;
            let code = payload
                .get("code")
                .or_else(|| payload.get("joinCode"))
                .and_then(|v| v.as_str())
                .ok_or(("400 Bad Request", "`code` is required".to_string()))?;
            let display_name = payload.get("displayName").and_then(|v| v.as_str());
            manager.join(code, display_name).await.map_err(bad)?;
            // Sync immediately so a pending membership shows up in the UI.
            let advert = runtime.advertisement(vec![], state.swap.loaded_models().await);
            let _ = manager.sync_once(&advert).await;
            Ok(HttpResponse::json(
                "202 Accepted",
                json!({ "status": "submitted" }).to_string(),
            ))
        }
        ("POST", "/create") => {
            let payload = parse_body(body)?;
            let (status, resp) = manager
                .proxy("POST", "/v1/pins", Some(payload))
                .await
                .map_err(bad)?;
            Ok(HttpResponse::json(proxy_status(status), resp.to_string()))
        }
        ("GET", "/settings/local") => Ok(HttpResponse::json(
            "200 OK",
            serde_json::to_string(&runtime.settings())
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?,
        )),
        ("POST", "/settings/local") => {
            let payload = parse_body(body)?;
            let updated = runtime
                .update_settings(|s| {
                    if let Some(v) = payload.get("allowRemoteModels").and_then(|v| v.as_bool()) {
                        s.allow_remote_models = v;
                    }
                    if let Some(v) = payload.get("dinPriorityEqual").and_then(|v| v.as_bool()) {
                        s.din_priority_equal = v;
                    }
                    if let Some(v) = payload.get("dinContribute").and_then(|v| v.as_bool()) {
                        s.din_contribute = v;
                    }
                })
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            // Apply immediately to the running node.
            state
                .node_state_handle()
                .pin_gate
                .set_din_priority_equal(updated.din_priority_equal);
            if updated.din_contribute {
                state.resume_supply().await;
            } else {
                state.pause_supply().await;
            }
            Ok(HttpResponse::json(
                "200 OK",
                serde_json::to_string(&updated)
                    .map_err(|e| ("500 Internal Server Error", e.to_string()))?,
            ))
        }
        // Everything else is a scoped passthrough to the gateway:
        //   GET  /:id | /:id/members | /:id/usage?... | /:id/models | /:id/join-code
        //   POST /:id/members/:dev/approve | .../deny | /:id/rotate-code | /:id/leave
        //   PATCH/DELETE /:id/members/:dev, PUT /:id/models/:dev, PUT /:id/settings
        (m, sub) if !sub.is_empty() => {
            let payload = if body.is_empty() {
                None
            } else {
                Some(parse_body(body)?)
            };
            let (status, resp) = manager
                .proxy(m, &format!("/v1/pins{sub}"), payload)
                .await
                .map_err(bad)?;
            Ok(HttpResponse::json(proxy_status(status), resp.to_string()))
        }
        _ => Err(("404 Not Found", format!("no pin route {method} {subpath}"))),
    }
}

pub fn spawn(state: Arc<StatusState>, port: u16) {
    let policy = Arc::new(ServerPolicy::from_env(port));
    if let Some(origin) = policy.extra_origin.as_deref() {
        info!("status server: also allowing browser origin {origin} (TEALE_DESKTOP_WEB_URL)");
    }
    tokio::spawn(async move {
        let addr: SocketAddr = match format!("127.0.0.1:{port}").parse() {
            Ok(a) => a,
            Err(e) => {
                warn!("status server: invalid bind addr: {e}");
                return;
            }
        };

        let listener = match tokio::net::TcpListener::bind(addr).await {
            Ok(l) => l,
            Err(e) => {
                warn!("status server: bind {addr} failed: {e} (tray will show Disconnected)");
                return;
            }
        };
        info!("status server listening on {addr}");

        loop {
            let (stream, _peer) = match listener.accept().await {
                Ok(v) => v,
                Err(e) => {
                    warn!("status server: accept failed: {e}");
                    continue;
                }
            };
            let state = state.clone();
            let policy = policy.clone();
            tokio::spawn(async move {
                if let Err(e) = handle(stream, state, policy).await {
                    tracing::debug!("status server: request error: {e}");
                }
            });
        }
    });
}

async fn handle(
    mut stream: tokio::net::TcpStream,
    state: Arc<StatusState>,
    policy: Arc<ServerPolicy>,
) -> Result<(), Infallible> {
    let request = match read_http_request(&mut stream).await {
        Ok(Some(request)) => request,
        Ok(None) => return Ok(()),
        Err((status, message)) => {
            let response = HttpResponse::json(status, json!({ "error": message }).to_string());
            let _ = stream.write_all(response.render().as_bytes()).await;
            return Ok(());
        }
    };

    // Host + Origin policy runs before any route, preflights included.
    let cors = match policy.authorize(request.host.as_deref(), request.origin.as_deref()) {
        Ok(cors) => cors,
        Err(response) => {
            let _ = stream.write_all(response.render().as_bytes()).await;
            return Ok(());
        }
    };

    if request.method == "OPTIONS" {
        let response = HttpResponse::empty("204 No Content").with_cors(&cors);
        let _ = stream.write_all(response.render().as_bytes()).await;
        return Ok(());
    }

    let path = canonical_path(&request.path).into_owned();
    if request.method == "POST" && path == "/v1/app/chat/completions" {
        let is_pin = serde_json::from_slice::<serde_json::Value>(&request.body)
            .ok()
            .and_then(|v| v.get("provider").and_then(|p| p.as_str()).map(String::from))
            .is_some_and(|p| p.eq_ignore_ascii_case("pin"));
        let result = if is_pin {
            handle_pin_chat(&mut stream, &request.body, state.clone(), &cors).await
        } else {
            handle_chat_proxy(&mut stream, &request.body, state.clone(), &cors).await
        };
        if let Err((status, message)) = result {
            let response = HttpResponse::json(status, json!({ "error": message }).to_string())
                .with_cors(&cors);
            let _ = stream.write_all(response.render().as_bytes()).await;
        }
        return Ok(());
    }

    let response = match route(&request.method, &path, &request.body, state).await {
        Ok(resp) => resp,
        Err((status, message)) => {
            HttpResponse::json(status, json!({ "error": message }).to_string())
        }
    };
    let response = response.with_cors(&cors);

    let _ = stream.write_all(response.render().as_bytes()).await;
    Ok(())
}

async fn route(
    method: &str,
    path: &str,
    body: &[u8],
    state: Arc<StatusState>,
) -> Result<HttpResponse, (&'static str, String)> {
    let path = canonical_path(path);
    let path = path.as_ref();

    // Private Inference Network app API. Management calls proxy to the
    // gateway control plane with this device's bearer; local state (netmaps,
    // settings, usage outbox) is served directly.
    if let Some(stripped) = path.strip_prefix("/v1/app/pins") {
        return route_pins(method, stripped, body, state).await;
    }

    match (method, path) {
        ("GET", "/status") => json_ok(&state.legacy_status().await),
        ("POST", "/pause") | ("POST", "/v1/app/service/pause") => {
            state.pause_supply().await;
            Ok(HttpResponse::json(
                "200 OK",
                json!({ "ok": true, "service_state": "paused_user" }).to_string(),
            ))
        }
        ("POST", "/resume") | ("POST", "/v1/app/service/resume") => {
            state.resume_supply().await;
            Ok(HttpResponse::json(
                "200 OK",
                json!({ "ok": true }).to_string(),
            ))
        }
        ("POST", "/v1/app/supply") => {
            let payload: SupplySetRequest = parse_json(body, "supply")?;
            if payload.enabled {
                state.resume_supply().await;
            } else {
                state.pause_supply().await;
            }
            json_ok(&state.snapshot().await)
        }
        ("POST", "/v1/app/privacy-filter/mode") => {
            let payload: PrivacyFilterModeUpdateRequest = parse_json(body, "privacy filter")?;
            state
                .set_privacy_filter_mode(payload.mode)
                .await
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            json_ok(&state.snapshot().await)
        }
        // Supabase sign-in was decommissioned; the UI signs in with the
        // gateway email code below.
        ("POST", "/v1/app/auth/session") => {
            let message = "Supabase sign-in has been removed; sign in with the email code";
            Err(("410 Gone", message.to_string()))
        }
        ("POST", "/v1/app/auth/logout") => {
            state.sign_out().await;
            json_ok(&state.snapshot().await)
        }
        ("GET", "/v1/app") => json_ok(&state.snapshot().await),
        ("GET", "/v1/app/network/models") => {
            let models = state
                .network_models_snapshot()
                .await
                .map_err(|e| bad_gateway("could not load gateway models", e))?;
            json_ok(&models)
        }
        ("GET", "/v1/app/network/stats") => {
            let stats = state
                .network_stats_snapshot()
                .await
                .map_err(|e| bad_gateway("could not load network stats", e))?;
            json_ok(&stats)
        }
        ("GET", "/v1/app/account") => {
            json_ok(&state.account_snapshot().await.map_err(account_failure)?)
        }
        ("GET", "/v1/app/account/api-keys") => {
            json_ok(&state.account_api_keys().await.map_err(account_failure)?)
        }
        ("POST", "/v1/app/account/link") => {
            let payload: AccountLinkRequest = parse_json(body, "account link")?;
            let account = state.link_account(payload).await.map_err(gateway_failure)?;
            json_ok(&account)
        }
        ("POST", "/v1/app/account/email-code/request") => {
            let payload: EmailCodeRequest = parse_json(body, "email code request")?;
            let response = state
                .request_email_code(&payload.email)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/email-code/verify") => {
            let payload: EmailCodeVerifyRequest = parse_json(body, "email code verify")?;
            let response = state
                .verify_email_code(payload)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/api-keys") => {
            let payload: AccountApiKeyCreateRequest = parse_json(body, "account api key")?;
            let response = state
                .create_account_api_key(payload)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/api-keys/revoke") => {
            let payload: AccountApiKeyRevokeRequest = parse_json(body, "account api key revoke")?;
            let response = state
                .revoke_account_api_key(payload.key_id.trim())
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/sweep") => {
            let payload: AccountDeviceControlRequest = parse_json(body, "account sweep")?;
            let response = state
                .sweep_account_device(&payload.device_id)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/send") => {
            let payload: WalletSendRequest = parse_json(body, "account send")?;
            let response = state
                .send_account_wallet(payload)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/devices/remove") => {
            let payload: AccountDeviceControlRequest = parse_json(body, "remove device")?;
            let response = state
                .remove_account_device(&payload.device_id)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/account/withdraw") => {
            let payload: serde_json::Value = parse_json(body, "withdrawal")?;
            let response = state
                .request_withdrawal(payload)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("GET", "/v1/app/account/withdrawals") => {
            json_ok(&state.account_withdrawals().await.map_err(account_failure)?)
        }
        ("GET", "/v1/app/account/deposit-info") => {
            json_ok(&state.deposit_info().await.map_err(account_failure)?)
        }
        ("POST", "/v1/app/models/download") => {
            let payload: ModelControlRequest = parse_json(body, "model")?;
            state
                .start_download(&payload.model)
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            json_ok(&state.snapshot().await)
        }
        ("POST", "/v1/app/models/load") => {
            let payload: ModelControlRequest = parse_json(body, "model")?;
            state
                .load_model(&payload.model)
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            json_ok(&state.snapshot().await)
        }
        ("POST", "/v1/app/models/unload") => {
            state
                .unload_model()
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            json_ok(&state.snapshot().await)
        }
        ("POST", "/v1/app/wallet/send") => {
            let payload: WalletSendRequest = parse_json(body, "wallet send")?;
            let response = state
                .send_device_wallet(payload)
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        ("POST", "/v1/app/wallet/refresh") => {
            let response = state
                .force_refresh_gateway_wallet()
                .await
                .map_err(gateway_failure)?;
            json_ok(&response)
        }
        _ => Err(("404 Not Found", "not found".to_string())),
    }
}

fn bad_gateway(context: &str, err: anyhow::Error) -> (&'static str, String) {
    ("502 Bad Gateway", format!("{context}: {err:#}"))
}

struct HttpResponse {
    status: &'static str,
    body: String,
    content_type: &'static str,
    cors: Cors,
}

impl HttpResponse {
    fn json(status: &'static str, body: String) -> Self {
        Self {
            status,
            body,
            content_type: "application/json",
            cors: Cors::NoOrigin,
        }
    }

    fn empty(status: &'static str) -> Self {
        Self {
            status,
            body: String::new(),
            content_type: "text/plain; charset=utf-8",
            cors: Cors::NoOrigin,
        }
    }

    fn with_cors(mut self, cors: &Cors) -> Self {
        self.cors = cors.clone();
        self
    }

    fn render(&self) -> String {
        format!(
            concat!(
                "HTTP/1.1 {}\r\n",
                "Content-Type: {}\r\n",
                "Content-Length: {}\r\n",
                "Connection: close\r\n",
                "Cache-Control: no-store\r\n",
                "{}",
                "\r\n{}"
            ),
            self.status,
            self.content_type,
            self.body.len(),
            self.cors.header_lines(),
            self.body
        )
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::{Arc, OnceLock};
    use std::time::Duration;

    use super::{
        canonical_path, gateway_error_detail, handle, proxy_chat_completion, read_http_request,
        route, verify_download, web_origin, write_sse_response, Cors, ServerPolicy, ServiceState,
        StatusState,
    };
    use crate::account_session::{AccountSession, AccountSessionStore};
    use crate::backend::Backend;
    use crate::cluster::NodeRuntimeState;
    use crate::config::LlamaConfig;
    use crate::hardware::HardwareCapability;
    use crate::model_registry::{PersistedRegistry, RegistryStore};
    use crate::privacy_filter::PrivacyFilterMode;
    use crate::swap::SwapManager;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    fn dummy_hw(ram: f64) -> HardwareCapability {
        HardwareCapability {
            chip_family: "intelCPU".to_string(),
            chip_name: "Intel".to_string(),
            total_ram_gb: ram,
            gpu_core_count: 0,
            memory_bandwidth_gbs: 80.0,
            tier: 2,
            gpu_backend: Some("vulkan".to_string()),
            platform: Some("windows".to_string()),
            gpu_vram_gb: None,
        }
    }

    fn dummy_llama() -> LlamaConfig {
        LlamaConfig {
            binary: "llama-server".to_string(),
            model: String::new(),
            backend_model_id: None,
            model_id: None,
            gpu_layers: 0,
            context_size: 8192,
            port: 11436,
            extra_args: vec![],
        }
    }

    fn dummy_llama_with_port(port: u16) -> LlamaConfig {
        let mut config = dummy_llama();
        config.port = port;
        config
    }

    fn temp_dir() -> PathBuf {
        let tmp = std::env::temp_dir().join(format!("teale-status-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).expect("temp dir");
        tmp
    }

    fn build_state(tmp: &Path, relay_url: String, llama: Option<LlamaConfig>) -> Arc<StatusState> {
        let registry_store = RegistryStore::new(tmp.join("model-registry.json"));
        let node_state = Arc::new(NodeRuntimeState::new(1));
        let swap = SwapManager::new(
            Backend::Unavailable,
            None,
            String::new(),
            None,
            llama.clone().unwrap_or_else(dummy_llama),
            vec![],
            node_state.clone(),
        );
        Arc::new(StatusState::new(
            "WIN".to_string(),
            dummy_hw(16.0),
            tmp.to_path_buf(),
            registry_store,
            // Off: tests must not try to start the Python privacy helper
            // (slow on Windows runners); tests that need it opt back in.
            PersistedRegistry {
                privacy_filter_mode: PrivacyFilterMode::Off,
                ..Default::default()
            },
            swap,
            llama,
            AccountSessionStore::in_data_dir(tmp),
            relay_url,
            node_state,
        ))
    }

    fn build_loaded_state(
        tmp: &Path,
        relay_url: String,
        llama: Option<LlamaConfig>,
        model_id: &str,
    ) -> Arc<StatusState> {
        let registry_store = RegistryStore::new(tmp.join("model-registry.json"));
        let node_state = Arc::new(NodeRuntimeState::new(1));
        let advertised_model_id = model_id.to_string();
        let proxy = crate::inference::InferenceProxy::new(
            11436,
            &advertised_model_id,
            &advertised_model_id,
        );
        proxy.mark_ready_for_tests(true);
        let swap = SwapManager::new(
            Backend::Http(proxy),
            None,
            advertised_model_id.clone(),
            None,
            llama.clone().unwrap_or_else(dummy_llama),
            vec![],
            node_state.clone(),
        );
        Arc::new(StatusState::new(
            "WIN".to_string(),
            dummy_hw(16.0),
            tmp.to_path_buf(),
            registry_store,
            PersistedRegistry {
                active_model_id: Some(advertised_model_id),
                privacy_filter_mode: PrivacyFilterMode::Off,
                ..Default::default()
            },
            swap,
            llama,
            AccountSessionStore::in_data_dir(tmp),
            relay_url,
            node_state,
        ))
    }

    fn helper_env_guard() -> &'static tokio::sync::Mutex<()> {
        static GUARD: OnceLock<tokio::sync::Mutex<()>> = OnceLock::new();
        GUARD.get_or_init(|| tokio::sync::Mutex::new(()))
    }

    async fn spawn_helper_stub() -> (String, tokio::task::JoinHandle<()>) {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind helper stub");
        let addr = listener.local_addr().expect("helper stub addr");
        let task = tokio::spawn(async move {
            loop {
                let accept = tokio::time::timeout(Duration::from_secs(1), listener.accept()).await;
                let Ok(Ok((mut socket, _))) = accept else {
                    break;
                };
                let request = read_http_request(&mut socket)
                    .await
                    .expect("parse helper request")
                    .expect("helper request should exist");
                let body_text = String::from_utf8_lossy(&request.body);
                let (status, body) = if request.method == "GET" && request.path == "/health" {
                    ("200 OK", r#"{"ready":true,"error":null}"#.to_string())
                } else if request.method == "POST" && request.path == "/v1/redact" {
                    let spans = if body_text.contains("Taylor") {
                        r#"{"ok":true,"spans":[{"label":"private_person","start":3,"end":9,"text":"Taylor"}]}"#
                    } else {
                        r#"{"ok":true,"spans":[]}"#
                    };
                    ("200 OK", spans.to_string())
                } else {
                    ("404 Not Found", r#"{"error":"not found"}"#.to_string())
                };
                let response = format!(
                    "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                socket
                    .write_all(response.as_bytes())
                    .await
                    .expect("write helper response");
            }
        });
        (format!("http://127.0.0.1:{}", addr.port()), task)
    }

    async fn unused_local_url() -> String {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind unused local port");
        let addr = listener.local_addr().expect("unused local addr");
        drop(listener);
        format!("http://127.0.0.1:{}", addr.port())
    }

    #[tokio::test]
    async fn snapshot_serializes_needs_model_state() {
        let tmp = temp_dir();
        let state = build_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
        );
        state.clear_starting().await;

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.service_state, ServiceState::NeedsModel.as_str());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn snapshot_reports_offline_when_model_is_loaded_but_relay_is_down() {
        let tmp = temp_dir();
        let state = build_loaded_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
            "nousresearch/hermes-3-llama-3.1-8b",
        );

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.service_state, ServiceState::Offline.as_str());
        assert_eq!(
            snapshot.state_reason.as_deref(),
            Some("Relay is offline. Waiting to reconnect.")
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn snapshot_reports_serving_when_model_is_loaded_and_relay_is_connected() {
        let tmp = temp_dir();
        let state = build_loaded_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
            "nousresearch/hermes-3-llama-3.1-8b",
        );
        state.mark_relay_connected(true);

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.service_state, ServiceState::Serving.as_str());
        assert_eq!(
            snapshot.state_reason.as_deref(),
            Some("Ready to serve inference.")
        );

        let _ = std::fs::remove_dir_all(&tmp);
    }

    const TEST_PORT: u16 = 11437;
    const LOOPBACK_HOST: &str = "127.0.0.1:11437";
    const STUB_VERIFY_BODY: &str = r#"{"sessionToken":"tsess_test","expiresAt":1,"accountUserID":"acct-1","email":"a@example.com"}"#;
    const STUB_ACCOUNT_BODY: &str = r#"{"account_user_id":"acct-1","balance_credits":0,"usdc_cents":0,"devices":[],"transactions":[]}"#;

    fn raw_request(
        method: &str,
        path: &str,
        host: &str,
        origin: Option<&str>,
        body: &str,
    ) -> String {
        let origin = origin
            .map(|origin| format!("Origin: {origin}\r\n"))
            .unwrap_or_default();
        format!(
            "{method} {path} HTTP/1.1\r\nHost: {host}\r\n{origin}\
             Content-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}",
            body.len()
        )
    }

    fn status_line(response: &str) -> &str {
        response.lines().next().unwrap_or_default()
    }

    /// Send one raw request through the real connection handler.
    async fn roundtrip(state: Arc<StatusState>, policy: ServerPolicy, raw: String) -> String {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind");
        let addr = listener.local_addr().expect("addr");
        let policy = Arc::new(policy);
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.expect("accept");
            let _ = handle(socket, state, policy).await;
        });
        let mut client = TcpStream::connect(addr).await.expect("connect");
        client.write_all(raw.as_bytes()).await.expect("write");
        let mut out = Vec::new();
        client.read_to_end(&mut out).await.expect("read");
        server.await.expect("server task");
        String::from_utf8(out).expect("utf8 response")
    }

    fn default_policy() -> ServerPolicy {
        ServerPolicy {
            port: TEST_PORT,
            extra_origin: None,
        }
    }

    fn assert_no_private_network_header(response: &str) {
        assert!(
            !response.contains("Access-Control-Allow-Private-Network"),
            "response must never opt into Private Network Access: {response}"
        );
    }

    #[tokio::test]
    async fn request_without_origin_is_served_without_cors_grant() {
        let tmp = temp_dir();
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));
        let raw = raw_request("GET", "/v1/app", LOOPBACK_HOST, None, "");
        let response = roundtrip(state, default_policy(), raw).await;
        assert_eq!(status_line(&response), "HTTP/1.1 200 OK");
        assert!(response.contains("Vary: Origin"));
        assert!(!response.contains("Access-Control-Allow-Origin"));
        assert_no_private_network_header(&response);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn bundled_ui_origin_is_echoed_on_get_and_options() {
        let tmp = temp_dir();
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));

        let raw = raw_request(
            "GET",
            "/v1/desktop/app",
            LOOPBACK_HOST,
            Some("http://teale.localhost"),
            "",
        );
        let response = roundtrip(state.clone(), default_policy(), raw).await;
        assert_eq!(status_line(&response), "HTTP/1.1 200 OK");
        assert!(response.contains("Access-Control-Allow-Origin: http://teale.localhost\r\n"));
        assert!(response.contains("Vary: Origin"));
        assert!(!response.contains("Access-Control-Allow-Origin: *"));
        assert_no_private_network_header(&response);

        let raw = raw_request(
            "OPTIONS",
            "/v1/desktop/app/account/link",
            "localhost:11437",
            Some("teale://localhost"),
            "",
        );
        let response = roundtrip(state, default_policy(), raw).await;
        assert_eq!(status_line(&response), "HTTP/1.1 204 No Content");
        assert!(response.contains("Access-Control-Allow-Origin: teale://localhost\r\n"));
        assert!(response.contains("Access-Control-Allow-Methods: "));
        assert_no_private_network_header(&response);
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn foreign_origin_is_rejected_for_get_post_and_options() {
        let tmp = temp_dir();
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));
        let send = r#"{"asset":"credits","recipient":"x","amount":1}"#;
        let cases = [
            ("GET", "/v1/app", ""),
            ("POST", "/v1/app/wallet/send", send),
            ("POST", "/v1/desktop/app/account/api-keys", "{}"),
            ("OPTIONS", "/v1/app/wallet/send", ""),
        ];
        for (method, path, body) in cases {
            let raw = raw_request(
                method,
                path,
                LOOPBACK_HOST,
                Some("https://evil.example"),
                body,
            );
            let response = roundtrip(state.clone(), default_policy(), raw).await;
            assert_eq!(
                status_line(&response),
                "HTTP/1.1 403 Forbidden",
                "{method} {path}"
            );
            assert!(!response.contains("Access-Control-Allow-Origin"));
            assert!(!response.contains("network_bearer_token"));
            assert_no_private_network_header(&response);
        }
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn non_loopback_host_is_rejected() {
        let tmp = temp_dir();
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));
        let hosts = [
            "evil.example:11437",
            "127.0.0.1:9999",
            "attacker.localhost:11437",
        ];
        for host in hosts {
            let raw = raw_request("GET", "/v1/app", host, None, "");
            let response = roundtrip(state.clone(), default_policy(), raw).await;
            assert_eq!(status_line(&response), "HTTP/1.1 403 Forbidden", "{host}");
            assert_no_private_network_header(&response);
        }
        // A request with no Host header at all is rejected too.
        let raw = "GET /v1/app HTTP/1.1\r\nContent-Length: 0\r\n\r\n".to_string();
        let response = roundtrip(state.clone(), default_policy(), raw).await;
        assert_eq!(status_line(&response), "HTTP/1.1 403 Forbidden");
        // IPv6 loopback is fine.
        let raw = raw_request("GET", "/status", "[::1]:11437", None, "");
        let response = roundtrip(state, default_policy(), raw).await;
        assert_eq!(status_line(&response), "HTTP/1.1 200 OK");
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn desktop_web_url_origin_is_allowed_only_when_configured() {
        let tmp = temp_dir();
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));
        let origin = web_origin("https://teale.com/docs/desktop-companion/index.html");
        assert_eq!(origin.as_deref(), Some("https://teale.com"));
        assert_eq!(web_origin("not a url"), None);

        let raw = raw_request(
            "GET",
            "/status",
            LOOPBACK_HOST,
            Some("https://teale.com"),
            "",
        );
        let rejected = roundtrip(state.clone(), default_policy(), raw.clone()).await;
        assert_eq!(status_line(&rejected), "HTTP/1.1 403 Forbidden");

        let policy = ServerPolicy {
            port: TEST_PORT,
            extra_origin: origin,
        };
        let allowed = roundtrip(state, policy, raw).await;
        assert_eq!(status_line(&allowed), "HTTP/1.1 200 OK");
        assert!(allowed.contains("Access-Control-Allow-Origin: https://teale.com\r\n"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn desktop_paths_alias_app_paths() {
        assert_eq!(canonical_path("/v1/desktop/app"), "/v1/app");
        assert_eq!(
            canonical_path("/v1/desktop/app/account/email-code/verify"),
            "/v1/app/account/email-code/verify"
        );
        assert_eq!(canonical_path("/v1/desktop/app?x=1"), "/v1/app?x=1");
        assert_eq!(canonical_path("/v1/desktop/apple"), "/v1/desktop/apple");
        assert_eq!(canonical_path("/v1/app/models"), "/v1/app/models");
    }

    #[tokio::test]
    async fn supply_route_toggles_user_pause() {
        let tmp = temp_dir();
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));
        let response = route(
            "POST",
            "/v1/desktop/app/supply",
            br#"{"enabled":false}"#,
            state.clone(),
        )
        .await
        .expect("supply off");
        assert!(response.body.contains("\"supply_enabled\":false"));
        let response = route(
            "POST",
            "/v1/desktop/app/supply",
            br#"{"enabled":true}"#,
            state.clone(),
        )
        .await
        .expect("supply on");
        assert!(response.body.contains("\"supply_enabled\":true"));

        let result = route("POST", "/v1/desktop/app/auth/session", b"{}", state).await;
        assert!(matches!(result, Err(("410 Gone", _))));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn snapshot_reports_persisted_gateway_session() {
        let tmp = temp_dir();
        let store = AccountSessionStore::in_data_dir(&tmp);
        let session = AccountSession {
            session_token: "tsess_persisted".into(),
            account_user_id: "acct-9".into(),
            email: Some("nine@example.com".into()),
            expires_at: None,
        };
        store.save(&session).expect("seed session");
        let state = build_state(&tmp, "wss://relay.teale.com/ws".into(), Some(dummy_llama()));
        let snapshot = state.snapshot().await;
        let auth = &snapshot.auth;
        assert!(!auth.configured);
        assert_eq!(auth.gateway_account_user_id.as_deref(), Some("acct-9"));
        assert_eq!(auth.gateway_email.as_deref(), Some("nine@example.com"));
        let json = serde_json::to_string(&snapshot).expect("serialize");
        assert!(!json.contains("tsess_persisted"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    /// Read one HTTP request (headers + Content-Length body) as raw text.
    async fn read_raw_request(socket: &mut TcpStream) -> String {
        let mut buf = Vec::new();
        loop {
            let mut chunk = [0u8; 4096];
            let read = socket.read(&mut chunk).await.expect("read request");
            if read == 0 {
                break;
            }
            buf.extend_from_slice(&chunk[..read]);
            let text = String::from_utf8_lossy(&buf).to_string();
            if let Some(end) = text.find("\r\n\r\n") {
                let length = text[..end]
                    .lines()
                    .filter_map(|line| line.split_once(':'))
                    .find(|(name, _)| name.eq_ignore_ascii_case("content-length"))
                    .and_then(|(_, value)| value.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if buf.len() >= end + 4 + length {
                    break;
                }
            }
        }
        String::from_utf8_lossy(&buf).to_string()
    }

    /// Minimal gateway stand-in: answers `count` requests and returns the
    /// raw requests it saw.
    async fn spawn_gateway_stub(count: usize) -> (String, tokio::task::JoinHandle<Vec<String>>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.expect("bind stub");
        let addr = listener.local_addr().expect("stub addr");
        let task = tokio::spawn(async move {
            let mut seen = Vec::new();
            for _ in 0..count {
                let (mut socket, _) = listener.accept().await.expect("accept stub");
                let raw = read_raw_request(&mut socket).await;
                let body = if raw.starts_with("POST /v1/auth/email/verify") {
                    STUB_VERIFY_BODY
                } else if raw.starts_with("POST /v1/account/link") {
                    STUB_ACCOUNT_BODY
                } else {
                    "{}"
                };
                let response = format!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                    body.len(),
                    body
                );
                socket
                    .write_all(response.as_bytes())
                    .await
                    .expect("write stub response");
                seen.push(raw);
            }
            seen
        });
        (format!("http://127.0.0.1:{}/ws", addr.port()), task)
    }

    #[tokio::test]
    async fn email_sign_in_persists_session_and_proves_account_link() {
        let (relay_url, stub) = spawn_gateway_stub(3).await;
        let tmp = temp_dir();
        let state = build_state(&tmp, relay_url, Some(dummy_llama()));
        state.inner.lock().await.gateway_device_token = Some("device-token".to_string());

        let verified = route(
            "POST",
            "/v1/desktop/app/account/email-code/verify",
            br#"{"email":"a@example.com","code":"123456"}"#,
            state.clone(),
        )
        .await
        .expect("verify ok");
        let verified: serde_json::Value = serde_json::from_str(&verified.body).expect("json");
        assert_eq!(verified["accountUserID"], "acct-1");
        assert_eq!(verified["email"], "a@example.com");
        assert!(verified.get("sessionToken").is_none());
        let stored = AccountSessionStore::in_data_dir(&tmp)
            .load()
            .expect("session persisted");
        assert_eq!(stored.session_token, "tsess_test");

        route(
            "POST",
            "/v1/desktop/app/account/link",
            br#"{"accountUserID":"acct-1"}"#,
            state.clone(),
        )
        .await
        .expect("link ok");

        route("POST", "/v1/app/auth/logout", b"", state.clone())
            .await
            .expect("logout ok");
        assert!(AccountSessionStore::in_data_dir(&tmp).load().is_none());
        let auth = state.snapshot().await.auth;
        assert!(auth.gateway_account_user_id.is_none());

        let seen = stub.await.expect("stub task");
        assert!(seen[0].starts_with("POST /v1/auth/email/verify"));
        assert!(seen[1].starts_with("POST /v1/account/link"));
        let link = seen[1].to_ascii_lowercase();
        assert!(link.contains("x-teale-account-session: tsess_test"));
        assert!(link.contains("authorization: bearer device-token"));
        assert!(seen[2].starts_with("POST /v1/auth/logout"));
        let logout = seen[2].to_ascii_lowercase();
        assert!(logout.contains("authorization: bearer tsess_test"));
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn download_verification_checks_length_and_hash() {
        let model = crate::windows_model_catalog::WINDOWS_MODEL_CATALOG[0].clone();
        let size = model.size_bytes;
        let hash = model.sha256;
        let upper = hash.to_uppercase();
        assert!(verify_download(&model, size, Some(size), hash).is_ok());
        assert!(verify_download(&model, size, Some(size), &upper).is_ok());
        let truncated = verify_download(&model, size - 1, Some(size), hash);
        assert!(truncated.unwrap_err().to_string().contains("truncated"));
        assert!(verify_download(&model, size - 1, None, hash).is_err());
        let bad_hash = verify_download(&model, size, Some(size), &"0".repeat(64));
        let message = bad_hash.unwrap_err().to_string();
        assert!(message.contains("checksum mismatch"));
    }

    #[test]
    fn gateway_error_detail_prefers_message_and_code() {
        let body = r#"{"error":{"message":"link needs proof","code":"account_session_required"}}"#;
        assert_eq!(
            gateway_error_detail(body),
            "link needs proof (account_session_required)"
        );
        let plain = r#"{"error":"bad code"}"#;
        assert_eq!(gateway_error_detail(plain), "bad code");
        assert_eq!(gateway_error_detail("plain text"), "plain text");
    }

    #[tokio::test]
    async fn request_parser_reads_large_body_from_content_length() {
        let listener = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind parser test listener");
        let addr = listener.local_addr().expect("parser test addr");
        let server = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.expect("accept parser test client");
            read_http_request(&mut socket)
                .await
                .expect("parsed request")
                .expect("request should exist")
        });

        let mut client = TcpStream::connect(addr).await.expect("connect parser test");
        let body = vec![b'a'; 9000];
        let headers = format!(
            "POST /v1/app/chat/completions HTTP/1.1\r\nHost: localhost\r\nContent-Length: {}\r\n\r\n",
            body.len()
        );
        client
            .write_all(headers.as_bytes())
            .await
            .expect("write parser headers");
        client.write_all(&body).await.expect("write parser body");

        let request = server.await.expect("parser server task");
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/v1/app/chat/completions");
        assert_eq!(request.body.len(), body.len());
    }

    #[tokio::test]
    async fn chat_proxy_rejects_malformed_payload() {
        let tmp = temp_dir();
        let state = build_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
        );

        let err = proxy_chat_completion(
            br#"{"provider":"network","model":"meta-llama/test","messages":"bad"}"#,
            state,
        )
        .await
        .expect_err("malformed payload should fail");

        assert_eq!(err.0, "400 Bad Request");
        assert!(err.1.contains("invalid chat payload"));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn local_chat_requires_a_loaded_model() {
        let tmp = temp_dir();
        let state = build_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
        );

        let err = proxy_chat_completion(
            br#"{"provider":"local","messages":[{"role":"user","content":"hi"}],"stream":true}"#,
            state,
        )
        .await
        .expect_err("local chat should fail without a loaded model");

        assert_eq!(err.0, "409 Conflict");
        assert!(err.1.contains("no local model"));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn network_chat_requires_a_device_token() {
        let tmp = temp_dir();
        let state = build_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
        );

        let err = proxy_chat_completion(
            br#"{"provider":"network","model":"meta-llama/test","messages":[{"role":"user","content":"hi"}],"stream":true}"#,
            state,
        )
        .await
        .expect_err("network chat should fail without a device token");

        assert_eq!(err.0, "409 Conflict");
        assert!(err.1.contains("gateway device token"));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn streaming_proxy_emits_sse_headers_and_forwards_done() {
        let _guard = helper_env_guard().lock().await;
        let (helper_url, helper_task) = spawn_helper_stub().await;
        std::env::set_var("TEALE_OPF_HELPER_URL", &helper_url);

        let upstream = TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind upstream listener");
        let upstream_addr = upstream.local_addr().expect("upstream addr");
        let upstream_task = tokio::spawn(async move {
            let (mut socket, _) = upstream.accept().await.expect("accept upstream");
            let mut request_buf = vec![0u8; 4096];
            let read = socket
                .read(&mut request_buf)
                .await
                .expect("read upstream request");
            let request = String::from_utf8_lossy(&request_buf[..read]);
            assert!(request.contains("POST /v1/chat/completions HTTP/1.1"));
            assert!(request
                .to_ascii_lowercase()
                .contains("authorization: bearer test-device-token"));
            assert!(request
                .to_ascii_lowercase()
                .contains("x-teale-privacy-filtered: 1"));
            assert!(request.contains("\"stream_options\":{\"include_usage\":true}"));
            assert!(request.contains("<PRIVATE_PERSON_1>"));
            assert!(!request.contains("\"hi Taylor\""));

            let body = concat!(
                "data: {\"choices\":[{\"delta\":{\"content\":\"hello <PRIVATE_\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"PERSON_1>\"}}]}\n\n",
                "data: [DONE]\n\n"
            );
            let response = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
                body.len(),
                body
            );
            socket
                .write_all(response.as_bytes())
                .await
                .expect("write upstream response");
        });

        let tmp = temp_dir();
        let relay_url = format!("http://127.0.0.1:{}/ws", upstream_addr.port());
        let state = build_state(&tmp, relay_url, Some(dummy_llama_with_port(11436)));
        {
            let mut inner = state.inner.lock().await;
            inner.gateway_device_token = Some("test-device-token".to_string());
        }
        state
            .set_privacy_filter_mode(PrivacyFilterMode::AutoWan)
            .await
            .expect("set privacy mode");

        let response = proxy_chat_completion(
            br#"{"provider":"network","model":"meta-llama/test","messages":[{"role":"user","content":"hi Taylor"}],"stream":true}"#,
            state,
        )
        .await
        .expect("proxy chat response");

        let (mut writer, mut reader) = tokio::io::duplex(4096);
        let forward_task = tokio::spawn(async move {
            write_sse_response(&mut writer, response, &Cors::NoOrigin)
                .await
                .expect("write sse response");
        });

        let mut rendered = Vec::new();
        reader
            .read_to_end(&mut rendered)
            .await
            .expect("read forwarded stream");
        forward_task.await.expect("forward task");
        upstream_task.await.expect("upstream task");
        helper_task.await.expect("helper task");
        std::env::remove_var("TEALE_OPF_HELPER_URL");

        let output = String::from_utf8(rendered).expect("stream output utf8");
        assert!(output.contains("HTTP/1.1 200 OK"));
        assert!(output.contains("Content-Type: text/event-stream; charset=utf-8"));
        assert!(output.contains("data: [DONE]"));
        assert!(output.contains("Taylor"));
        assert!(!output.contains("<PRIVATE_PERSON_1>"));

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn network_chat_fails_closed_when_helper_is_unavailable() {
        let _guard = helper_env_guard().lock().await;
        let helper_url = unused_local_url().await;
        std::env::set_var("TEALE_OPF_HELPER_URL", &helper_url);

        let tmp = temp_dir();
        let state = build_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
        );
        {
            let mut inner = state.inner.lock().await;
            inner.gateway_device_token = Some("test-device-token".to_string());
        }
        state
            .set_privacy_filter_mode(PrivacyFilterMode::AutoWan)
            .await
            .expect("set privacy mode");

        let err = proxy_chat_completion(
            br#"{"provider":"network","model":"meta-llama/test","messages":[{"role":"user","content":"hi Taylor"}],"stream":true}"#,
            state,
        )
        .await
        .expect_err("network chat should fail closed without helper");

        std::env::remove_var("TEALE_OPF_HELPER_URL");
        assert_eq!(err.0, "503 Service Unavailable");
        assert!(err.1.contains("privacy filter unavailable"));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
