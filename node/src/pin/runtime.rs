//! Node-side PIN runtime: bundles the manager, transport, usage batcher and
//! device-local settings, and runs the model-policy reconciler.

use std::path::PathBuf;
use std::sync::Arc;

use anyhow::Result;
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};

use super::manager::{PinManager, SyncAdvertisement};
use super::usage::UsageBatcher;
use crate::identity::NodeIdentity;

/// Device-local opt-outs — controlled only on this machine, never remotely
/// (spec §4). Persisted next to the netmap cache.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase", default)]
pub struct LocalPinSettings {
    /// Accept admin/modelrator model pushes (spec §10). Default on for
    /// serving devices; opting out reports `opted_out` upstream.
    pub allow_remote_models: bool,
    /// Restore plain DIN/PIN competition instead of PIN-first (spec §9).
    pub din_priority_equal: bool,
    /// Contribute excess capacity to the public DIN.
    pub din_contribute: bool,
}

impl Default for LocalPinSettings {
    fn default() -> Self {
        Self {
            allow_remote_models: true,
            din_priority_equal: false,
            din_contribute: true,
        }
    }
}

/// One reconciliation report row: (pin_id, model_id, applied_state, error).
pub type PolicyStatus = (String, String, String, Option<String>);

/// What the policy reconciler needs from the inference stack. Implemented by
/// `StatusState` in production.
pub trait ModelOps: Send + Sync + 'static {
    fn loaded_models(&self) -> impl std::future::Future<Output = Vec<String>> + Send;
    fn downloaded_models(&self) -> impl std::future::Future<Output = Vec<String>> + Send;
    fn ensure_download(
        &self,
        model_id: &str,
    ) -> impl std::future::Future<Output = Result<()>> + Send;
    fn ensure_loaded(&self, model_id: &str)
        -> impl std::future::Future<Output = Result<()>> + Send;
}

pub struct PinRuntime {
    pub manager: Arc<PinManager>,
    pub identity: Arc<NodeIdentity>,
    pub usage: Arc<UsageBatcher>,
    /// Actual bound UDP port of the transport listener.
    pub transport_port: u16,
    settings_path: PathBuf,
    settings: Mutex<LocalPinSettings>,
    /// Latest reconciliation results, drained into each sync advertisement.
    policy_status: Mutex<Vec<PolicyStatus>>,
}

impl PinRuntime {
    pub fn new(
        manager: Arc<PinManager>,
        identity: Arc<NodeIdentity>,
        usage: Arc<UsageBatcher>,
        transport_port: u16,
        data_dir: PathBuf,
    ) -> Arc<Self> {
        let settings_path = data_dir.join("local-settings.json");
        let settings = std::fs::read(&settings_path)
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default();
        Arc::new(Self {
            manager,
            identity,
            usage,
            transport_port,
            settings_path,
            settings: Mutex::new(settings),
            policy_status: Mutex::new(Vec::new()),
        })
    }

    pub fn settings(&self) -> LocalPinSettings {
        self.settings.lock().clone()
    }

    pub fn update_settings(
        &self,
        update: impl FnOnce(&mut LocalPinSettings),
    ) -> Result<LocalPinSettings> {
        let mut guard = self.settings.lock();
        update(&mut guard);
        std::fs::write(&self.settings_path, serde_json::to_vec_pretty(&*guard)?)?;
        Ok(guard.clone())
    }

    pub fn record_policy_status(&self, status: Vec<PolicyStatus>) {
        *self.policy_status.lock() = status;
    }

    /// Build the sync advertisement for this tick: current endpoints, loaded
    /// models, and the latest policy reconciliation results.
    pub fn advertisement(
        &self,
        endpoints: Vec<teale_protocol::PinEndpoint>,
        loaded_models: Vec<String>,
    ) -> SyncAdvertisement {
        SyncAdvertisement {
            endpoints,
            loaded_models,
            model_policy_status: self.policy_status.lock().clone(),
        }
    }
}

