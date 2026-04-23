//! Localhost control API for the Windows companion app.
//!
//! Bound to `127.0.0.1` only. This server powers both the tray icon and the
//! embedded desktop companion UI. Legacy `/status`, `/pause`, and `/resume`
//! remain for back-compat with earlier tray-only pilots.

use std::collections::HashMap;
use std::convert::Infallible;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use anyhow::Context;
use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
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

#[derive(Debug, Serialize, Deserialize)]
struct AccountSweepResponse {
    swept_credits: i64,
    swept_usdc_cents: i64,
    account: AccountSnapshot,
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
            app_version: env!("CARGO_PKG_VERSION").to_string(),
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
        }
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
                device_count: device_counts.get(&model.id).copied().unwrap_or(0),
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
    let mut buf = vec![0u8; 8192];
    let n = match stream.read(&mut buf).await {
        Ok(n) => n,
        Err(_) => return Ok(()),
    };
    if n == 0 {
        return Ok(());
    }

    let req = String::from_utf8_lossy(&buf[..n]);
    let first_line = req.lines().next().unwrap_or("");
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");
    let body = req.split("\r\n\r\n").nth(1).unwrap_or("").as_bytes();

    let response = match route(method, path, body, state).await {
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
        ("GET", "/v1/app") => {
            let body = serde_json::to_string(&state.snapshot().await)
                .map_err(|e| ("500 Internal Server Error", e.to_string()))?;
            Ok(HttpResponse::json("200 OK", body))
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
                "Access-Control-Allow-Headers: Content-Type\r\n",
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
    use std::sync::Arc;

    use super::{route, ServiceState, StatusState};
    use crate::backend::Backend;
    use crate::cluster::NodeRuntimeState;
    use crate::config::{ControlConfig, LlamaConfig};
    use crate::hardware::HardwareCapability;
    use crate::model_registry::{PersistedRegistry, RegistryStore};
    use crate::swap::SwapManager;

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
            model_id: None,
            gpu_layers: 0,
            context_size: 8192,
            port: 11436,
            extra_args: vec![],
        }
    }

    #[tokio::test]
    async fn snapshot_serializes_needs_model_state() {
        let tmp = std::env::temp_dir().join(format!("teale-status-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).expect("temp dir");
        let registry_store = RegistryStore::new(tmp.join("model-registry.json"));
        let swap = SwapManager::new(
            Backend::Unavailable,
            None,
            String::new(),
            None,
            dummy_llama(),
            vec![],
            Arc::new(NodeRuntimeState::new(1)),
        );
        let node_state = Arc::new(NodeRuntimeState::new(1));
        let state = StatusState::new(
            "WIN".to_string(),
            dummy_hw(16.0),
            tmp.clone(),
            registry_store,
            PersistedRegistry::default(),
            swap,
            Some(dummy_llama()),
            ControlConfig::default(),
            "wss://relay.teale.com/ws".to_string(),
            node_state,
        );
        state.clear_starting().await;

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.service_state, ServiceState::NeedsModel.as_str());

        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[tokio::test]
    async fn options_preflight_returns_cors_headers() {
        let tmp = std::env::temp_dir().join(format!("teale-status-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&tmp).expect("temp dir");
        let registry_store = RegistryStore::new(tmp.join("model-registry.json"));
        let node_state = Arc::new(NodeRuntimeState::new(1));
        let state = Arc::new(StatusState::new(
            "WIN".to_string(),
            dummy_hw(16.0),
            tmp.clone(),
            registry_store,
            PersistedRegistry::default(),
            SwapManager::new(
                Backend::Unavailable,
                None,
                String::new(),
                None,
                dummy_llama(),
                vec![],
                node_state.clone(),
            ),
            Some(dummy_llama()),
            ControlConfig::default(),
            "wss://relay.teale.com/ws".to_string(),
            node_state,
        ));

        let response = route("OPTIONS", "/v1/app", b"", state)
            .await
            .expect("preflight ok");
        let rendered = response.render();
        assert!(rendered.contains("204 No Content"));
        assert!(rendered.contains("Access-Control-Allow-Origin: *"));
        assert!(rendered.contains("Access-Control-Allow-Methods: GET, POST, OPTIONS"));

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
