//! Localhost control API for the Windows companion app.
//!
//! Bound to `127.0.0.1` only. This server powers both the tray icon and the
//! embedded desktop companion UI. Legacy `/status`, `/pause`, and `/resume`
//! remain for back-compat with earlier tray-only pilots.

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Mutex;
use tracing::{info, warn};
use url::Url;

use crate::cluster::NodeRuntimeState;
use crate::config::{ControlConfig, LlamaConfig};
use crate::hardware::HardwareCapability;
use crate::model_registry::{PersistedRegistry, RegistryStore};
use crate::swap::SwapManager;
use crate::windows_model_catalog::{
    compatible_models, context_for_model, model_by_id, recommended_model, WindowsCatalogModel,
    AVAILABILITY_TICK_SECONDS,
};
use teale_protocol::openai::ChatCompletionRequest;

const MAX_HTTP_BODY_BYTES: usize = 1024 * 1024;
const MAX_HTTP_HEADER_BYTES: usize = 16 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ServiceState {
    Starting,
    NeedsModel,
    Downloading,
    Loading,
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

#[derive(Debug, Clone, Serialize)]
pub struct AuthConfigSnapshot {
    pub configured: bool,
    pub supabase_url: Option<String>,
    pub supabase_anon_key: Option<String>,
    pub redirect_url: Option<String>,
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

#[derive(Debug, Clone, Serialize)]
pub struct AppSnapshot {
    pub app_version: String,
    pub service_state: String,
    pub state_reason: Option<String>,
    pub device: DeviceSnapshot,
    pub auth: AuthConfigSnapshot,
    pub demand: DemandSnapshot,
    pub wallet: WalletSnapshot,
    pub wallet_transactions: Vec<WalletTransactionSnapshot>,
    pub loaded_model_id: Option<String>,
    pub models: Vec<ModelSnapshot>,
    pub active_transfer: Option<TransferSnapshot>,
    pub updater: UpdaterSnapshot,
}

#[derive(Debug, Serialize)]
pub(crate) struct LegacyStatusDTO {
    state: String,
    supplying_since: Option<String>,
    requests_today: u64,
    credits_today: i64,
    on_ac: bool,
    paused_reason: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ModelControlRequest {
    model: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct UpdaterSnapshot {
    pub auto_download: bool,
    pub auto_install_after_download: bool,
    pub latest_tag: Option<String>,
    pub latest_release_url: Option<String>,
    pub downloaded_tag: Option<String>,
    pub downloaded_installer_path: Option<String>,
    pub status: String,
    pub last_error: Option<String>,
    pub last_checked_at: Option<u64>,
    pub last_downloaded_at: Option<u64>,
    pub last_installed_at: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
struct UpdaterSettingsRecord {
    #[serde(default)]
    auto_download: bool,
    #[serde(default)]
    auto_install_after_download: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct UpdaterStateRecord {
    #[serde(default)]
    latest_tag: Option<String>,
    #[serde(default)]
    latest_release_url: Option<String>,
    #[serde(default)]
    downloaded_tag: Option<String>,
    #[serde(default)]
    downloaded_installer_path: Option<String>,
    #[serde(default = "default_updater_status")]
    status: String,
    #[serde(default)]
    last_error: Option<String>,
    #[serde(default)]
    last_checked_at: Option<u64>,
    #[serde(default)]
    last_downloaded_at: Option<u64>,
    #[serde(default)]
    last_installed_at: Option<u64>,
}

impl Default for UpdaterStateRecord {
    fn default() -> Self {
        Self {
            latest_tag: None,
            latest_release_url: None,
            downloaded_tag: None,
            downloaded_installer_path: None,
            status: default_updater_status(),
            last_error: None,
            last_checked_at: None,
            last_downloaded_at: None,
            last_installed_at: None,
        }
    }
}

fn default_updater_status() -> String {
    "idle".to_string()
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
struct UpdaterSettingsRequest {
    #[serde(default)]
    auto_download: bool,
    #[serde(default)]
    auto_install_after_download: bool,
}

#[derive(Debug, Deserialize)]
struct UpdaterRunRequest {
    action: String,
}

#[derive(Debug, Deserialize)]
struct AuthSessionLookupRequest {
    #[serde(rename = "accessToken")]
    access_token: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ChatProvider {
    Local,
    Network,
}

#[derive(Debug, Clone, Deserialize)]
struct AppChatRequest {
    provider: ChatProvider,
    #[serde(flatten)]
    request: ChatCompletionRequest,
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
    body: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SupabaseAuthSessionSnapshot {
    user: SupabaseAuthUserSnapshot,
    identities: Vec<SupabaseAuthIdentitySnapshot>,
    devices: Vec<SupabaseDeviceRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SupabaseAuthUserSnapshot {
    id: String,
    phone: Option<String>,
    email: Option<String>,
    #[serde(default)]
    app_metadata: serde_json::Value,
    #[serde(default)]
    user_metadata: serde_json::Value,
    #[serde(default)]
    identities: Vec<SupabaseAuthIdentitySnapshot>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SupabaseAuthIdentitySnapshot {
    id: Option<String>,
    provider: String,
    #[serde(default)]
    identity_data: serde_json::Value,
    email: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SupabaseDeviceRecord {
    id: String,
    user_id: String,
    device_name: Option<String>,
    platform: Option<String>,
    chip_name: Option<String>,
    ram_gb: Option<i64>,
    wan_node_id: Option<String>,
    registered_at: Option<String>,
    last_seen: Option<String>,
    is_active: Option<bool>,
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

#[derive(Debug, Default)]
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
}

/// Shared state between the node runtime and the companion app API.
#[derive(Clone)]
pub struct StatusState {
    pub requests_today: Arc<AtomicU64>,
    pub credits_today: Arc<std::sync::atomic::AtomicI64>,
    pub supplying_since: Arc<AtomicU64>,
    app_version: String,
    install_root: PathBuf,
    display_name: String,
    hardware: HardwareCapability,
    model_dir: PathBuf,
    registry_store: RegistryStore,
    swap: Arc<SwapManager>,
    llama_template: Option<LlamaConfig>,
    control: ControlConfig,
    relay_url: String,
    node_state: Arc<NodeRuntimeState>,
    inner: Arc<Mutex<RuntimeInner>>,
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
        control: ControlConfig,
        relay_url: String,
        node_state: Arc<NodeRuntimeState>,
    ) -> Self {
        let initializing = registry.active_model_id.is_none();
        Self {
            requests_today: Arc::new(AtomicU64::new(0)),
            credits_today: Arc::new(std::sync::atomic::AtomicI64::new(0)),
            supplying_since: Arc::new(AtomicU64::new(0)),
            app_version: installed_app_version(),
            install_root: resolved_install_root(),
            display_name,
            hardware,
            model_dir,
            registry_store,
            swap,
            llama_template,
            control,
            relay_url,
            node_state,
            inner: Arc::new(Mutex::new(RuntimeInner {
                registry,
                initializing,
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
        let recommended = recommended_model(self.hardware.total_ram_gb).map(|m| m.id.to_string());
        let on_ac = self.node_state.on_ac_power.load(Ordering::SeqCst);
        let inner = self.inner.lock().await;
        let service_state = self.resolve_state(&inner, current_model_id.as_deref(), on_ac);
        let state_reason = self.state_reason(&inner, service_state);

        AppSnapshot {
            app_version: self.app_version.clone(),
            service_state: service_state.as_str().to_string(),
            state_reason,
            device: DeviceSnapshot {
                display_name: self.display_name.clone(),
                hardware: self.hardware.clone(),
                gpu_backend: self.hardware.gpu_backend.clone(),
                on_ac,
            },
            auth: self.auth_snapshot(),
            demand: self.demand_snapshot(&inner, current_model_id.clone()),
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
            updater: self.updater_snapshot(),
        }
    }

    async fn update_updater_settings(
        &self,
        payload: UpdaterSettingsRequest,
    ) -> anyhow::Result<AppSnapshot> {
        let auto_download = payload.auto_download || payload.auto_install_after_download;
        let settings = UpdaterSettingsRecord {
            auto_download,
            auto_install_after_download: auto_download && payload.auto_install_after_download,
        };
        self.write_json_file(&self.updater_settings_path(), &settings)?;
        Ok(self.snapshot().await)
    }

    fn run_updater(&self, action: &str) -> anyhow::Result<()> {
        let script_path = self.install_root.join("check-update.ps1");
        if !script_path.exists() {
            anyhow::bail!("updater script not found at {}", script_path.display());
        }

        let mut command = Command::new("powershell.exe");
        command
            .arg("-ExecutionPolicy")
            .arg("Bypass")
            .arg("-WindowStyle")
            .arg("Hidden")
            .arg("-File")
            .arg(&script_path);

        match action {
            "check" => {
                command.arg("-Quiet");
            }
            "download" => {
                command.arg("-Quiet");
                command.arg("-ForceDownload");
            }
            "installDownloaded" => {
                command.arg("-Quiet");
                command.arg("-InstallDownloaded");
            }
            _ => anyhow::bail!("unsupported updater action: {action}"),
        }

        command
            .spawn()
            .with_context(|| format!("launch updater script {}", script_path.display()))?;
        Ok(())
    }

    fn updater_snapshot(&self) -> UpdaterSnapshot {
        let settings = self.read_updater_settings();
        let mut state = self.read_updater_state();

        if let Some(path) = state.downloaded_installer_path.as_deref() {
            if !Path::new(path).exists() {
                state.downloaded_tag = None;
                state.downloaded_installer_path = None;
                if state.status == "downloaded" {
                    state.status = "available".to_string();
                }
            }
        }

        UpdaterSnapshot {
            auto_download: settings.auto_download,
            auto_install_after_download: settings.auto_install_after_download,
            latest_tag: state.latest_tag,
            latest_release_url: state.latest_release_url,
            downloaded_tag: state.downloaded_tag,
            downloaded_installer_path: state.downloaded_installer_path,
            status: state.status,
            last_error: state.last_error,
            last_checked_at: state.last_checked_at,
            last_downloaded_at: state.last_downloaded_at,
            last_installed_at: state.last_installed_at,
        }
    }

    fn read_updater_settings(&self) -> UpdaterSettingsRecord {
        self.read_json_file(&self.updater_settings_path())
            .unwrap_or_default()
    }

    fn read_updater_state(&self) -> UpdaterStateRecord {
        self.read_json_file(&self.updater_state_path())
            .unwrap_or_default()
    }

    fn updater_settings_path(&self) -> PathBuf {
        self.install_root
            .join("config")
            .join("updater-settings.json")
    }

    fn updater_state_path(&self) -> PathBuf {
        self.install_root.join("config").join("updater-state.json")
    }

    fn read_json_file<T>(&self, path: &Path) -> Option<T>
    where
        T: for<'de> Deserialize<'de>,
    {
        let raw = std::fs::read_to_string(path).ok()?;
        serde_json::from_str(&raw).ok()
    }

    fn write_json_file<T>(&self, path: &Path, value: &T) -> anyhow::Result<()>
    where
        T: Serialize,
    {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("create updater config dir {}", parent.display()))?;
        }
        let payload = serde_json::to_vec_pretty(value).context("serialize updater json")?;
        std::fs::write(path, payload)
            .with_context(|| format!("write updater file {}", path.display()))?;
        Ok(())
    }

    pub(crate) async fn legacy_status(&self) -> LegacyStatusDTO {
        let current_model_id = self.swap.current_model_id().await;
        let on_ac = self.node_state.on_ac_power.load(Ordering::SeqCst);
        let inner = self.inner.lock().await;
        let state = self.resolve_state(&inner, current_model_id.as_deref(), on_ac);
        LegacyStatusDTO {
            state: state.legacy_state().to_string(),
            supplying_since: self.supplying_since_secs().map(|secs| secs.to_string()),
            requests_today: self.live_requests_today(),
            credits_today: self.live_credits_today(state, current_model_id.as_deref()),
            on_ac,
            paused_reason: state.legacy_paused_reason().map(str::to_string),
        }
    }

    pub async fn pause_supply(&self) {
        self.node_state.user_paused.store(true, Ordering::SeqCst);
    }

    pub async fn resume_supply(&self) {
        self.node_state.user_paused.store(false, Ordering::SeqCst);
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
            return ServiceState::Serving;
        }
        if inner.last_fatal_error.is_some() {
            return ServiceState::Error;
        }
        ServiceState::NeedsModel
    }

    fn state_reason(&self, inner: &RuntimeInner, state: ServiceState) -> Option<String> {
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
                .and_then(model_by_id)
                .map(|model| {
                    (
                        model.availability_credits_per_tick(),
                        model.availability_credits_per_minute(),
                    )
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

    fn auth_snapshot(&self) -> AuthConfigSnapshot {
        let configured = !self.control.supabase_url.trim().is_empty()
            && !self.control.supabase_anon_key.trim().is_empty();
        AuthConfigSnapshot {
            configured,
            supabase_url: configured.then(|| self.control.supabase_url.clone()),
            supabase_anon_key: configured.then(|| self.control.supabase_anon_key.clone()),
            redirect_url: configured.then(|| self.control.supabase_redirect_url.clone()),
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

    async fn auth_session_snapshot(
        &self,
        access_token: &str,
    ) -> anyhow::Result<SupabaseAuthSessionSnapshot> {
        let supabase_url = self.control.supabase_url.trim();
        let supabase_anon_key = self.control.supabase_anon_key.trim();
        if supabase_url.is_empty() || supabase_anon_key.is_empty() {
            anyhow::bail!("supabase auth is not configured");
        }
        if access_token.trim().is_empty() {
            anyhow::bail!("missing supabase access token");
        }

        let url = format!("{}/auth/v1/user", supabase_url.trim_end_matches('/'));
        let client = supabase_client(Duration::from_secs(10))?;
        let response = client
            .get(&url)
            .header("apikey", supabase_anon_key)
            .bearer_auth(access_token)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        let response = response
            .error_for_status()
            .with_context(|| format!("supabase user lookup failed at {url}"))?;
        let user = response
            .json::<SupabaseAuthUserSnapshot>()
            .await
            .context("decode supabase auth user response")?;
        let identities = user.identities.clone();
        let devices = self
            .supabase_devices_snapshot(
                &client,
                supabase_url,
                supabase_anon_key,
                access_token,
                &user.id,
            )
            .await
            .unwrap_or_default();

        Ok(SupabaseAuthSessionSnapshot {
            user,
            identities,
            devices,
        })
    }

    async fn supabase_devices_snapshot(
        &self,
        client: &reqwest::Client,
        supabase_url: &str,
        supabase_anon_key: &str,
        access_token: &str,
        user_id: &str,
    ) -> anyhow::Result<Vec<SupabaseDeviceRecord>> {
        let url = format!("{}/rest/v1/devices", supabase_url.trim_end_matches('/'));
        let response = client
            .get(&url)
            .query(&[
                (
                    "select",
                    "id,user_id,device_name,platform,chip_name,ram_gb,wan_node_id,registered_at,last_seen,is_active",
                ),
                ("user_id", &format!("eq.{user_id}")),
                ("order", "last_seen.desc"),
            ])
            .header("apikey", supabase_anon_key)
            .bearer_auth(access_token)
            .send()
            .await
            .with_context(|| format!("GET {url}"))?;
        let response = response
            .error_for_status()
            .with_context(|| format!("supabase devices lookup failed at {url}"))?;
        response
            .json::<Vec<SupabaseDeviceRecord>>()
            .await
            .context("decode supabase devices response")
    }

    async fn link_account(&self, payload: AccountLinkRequest) -> anyhow::Result<AccountSnapshot> {
        let token = self.gateway_device_token().await?;
        let gateway_base_url = relay_to_gateway_base_url(&self.relay_url);
        let url = format!("{gateway_base_url}/account/link");
        let client = gateway_client(Duration::from_secs(15))?;
        let response = client
            .post(&url)
            .bearer_auth(token)
            .json(&json!({
                "accountUserID": payload.account_user_id,
                "deviceName": self.display_name,
                "platform": "windows",
                "displayName": payload.display_name,
                "phone": payload.phone,
                "email": payload.email,
                "githubUsername": payload.github_username,
            }))
            .send()
            .await
            .with_context(|| format!("POST {url}"))?;
        response
            .error_for_status()
            .with_context(|| format!("account link failed at {url}"))?
            .json::<AccountSnapshot>()
            .await
            .context("decode account link response")
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

        let Some(model) = current_model_id.and_then(model_by_id) else {
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
        elapsed_ticks as i64 * model.availability_credits_per_tick()
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
        while let Some(chunk) = response.chunk().await? {
            file.write_all(&chunk).await?;
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
        Ok(())
    }
}

fn installed_app_version() -> String {
    version_file_for_current_install()
        .and_then(|path| std::fs::read_to_string(path).ok())
        .map(|raw| raw.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| env!("CARGO_PKG_VERSION").to_string())
}

fn resolved_install_root() -> PathBuf {
    current_install_root()
        .unwrap_or_else(|| std::env::current_dir().unwrap_or_else(|_| PathBuf::from("C:\\Teale")))
}

fn current_install_root() -> Option<PathBuf> {
    let current_exe = std::env::current_exe().ok()?;
    Some(current_exe.parent()?.parent()?.to_path_buf())
}

fn version_file_for_current_install() -> Option<PathBuf> {
    Some(current_install_root()?.join("version.txt"))
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

fn supabase_client(timeout: Duration) -> anyhow::Result<reqwest::Client> {
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
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") {
                content_length = value.trim().parse::<usize>().map_err(|e| {
                    (
                        "400 Bad Request",
                        format!("invalid Content-Length header: {e}"),
                    )
                })?;
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
        body: buffer[body_start..body_start + content_length].to_vec(),
    }))
}

async fn proxy_chat_completion(
    body: &[u8],
    state: Arc<StatusState>,
) -> Result<reqwest::Response, (&'static str, String)> {
    let payload: AppChatRequest = serde_json::from_slice(body)
        .map_err(|e| ("400 Bad Request", format!("invalid chat payload: {e}")))?;

    let mut request = payload.request;
    request.stream = Some(true);
    request.stream_options = Some(json!({ "include_usage": true }));

    let (url, bearer_token) = match payload.provider {
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
            (format!("http://127.0.0.1:{port}/v1/chat/completions"), None)
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
            (
                format!(
                    "{}/chat/completions",
                    relay_to_gateway_base_url(&state.relay_url)
                ),
                Some(token),
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
        .json(&request);
    if let Some(token) = bearer_token {
        builder = builder.bearer_auth(token);
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

    Ok(response)
}

async fn write_sse_response<W: AsyncWrite + Unpin>(
    writer: &mut W,
    response: reqwest::Response,
) -> Result<(), (&'static str, String)> {
    let headers = concat!(
        "HTTP/1.1 200 OK\r\n",
        "Content-Type: text/event-stream; charset=utf-8\r\n",
        "Connection: close\r\n",
        "Cache-Control: no-store\r\n",
        "Access-Control-Allow-Origin: *\r\n",
        "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n",
        "Access-Control-Allow-Headers: Content-Type, Accept\r\n",
        "Access-Control-Max-Age: 86400\r\n",
        "Access-Control-Allow-Private-Network: true\r\n",
        "\r\n"
    );
    writer.write_all(headers.as_bytes()).await.map_err(|e| {
        (
            "500 Internal Server Error",
            format!("could not write SSE headers: {e}"),
        )
    })?;

    let mut stream = response.bytes_stream();
    while let Some(chunk) = stream.next().await {
        match chunk {
            Ok(bytes) => {
                if let Err(err) = writer.write_all(&bytes).await {
                    warn!("chat proxy write failed: {err}");
                    return Ok(());
                }
            }
            Err(err) => {
                warn!("chat proxy stream failed: {err:#}");
                return Ok(());
            }
        }
    }

    let _ = writer.flush().await;
    Ok(())
}

async fn handle_chat_proxy(
    stream: &mut tokio::net::TcpStream,
    body: &[u8],
    state: Arc<StatusState>,
) -> Result<(), (&'static str, String)> {
    let response = proxy_chat_completion(body, state).await?;
    write_sse_response(stream, response).await
}

pub fn spawn(state: Arc<StatusState>, port: u16) {
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
            tokio::spawn(async move {
                if let Err(e) = handle(stream, state).await {
                    tracing::debug!("status server: request error: {e}");
                }
            });
        }
    });
}

async fn handle(
    mut stream: tokio::net::TcpStream,
    state: Arc<StatusState>,
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

    if request.method == "POST" && request.path == "/v1/app/chat/completions" {
        if let Err((status, message)) =
            handle_chat_proxy(&mut stream, &request.body, state.clone()).await
        {
            let response = HttpResponse::json(status, json!({ "error": message }).to_string());
            let _ = stream.write_all(response.render().as_bytes()).await;
        }
        return Ok(());
    }

    let response = match route(&request.method, &request.path, &request.body, state).await {
        Ok(resp) => resp,
        Err((status, message)) => {
            HttpResponse::json(status, json!({ "error": message }).to_string())
        }
    };

    let _ = stream.write_all(response.render().as_bytes()).await;
    Ok(())
}

async fn route(
    method: &str,
    path: &str,
    body: &[u8],
    state: Arc<StatusState>,
) -> Result<HttpResponse, (&'static str, String)> {
    if method == "OPTIONS" {
        return Ok(HttpResponse::empty("204 No Content"));
    }

    match (method, path) {
        ("GET", "/status") => {
            let body = serde_json::to_string(&state.legacy_status().await)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
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
        ("POST", "/v1/app/auth/session") => {
            let payload: AuthSessionLookupRequest = serde_json::from_slice(body).map_err(|e| {
                (
                    "400 Bad Request",
                    format!("invalid auth session payload: {e}"),
                )
            })?;
            let body = serde_json::to_string(
                &state
                    .auth_session_snapshot(&payload.access_token)
                    .await
                    .map_err(|e| ("502 Bad Gateway", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("GET", "/v1/app") => {
            let body = serde_json::to_string(&state.snapshot().await)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/updater/settings") => {
            let payload: UpdaterSettingsRequest = serde_json::from_slice(body).map_err(|e| {
                (
                    "400 Bad Request",
                    format!("invalid updater settings payload: {e}"),
                )
            })?;
            let body = serde_json::to_string(
                &state
                    .update_updater_settings(payload)
                    .await
                    .map_err(|e| ("500 Internal Server Error", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/updater/run") => {
            let payload: UpdaterRunRequest = serde_json::from_slice(body).map_err(|e| {
                (
                    "400 Bad Request",
                    format!("invalid updater run payload: {e}"),
                )
            })?;
            state
                .run_updater(payload.action.trim())
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json(
                "200 OK",
                json!({ "started": true }).to_string(),
            ))
        }
        ("GET", "/v1/app/network/models") => {
            let body =
                serde_json::to_string(&state.network_models_snapshot().await.map_err(|e| {
                    (
                        "502 Bad Gateway",
                        format!("could not load gateway models: {e:#}"),
                    )
                })?)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("GET", "/v1/app/network/stats") => {
            let body =
                serde_json::to_string(&state.network_stats_snapshot().await.map_err(|e| {
                    (
                        "502 Bad Gateway",
                        format!("could not load network stats: {e:#}"),
                    )
                })?)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("GET", "/v1/app/account") => {
            let account = match state.account_snapshot().await {
                Ok(account) => account,
                Err(err) if err.to_string().contains("account not linked") => {
                    return Err(("404 Not Found", "account not linked".to_string()))
                }
                Err(err) => return Err(("502 Bad Gateway", err.to_string())),
            };
            let body = serde_json::to_string(&account)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/account/link") => {
            let payload: AccountLinkRequest = serde_json::from_slice(body).map_err(|e| {
                (
                    "400 Bad Request",
                    format!("invalid account link payload: {e}"),
                )
            })?;
            let body = serde_json::to_string(
                &state
                    .link_account(payload)
                    .await
                    .map_err(|e| ("502 Bad Gateway", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/account/sweep") => {
            let payload: AccountDeviceControlRequest =
                serde_json::from_slice(body).map_err(|e| {
                    (
                        "400 Bad Request",
                        format!("invalid account sweep payload: {e}"),
                    )
                })?;
            let body = serde_json::to_string(
                &state
                    .sweep_account_device(&payload.device_id)
                    .await
                    .map_err(|e| ("502 Bad Gateway", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/account/send") => {
            let payload: WalletSendRequest = serde_json::from_slice(body).map_err(|e| {
                (
                    "400 Bad Request",
                    format!("invalid account send payload: {e}"),
                )
            })?;
            let body = serde_json::to_string(
                &state
                    .send_account_wallet(payload)
                    .await
                    .map_err(|e| ("502 Bad Gateway", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/account/devices/remove") => {
            let payload: AccountDeviceControlRequest =
                serde_json::from_slice(body).map_err(|e| {
                    (
                        "400 Bad Request",
                        format!("invalid remove device payload: {e}"),
                    )
                })?;
            let body = serde_json::to_string(
                &state
                    .remove_account_device(&payload.device_id)
                    .await
                    .map_err(|e| ("502 Bad Gateway", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/models/download") => {
            let payload: ModelControlRequest = serde_json::from_slice(body)
                .map_err(|e| ("400 Bad Request", format!("invalid model payload: {e}")))?;
            state
                .start_download(&payload.model)
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            let body = serde_json::to_string(&state.snapshot().await)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/models/load") => {
            let payload: ModelControlRequest = serde_json::from_slice(body)
                .map_err(|e| ("400 Bad Request", format!("invalid model payload: {e}")))?;
            state
                .load_model(&payload.model)
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            let body = serde_json::to_string(&state.snapshot().await)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/models/unload") => {
            state
                .unload_model()
                .await
                .map_err(|e| ("409 Conflict", e.to_string()))?;
            let body = serde_json::to_string(&state.snapshot().await)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        ("POST", "/v1/app/wallet/send") => {
            let payload: WalletSendRequest = serde_json::from_slice(body).map_err(|e| {
                (
                    "400 Bad Request",
                    format!("invalid wallet send payload: {e}"),
                )
            })?;
            let body = serde_json::to_string(
                &state
                    .send_device_wallet(payload)
                    .await
                    .map_err(|e| ("502 Bad Gateway", e.to_string()))?,
            )
            .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
        }
        _ => Err(("404 Not Found", "not found".to_string())),
    }
}

struct HttpResponse {
    status: &'static str,
    body: String,
    content_type: &'static str,
}

impl HttpResponse {
    fn json(status: &'static str, body: String) -> Self {
        Self {
            status,
            body,
            content_type: "application/json",
        }
    }

    fn empty(status: &'static str) -> Self {
        Self {
            status,
            body: String::new(),
            content_type: "text/plain; charset=utf-8",
        }
    }

    fn render(&self) -> String {
        format!(
            concat!(
                "HTTP/1.1 {}\r\n",
                "Content-Type: {}\r\n",
                "Content-Length: {}\r\n",
                "Connection: close\r\n",
                "Cache-Control: no-store\r\n",
                "Access-Control-Allow-Origin: *\r\n",
                "Access-Control-Allow-Methods: GET, POST, OPTIONS\r\n",
                "Access-Control-Allow-Headers: Content-Type, Accept\r\n",
                "Access-Control-Max-Age: 86400\r\n",
                "Access-Control-Allow-Private-Network: true\r\n",
                "\r\n{}"
            ),
            self.status,
            self.content_type,
            self.body.len(),
            self.body
        )
    }
}

#[cfg(test)]
mod tests {
    use std::path::{Path, PathBuf};
    use std::sync::Arc;

    use super::{
        proxy_chat_completion, read_http_request, route, write_sse_response, ServiceState,
        StatusState,
    };
    use crate::backend::Backend;
    use crate::cluster::NodeRuntimeState;
    use crate::config::{ControlConfig, LlamaConfig};
    use crate::hardware::HardwareCapability;
    use crate::model_registry::{PersistedRegistry, RegistryStore};
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
            PersistedRegistry::default(),
            swap,
            llama,
            ControlConfig::default(),
            relay_url,
            node_state,
        ))
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
    async fn options_preflight_returns_cors_headers() {
        let tmp = temp_dir();
        let state = build_state(
            &tmp,
            "wss://relay.teale.com/ws".to_string(),
            Some(dummy_llama()),
        );

        let response = route("OPTIONS", "/v1/app", b"", state)
            .await
            .expect("preflight ok");
        let rendered = response.render();
        assert!(rendered.contains("204 No Content"));
        assert!(rendered.contains("Access-Control-Allow-Origin: *"));
        assert!(rendered.contains("Access-Control-Allow-Methods: GET, POST, OPTIONS"));
        assert!(rendered.contains("Access-Control-Allow-Headers: Content-Type, Accept"));

        let _ = std::fs::remove_dir_all(&tmp);
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
            assert!(request.contains("\"stream_options\":{\"include_usage\":true}"));

            let body =
                "data: {\"choices\":[{\"delta\":{\"content\":\"hello\"}}]}\n\ndata: [DONE]\n\n";
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

        let response = proxy_chat_completion(
            br#"{"provider":"network","model":"meta-llama/test","messages":[{"role":"user","content":"hi"}],"stream":true}"#,
            state,
        )
        .await
        .expect("proxy chat response");

        let (mut writer, mut reader) = tokio::io::duplex(4096);
        let forward_task = tokio::spawn(async move {
            write_sse_response(&mut writer, response)
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

        let output = String::from_utf8(rendered).expect("stream output utf8");
        assert!(output.contains("HTTP/1.1 200 OK"));
        assert!(output.contains("Content-Type: text/event-stream; charset=utf-8"));
        assert!(output.contains("data: [DONE]"));
        assert!(output.contains("\"hello\""));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