/// Wire the full PIN runtime into a running node: manager + sync loop,
/// transport listener + serving, policy reconciler, and local settings
/// applied to the admission gate. Returns None when the node has no relay
/// URL to derive a gateway from (dev configs).
pub async fn spawn_pin_runtime(
    config: &crate::config::Config,
    identity: Arc<NodeIdentity>,
    node_state: Arc<crate::cluster::NodeRuntimeState>,
    swap: Arc<crate::swap::SwapManager>,
    status: Arc<crate::status_server::StatusState>,
) -> Result<Option<Arc<PinRuntime>>> {
    let gateway_url = crate::gateway_wallet::derive_gateway_url(&config.relay.url)?;
    let data_dir = config
        .pin
        .data_dir
        .clone()
        .map(PathBuf::from)
        .unwrap_or_else(|| dirs_next_data_dir().join("teale").join("pin"));

    let manager = PinManager::new(
        gateway_url,
        identity.clone(),
        data_dir.clone(),
        config.pin.gateway_pubkey.clone(),
    )?;
    let usage = UsageBatcher::new(data_dir.join("usage"))?;

    // Data plane listener. config.pin.port = 0 → ephemeral.
    let listener = super::transport::PinListener::bind(
        &format!("0.0.0.0:{}", config.pin.port),
        identity.wg_static(),
        manager.authorizer(),
    )
    .await?;
    let transport_port = listener.local_addr()?.port();

    let runtime = PinRuntime::new(
        manager.clone(),
        identity.clone(),
        usage.clone(),
        transport_port,
        data_dir,
    );

    // Local settings drive the admission gate from the start.
    node_state
        .pin_gate
        .set_din_priority_equal(runtime.settings().din_priority_equal);

    // Serving path (PIN-first admission, netmap-authenticated peers).
    super::serve::spawn_serving(
        listener,
        manager.clone(),
        swap.clone(),
        node_state.pin_gate.clone(),
        usage.clone(),
    );

    // Control-plane sync loop: fresh endpoints + loaded models + policy
    // status each tick, then a policy reconciliation pass and usage flush.
    {
        let runtime = runtime.clone();
        let manager = manager.clone();
        let status = status.clone();
        let preseed = config.pin.join_code.clone();
        tokio::spawn(async move {
            if let Some(code) = preseed {
                if let Err(err) = manager.preseed_join_if_needed(&code).await {
                    tracing::warn!("pin preseed join failed: {err:#}");
                }
            }
            loop {
                let endpoints = super::endpoints::gather(runtime.transport_port).await;
                let loaded = crate::swap::SwapManager::loaded_models(&swap).await;
                let advert = runtime.advertisement(endpoints, loaded);
                if let Err(err) = manager.sync_once(&advert).await {
                    tracing::debug!("pin sync failed (will retry): {err:#}");
                }
                reconcile_policy(&runtime, &status).await;
                if let Err(err) = manager.flush_usage(&runtime.usage).await {
                    tracing::debug!("pin usage flush failed (will retry): {err:#}");
                }
                tokio::time::sleep(std::time::Duration::from_secs(
                    super::manager::SYNC_INTERVAL_SECONDS,
                ))
                .await;
            }
        });
    }

    status.set_pin_runtime(runtime.clone());
    Ok(Some(runtime))
}

/// Platform data dir (mirrors the identity file's location conventions).
fn dirs_next_data_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        std::env::var("APPDATA")
            .map(PathBuf::from)
            .unwrap_or_else(|_| PathBuf::from("."))
    }
    #[cfg(not(target_os = "windows"))]
    {
        std::env::var("HOME")
            .map(|home| PathBuf::from(home).join(".local").join("share"))
            .unwrap_or_else(|_| PathBuf::from("."))
    }
}

