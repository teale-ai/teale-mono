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

use serde::{Deserialize, Serialize};
use serde_json::json;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::sync::Mutex;
use tracing::{info, warn};

use crate::cluster::NodeRuntimeState;
use crate::config::LlamaConfig;
use crate::hardware::HardwareCapability;
use crate::model_registry::{PersistedRegistry, RegistryStore};
use crate::swap::SwapManager;
use crate::windows_model_catalog::{
    compatible_models, model_by_id, recommended_model, WindowsCatalogModel,
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
pub struct AppSnapshot {
    pub app_version: String,
    pub service_state: String,
    pub state_reason: Option<String>,
    pub device: DeviceSnapshot,
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

#[derive(Debug, Clone)]
struct InFlightTransfer {
    model_id: String,
    phase: String,
    started_at: Instant,
    bytes_downloaded: u64,
    bytes_total: Option<u64>,
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
            loaded_model_id: current_model_id.clone(),
            models: compatible_models(self.hardware.total_ram_gb)
                .into_iter()
                .map(|model| self.model_snapshot(&inner, &model, current_model_id.as_deref(), recommended.as_deref()))
                .collect(),
            active_transfer: inner.active_transfer.as_ref().map(InFlightTransfer::snapshot),
        }
    }

    pub(crate) async fn legacy_status(&self) -> LegacyStatusDTO {
        let current_model_id = self.swap.current_model_id().await;
        let on_ac = self.node_state.on_ac_power.load(Ordering::SeqCst);
        let inner = self.inner.lock().await;
        let state = self.resolve_state(&inner, current_model_id.as_deref(), on_ac);
        LegacyStatusDTO {
            state: state.legacy_state().to_string(),
            supplying_since: match self.supplying_since.load(Ordering::SeqCst) {
                0 => None,
                secs => Some(secs.to_string()),
            },
            requests_today: self.requests_today.load(Ordering::SeqCst),
            credits_today: self.credits_today.load(Ordering::SeqCst),
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
            let record = inner.registry.models.entry(model.id.to_string()).or_default();
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
            let record = inner.registry.models.entry(model.id.to_string()).or_default();
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
        let result = self
            .swap
            .load_local_model(
                request_id,
                model.id.to_string(),
                path,
                Some(model.default_context),
            )
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

    async fn download_model_task(self: Arc<Self>, model: WindowsCatalogModel) -> anyhow::Result<()> {
        let final_path = self.model_dir.join(model.file_name);
        tokio::fs::create_dir_all(&self.model_dir).await?;
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(0))
            .build()?;

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
                    errors.push(format!("{url}: {e}"));
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
            inner.download_progress.insert(model.id.to_string(), progress);
            if let Some(transfer) = &mut inner.active_transfer {
                transfer.bytes_downloaded = downloaded;
                transfer.bytes_total = total;
            }
        }
        file.flush().await?;
        Ok(())
    }
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

async fn handle(mut stream: tokio::net::TcpStream, state: Arc<StatusState>) -> Result<(), Infallible> {
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
        Err((status, message)) => HttpResponse::json(status, json!({ "error": message }).to_string()),
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
            Ok(HttpResponse::json("200 OK", json!({ "ok": true }).to_string()))
        }
        ("GET", "/v1/app") => {
            let body = serde_json::to_string(&state.snapshot().await)
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

    fn render(&self) -> String {
        format!(
            "HTTP/1.1 {}\r\nContent-Type: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
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

    use super::{ServiceState, StatusState};
    use crate::backend::Backend;
    use crate::cluster::NodeRuntimeState;
    use crate::config::LlamaConfig;
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
            node_state,
        );
        state.clear_starting().await;

        let snapshot = state.snapshot().await;
        assert_eq!(snapshot.service_state, ServiceState::NeedsModel.as_str());

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