/// One reconciliation pass: compare each active network's desired loadout
/// against local reality, execute what's missing, report per-model status.
pub async fn reconcile_policy<M: ModelOps>(runtime: &PinRuntime, ops: &M) -> Vec<PolicyStatus> {
    let mut results: Vec<PolicyStatus> = Vec::new();
    let opted_out = !runtime.settings().allow_remote_models;

    for pin in runtime.manager.snapshot() {
        if pin.membership != "active" {
            continue;
        }
        for entry in &pin.model_policy {
            let (Some(model_id), Some(desired)) = (
                entry.get("modelId").and_then(|v| v.as_str()),
                entry.get("desiredState").and_then(|v| v.as_str()),
            ) else {
                continue;
            };
            if opted_out {
                results.push((
                    pin.pin_id.clone(),
                    model_id.to_string(),
                    "opted_out".to_string(),
                    None,
                ));
                continue;
            }
            let loaded = ops.loaded_models().await;
            let downloaded = ops.downloaded_models().await;
            let is_loaded = loaded.iter().any(|m| m == model_id);
            let is_downloaded = is_loaded || downloaded.iter().any(|m| m == model_id);
            let status = match desired {
                "loaded" if is_loaded => ("loaded".to_string(), None),
                "loaded" => {
                    let step = async {
                        if !is_downloaded {
                            ops.ensure_download(model_id).await?;
                        }
                        ops.ensure_loaded(model_id).await
                    };
                    match step.await {
                        Ok(()) => ("loaded".to_string(), None),
                        Err(err) if !is_downloaded => {
                            ("downloading".to_string(), Some(err.to_string()))
                        }
                        Err(err) => ("error".to_string(), Some(err.to_string())),
                    }
                }
                "downloaded" if is_downloaded => ("downloaded".to_string(), None),
                "downloaded" => match ops.ensure_download(model_id).await {
                    Ok(()) => ("downloaded".to_string(), None),
                    Err(err) => ("downloading".to_string(), Some(err.to_string())),
                },
                // v1 never force-unloads: another network (or the local
                // user) may still want the weights. Report reality.
                _ => (
                    if is_loaded {
                        "loaded".to_string()
                    } else if is_downloaded {
                        "downloaded".to_string()
                    } else {
                        "absent".to_string()
                    },
                    None,
                ),
            };
            results.push((pin.pin_id.clone(), model_id.to_string(), status.0, status.1));
        }
    }
    runtime.record_policy_status(results.clone());
    results
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use std::path::Path;
    use teale_protocol::{canonical_json, PinNetmap, SignedPinNetmap};

    struct FakeOps {
        loaded: Mutex<Vec<String>>,
        downloaded: Mutex<Vec<String>>,
        fail_downloads: bool,
    }
    impl ModelOps for FakeOps {
        async fn loaded_models(&self) -> Vec<String> {
            self.loaded.lock().clone()
        }
        async fn downloaded_models(&self) -> Vec<String> {
            self.downloaded.lock().clone()
        }
        async fn ensure_download(&self, model_id: &str) -> Result<()> {
            if self.fail_downloads {
                anyhow::bail!("disk full");
            }
            self.downloaded.lock().push(model_id.to_string());
            Ok(())
        }
        async fn ensure_loaded(&self, model_id: &str) -> Result<()> {
            self.loaded.lock().push(model_id.to_string());
            Ok(())
        }
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pin-rt-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn runtime_with_policy(dir: &Path, policy: Vec<serde_json::Value>) -> Arc<PinRuntime> {
        let identity = Arc::new(NodeIdentity::load_or_create_in(dir.join("id.key")).unwrap());
        let manager = PinManager::new(
            "http://127.0.0.1:9".into(),
            identity.clone(),
            dir.join("pin"),
            None,
        )
        .unwrap();
        // Plant an active membership carrying the policy.
        let key = SigningKey::from_bytes(&[33u8; 32]);
        let netmap = PinNetmap {
            pin_id: "pin-p".into(),
            name: "p".into(),
            generation: 1,
            issued_at: crate::gateway_wallet::now_unix_secs() as i64,
            members: vec![],
        };
        let message = canonical_json(&netmap).unwrap();
        manager.plant_state_for_tests(
            "pin-p",
            "p",
            SignedPinNetmap {
                gateway_pubkey: hex::encode(key.verifying_key().as_bytes()),
                signature: hex::encode(key.sign(&message).to_bytes()),
                netmap,
            },
        );
        manager.plant_policy_for_tests("pin-p", policy);
        let usage = UsageBatcher::new(dir.join("usage")).unwrap();
        PinRuntime::new(manager, identity, usage, 0, dir.join("pin"))
    }

    #[tokio::test]
    async fn reconciles_desired_loadout() {
        let dir = temp_dir();
        let runtime = runtime_with_policy(
            &dir,
            vec![
                serde_json::json!({"modelId": "m-load", "desiredState": "loaded"}),
                serde_json::json!({"modelId": "m-dl", "desiredState": "downloaded"}),
                serde_json::json!({"modelId": "m-none", "desiredState": "none"}),
            ],
        );
        let ops = FakeOps {
            loaded: Mutex::new(vec![]),
            downloaded: Mutex::new(vec![]),
            fail_downloads: false,
        };
        let results = reconcile_policy(&runtime, &ops).await;
        let by_model: std::collections::HashMap<_, _> = results
            .iter()
            .map(|(_, m, s, _)| (m.clone(), s.clone()))
            .collect();
        assert_eq!(by_model["m-load"], "loaded");
        assert_eq!(by_model["m-dl"], "downloaded");
        assert_eq!(by_model["m-none"], "absent");
        assert!(ops.loaded.lock().contains(&"m-load".to_string()));

        // Status feeds the next sync advertisement.
        let advert = runtime.advertisement(vec![], vec![]);
        assert_eq!(advert.model_policy_status.len(), 3);
    }

    #[tokio::test]
    async fn opt_out_blocks_execution_and_reports() {
        let dir = temp_dir();
        let runtime = runtime_with_policy(
            &dir,
            vec![serde_json::json!({"modelId": "m1", "desiredState": "loaded"})],
        );
        runtime
            .update_settings(|s| s.allow_remote_models = false)
            .unwrap();
        let ops = FakeOps {
            loaded: Mutex::new(vec![]),
            downloaded: Mutex::new(vec![]),
            fail_downloads: false,
        };
        let results = reconcile_policy(&runtime, &ops).await;
        assert_eq!(results[0].2, "opted_out");
        assert!(ops.loaded.lock().is_empty(), "no execution when opted out");
    }

    #[tokio::test]
    async fn failures_surface_as_errors() {
        let dir = temp_dir();
        let runtime = runtime_with_policy(
            &dir,
            vec![serde_json::json!({"modelId": "m1", "desiredState": "loaded"})],
        );
        let ops = FakeOps {
            loaded: Mutex::new(vec![]),
            downloaded: Mutex::new(vec![]),
            fail_downloads: true,
        };
        let results = reconcile_policy(&runtime, &ops).await;
        assert_eq!(results[0].2, "downloading");
        assert!(results[0].3.as_deref().unwrap().contains("disk full"));
    }

    #[test]
    fn settings_persist_across_restarts() {
        let dir = temp_dir();
        let runtime = runtime_with_policy(&dir, vec![]);
        runtime
            .update_settings(|s| {
                s.din_priority_equal = true;
                s.din_contribute = false;
            })
            .unwrap();
        drop(runtime);
        let runtime = runtime_with_policy(&dir, vec![]);
        let settings = runtime.settings();
        assert!(settings.din_priority_equal);
        assert!(!settings.din_contribute);
        assert!(settings.allow_remote_models);
    }
}
