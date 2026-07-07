//! PIN membership manager: join, 60-second control-plane sync, signed
//! netmap caching with TOFU gateway-key pinning, and the peer-authorization
//! view the data-plane transport consults.
//!
//! Privacy boundary: everything this module sends the gateway is metadata —
//! endpoints, loaded model ids, policy status, token counts. Prompt bytes
//! only ever ride the direct Noise transport.

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;

use anyhow::{Context, Result};
use parking_lot::Mutex;
use serde::{Deserialize, Serialize};
use tokio::sync::Mutex as AsyncMutex;
use x25519_dalek::PublicKey;

use crate::gateway_wallet::{ensure_device_token, DeviceToken};
use crate::identity::NodeIdentity;
use teale_protocol::{PinEndpoint, SignedPinNetmap};

pub const SYNC_INTERVAL_SECONDS: u64 = 60;

/// Gateway scheduling answer: which member to dial. Connection material
/// (wg key, endpoints) is resolved from the netmap by device id.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ScheduleChoice {
    pub device_id: String,
    pub node_pubkey: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PinMembership {
    pub pin_id: String,
    pub name: String,
    /// "pending" | "active" | "disabled" | "none"
    pub status: String,
}

#[derive(Debug, Clone, Serialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PinState {
    pub pin_id: String,
    pub name: String,
    pub membership: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub netmap: Option<SignedPinNetmap>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub settings: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Vec::is_empty", default)]
    pub model_policy: Vec<serde_json::Value>,
}

/// Inputs the sync loop gathers fresh each tick.
#[derive(Debug, Clone, Default)]
pub struct SyncAdvertisement {
    pub endpoints: Vec<PinEndpoint>,
    pub loaded_models: Vec<String>,
    /// (pin_id, model_id, applied_state, error)
    pub model_policy_status: Vec<(String, String, String, Option<String>)>,
}

pub struct PinManager {
    gateway_url: String,
    client: reqwest::Client,
    identity: Arc<NodeIdentity>,
    data_dir: PathBuf,
    token_state: AsyncMutex<Option<DeviceToken>>,
    /// TOFU-pinned gateway Ed25519 key (hex). Config override wins.
    pinned_gateway_key: Mutex<Option<String>>,
    state: Mutex<HashMap<String, PinState>>,
}

impl PinManager {
    pub fn new(
        gateway_url: String,
        identity: Arc<NodeIdentity>,
        data_dir: PathBuf,
        configured_gateway_pubkey: Option<String>,
    ) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&data_dir)
            .with_context(|| format!("create pin data dir {}", data_dir.display()))?;
        let pinned = configured_gateway_pubkey.or_else(|| {
            std::fs::read_to_string(data_dir.join("gateway.pub"))
                .ok()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
        });
        let manager = Arc::new(Self {
            gateway_url,
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(20))
                .build()
                .context("build pin http client")?,
            identity,
            data_dir,
            token_state: AsyncMutex::new(None),
            pinned_gateway_key: Mutex::new(pinned),
            state: Mutex::new(HashMap::new()),
        });
        manager.load_cached_netmaps();
        Ok(manager)
    }

    async fn bearer(&self) -> Result<String> {
        let token = ensure_device_token(
            &self.client,
            &self.gateway_url,
            &self.identity,
            &self.token_state,
        )
        .await?;
        Ok(token.value)
    }

    /// Submit a join request ("knock"). Always accepted by the gateway;
    /// membership shows up as `pending` on the next sync if the code was
    /// valid — deliberately no immediate signal either way.
    pub async fn join(&self, code: &str, display_name: Option<&str>) -> Result<()> {
        let bearer = self.bearer().await?;
        self.client
            .post(format!("{}/v1/pins/join", self.gateway_url))
            .bearer_auth(bearer)
            .json(&serde_json::json!({
                "joinCode": code,
                "displayName": display_name,
                "nodePubkey": self.identity.node_id(),
            }))
            .send()
            .await?
            .error_for_status()
            .context("join request rejected")?;
        Ok(())
    }

    /// Preseeded IT rollout path: knock with the configured code when this
    /// device has no memberships yet (idempotent — re-knocks refresh the
    /// pending request until an admin approves).
    pub async fn preseed_join_if_needed(&self, code: &str) -> Result<()> {
        let memberships = self.fetch_memberships().await?;
        if memberships.is_empty() {
            self.join(code, None).await?;
        }
        Ok(())
    }

    async fn fetch_memberships(&self) -> Result<Vec<PinMembership>> {
        let bearer = self.bearer().await?;
        #[derive(Deserialize)]
        struct ListResponse {
            #[serde(default)]
            memberships: Vec<PinMembership>,
        }
        let resp: ListResponse = self
            .client
            .get(format!("{}/v1/pins", self.gateway_url))
            .bearer_auth(bearer)
            .send()
            .await?
            .error_for_status()?
            .json()
            .await?;
        Ok(resp.memberships)
    }

    /// One control-plane round: refresh memberships, sync each network,
    /// verify + cache netmaps. Returns the number of networks synced.
    pub async fn sync_once(&self, advert: &SyncAdvertisement) -> Result<usize> {
        let memberships = self.fetch_memberships().await?;
        let bearer = self.bearer().await?;
        let mut synced = 0;

        // Prune networks we no longer belong to.
        {
            let known: std::collections::HashSet<&str> =
                memberships.iter().map(|m| m.pin_id.as_str()).collect();
            self.state
                .lock()
                .retain(|id, _| known.contains(id.as_str()));
        }

        for membership in memberships {
            let known_generation = self
                .state
                .lock()
                .get(&membership.pin_id)
                .and_then(|s| s.netmap.as_ref())
                .map(|n| n.netmap.generation);
            let policy_status: Vec<serde_json::Value> = advert
                .model_policy_status
                .iter()
                .filter(|(pin, ..)| *pin == membership.pin_id)
                .map(|(_, model, applied, error)| {
                    serde_json::json!({
                        "modelId": model,
                        "appliedState": applied,
                        "error": error,
                    })
                })
                .collect();

            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct SyncResponse {
                membership: String,
                #[serde(default)]
                netmap: Option<SignedPinNetmap>,
                #[serde(default)]
                model_policy: Vec<serde_json::Value>,
                #[serde(default)]
                settings: Option<serde_json::Value>,
            }
            let resp = self
                .client
                .post(format!(
                    "{}/v1/pins/{}/sync",
                    self.gateway_url, membership.pin_id
                ))
                .bearer_auth(&bearer)
                .json(&serde_json::json!({
                    "endpoints": advert.endpoints,
                    "wgPubkey": self.identity.wg_pubkey_hex(),
                    "loadedModels": advert.loaded_models,
                    "knownGeneration": known_generation,
                    "modelPolicyStatus": policy_status,
                }))
                .send()
                .await?
                .error_for_status()?;
            let resp: SyncResponse = resp.json().await?;

            let mut state = self.state.lock();
            let entry = state
                .entry(membership.pin_id.clone())
                .or_insert_with(|| PinState {
                    pin_id: membership.pin_id.clone(),
                    name: membership.name.clone(),
                    ..Default::default()
                });
            entry.name = membership.name.clone();
            entry.membership = resp.membership;
            entry.model_policy = resp.model_policy;
            entry.settings = resp.settings;
            drop(state);

            if let Some(signed) = resp.netmap {
                self.accept_netmap(&membership.pin_id, signed)?;
            }
            synced += 1;
        }
        Ok(synced)
    }

    /// Verify (TOFU on first contact) and cache a fresh netmap.
    fn accept_netmap(&self, pin_id: &str, signed: SignedPinNetmap) -> Result<()> {
        let pinned = {
            let mut guard = self.pinned_gateway_key.lock();
            match guard.as_ref() {
                Some(key) => key.clone(),
                None => {
                    // Trust-on-first-use: pin the first key we see and
                    // persist it; every later netmap must match.
                    let key = signed.gateway_pubkey.clone();
                    std::fs::write(self.data_dir.join("gateway.pub"), &key)
                        .context("persist pinned gateway key")?;
                    *guard = Some(key.clone());
                    key
                }
            }
        };
        anyhow::ensure!(
            signed.verify(&pinned),
            "netmap signature verification failed for network {pin_id}"
        );
        anyhow::ensure!(
            !signed.is_stale(crate::gateway_wallet::now_unix_secs() as i64),
            "netmap for network {pin_id} is stale"
        );
        std::fs::create_dir_all(self.data_dir.join(pin_id)).ok();
        std::fs::write(
            self.data_dir.join(pin_id).join("netmap.json"),
            serde_json::to_vec_pretty(&signed)?,
        )
        .context("persist netmap")?;
        if let Some(state) = self.state.lock().get_mut(pin_id) {
            state.netmap = Some(signed);
        }
        Ok(())
    }

    /// Load cached netmaps from disk at startup (offline-LAN mode). Only
    /// signature-valid, non-stale caches are accepted.
    fn load_cached_netmaps(&self) {
        let Some(pinned) = self.pinned_gateway_key.lock().clone() else {
            return; // nothing pinned yet — nothing trustworthy to load
        };
        let Ok(entries) = std::fs::read_dir(&self.data_dir) else {
            return;
        };
        let now = crate::gateway_wallet::now_unix_secs() as i64;
        for entry in entries.flatten() {
            let path = entry.path().join("netmap.json");
            let Ok(bytes) = std::fs::read(&path) else {
                continue;
            };
            let Ok(signed) = serde_json::from_slice::<SignedPinNetmap>(&bytes) else {
                continue;
            };
            if !signed.verify(&pinned) || signed.is_stale(now) {
                continue;
            }
            let pin_id = signed.netmap.pin_id.clone();
            self.state.lock().insert(
                pin_id.clone(),
                PinState {
                    pin_id,
                    name: signed.netmap.name.clone(),
                    membership: "active".into(),
                    netmap: Some(signed),
                    settings: None,
                    model_policy: Vec::new(),
                },
            );
        }
    }

    pub fn snapshot(&self) -> Vec<PinState> {
        let mut states: Vec<PinState> = self.state.lock().values().cloned().collect();
        states.sort_by(|a, b| a.name.cmp(&b.name));
        states
    }

    /// Data-plane authorizer: a peer static key is allowed when some current
    /// netmap lists it as an active (not disabled) member. Our own device
    /// must also still be active in that network.
    pub fn authorizer(self: &Arc<Self>) -> super::transport::PeerAuthorizer {
        let manager = self.clone();
        Arc::new(move |peer: &PublicKey| {
            let peer_hex = hex::encode(peer.as_bytes());
            let state = manager.state.lock();
            state.values().any(|pin| {
                pin.membership == "active"
                    && pin.netmap.as_ref().is_some_and(|signed| {
                        signed
                            .netmap
                            .members
                            .iter()
                            .any(|m| !m.disabled && m.wg_pubkey.eq_ignore_ascii_case(&peer_hex))
                    })
            })
        })
    }

    /// Serving candidates for a model across active networks (offline-LAN
    /// scheduling + demand-path fallback).
    pub fn serving_peers_for_model(
        &self,
        model_id: &str,
    ) -> Vec<(String, teale_protocol::PinNetmapMember)> {
        let own_wg = self.identity.wg_pubkey_hex();
        let state = self.state.lock();
        let mut peers = Vec::new();
        for pin in state.values() {
            if pin.membership != "active" {
                continue;
            }
            let Some(signed) = pin.netmap.as_ref() else {
                continue;
            };
            for member in &signed.netmap.members {
                if member.disabled
                    || !member.serves_models
                    || member.wg_pubkey.eq_ignore_ascii_case(&own_wg)
                    || !member.loaded_models.iter().any(|m| m == model_id)
                {
                    continue;
                }
                peers.push((pin.pin_id.clone(), member.clone()));
            }
        }
        peers
    }

    pub fn gateway_url(&self) -> &str {
        &self.gateway_url
    }

    /// Resolve an authenticated peer static key to (pin_id, member) —
    /// which network the peer belongs to and who it is.
    pub fn member_for_wg_key(
        &self,
        wg_pubkey_hex: &str,
    ) -> Option<(String, teale_protocol::PinNetmapMember)> {
        let state = self.state.lock();
        for pin in state.values() {
            if pin.membership != "active" {
                continue;
            }
            let Some(signed) = pin.netmap.as_ref() else {
                continue;
            };
            if let Some(member) = signed
                .netmap
                .members
                .iter()
                .find(|m| !m.disabled && m.wg_pubkey.eq_ignore_ascii_case(wg_pubkey_hex))
            {
                return Some((pin.pin_id.clone(), member.clone()));
            }
        }
        None
    }

    /// Authenticated passthrough for the local app API: forwards a request
    /// to the gateway control plane with this device's bearer and returns
    /// (status, body). Never used for prompt content.
    pub async fn proxy(
        &self,
        method: &str,
        path: &str,
        body: Option<serde_json::Value>,
    ) -> Result<(u16, serde_json::Value)> {
        let bearer = self.bearer().await?;
        let url = format!("{}{}", self.gateway_url, path);
        let mut req = match method {
            "GET" => self.client.get(&url),
            "POST" => self.client.post(&url),
            "PUT" => self.client.put(&url),
            "PATCH" => self.client.patch(&url),
            "DELETE" => self.client.delete(&url),
            other => anyhow::bail!("unsupported proxy method {other}"),
        }
        .bearer_auth(bearer);
        if let Some(body) = body {
            req = req.json(&body);
        }
        let resp = req.send().await?;
        let status = resp.status().as_u16();
        let body = resp
            .json::<serde_json::Value>()
            .await
            .unwrap_or_else(|_| serde_json::json!({}));
        Ok((status, body))
    }

    /// Gateway-side provider choice for one request. Metadata only.
    pub async fn schedule(
        &self,
        pin_id: &str,
        model: &str,
        exclude: &[String],
    ) -> Result<ScheduleChoice> {
        let bearer = self.bearer().await?;
        let resp = self
            .client
            .post(format!("{}/v1/pins/{}/schedule", self.gateway_url, pin_id))
            .bearer_auth(bearer)
            .json(&serde_json::json!({
                "model": model,
                "exclude": exclude,
            }))
            .send()
            .await?
            .error_for_status()?
            .json::<ScheduleChoice>()
            .await?;
        Ok(resp)
    }

    /// Push pending usage batches with this manager's bearer + client.
    pub async fn flush_usage(&self, batcher: &super::usage::UsageBatcher) -> Result<usize> {
        let bearer = self.bearer().await?;
        batcher
            .flush(&self.client, &self.gateway_url, &bearer)
            .await
    }

    /// Test seam: plant a desired model policy without a live control plane.
    #[cfg(test)]
    pub(crate) fn plant_policy_for_tests(&self, pin_id: &str, policy: Vec<serde_json::Value>) {
        if let Some(state) = self.state.lock().get_mut(pin_id) {
            state.model_policy = policy;
        }
    }

    /// Test seam: plant a verified netmap without a live control plane.
    #[cfg(test)]
    pub(crate) fn plant_state_for_tests(
        &self,
        pin_id: &str,
        name: &str,
        netmap: teale_protocol::SignedPinNetmap,
    ) {
        self.state.lock().insert(
            pin_id.to_string(),
            PinState {
                pin_id: pin_id.to_string(),
                name: name.to_string(),
                membership: "active".into(),
                netmap: Some(netmap),
                settings: None,
                model_policy: Vec::new(),
            },
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ed25519_dalek::{Signer, SigningKey};
    use std::net::SocketAddr;
    use std::path::Path;
    use teale_protocol::{canonical_json, PinNetmap, PinNetmapMember};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn gateway_key() -> SigningKey {
        SigningKey::from_bytes(&[77u8; 32])
    }

    fn signed_netmap(generation: i64, members: Vec<PinNetmapMember>) -> SignedPinNetmap {
        let netmap = PinNetmap {
            pin_id: "pin-hou".into(),
            name: "Hou".into(),
            generation,
            issued_at: crate::gateway_wallet::now_unix_secs() as i64,
            members,
        };
        let key = gateway_key();
        let message = canonical_json(&netmap).unwrap();
        SignedPinNetmap {
            gateway_pubkey: hex::encode(key.verifying_key().as_bytes()),
            signature: hex::encode(key.sign(&message).to_bytes()),
            netmap,
        }
    }

    fn member(wg: &str, disabled: bool, serves: bool, models: &[&str]) -> PinNetmapMember {
        PinNetmapMember {
            device_id: format!("dev-{wg}"),
            node_pubkey: "ab".repeat(32),
            wg_pubkey: wg.repeat(32),
            display_name: None,
            serves_models: serves,
            disabled,
            endpoints: vec![],
            loaded_models: models.iter().map(|s| s.to_string()).collect(),
            last_seen: None,
        }
    }

    /// Minimal canned-response HTTP server: routes by (method, path prefix).
    /// `netmap_body` is served on sync; poisoning it after the first sync
    /// simulates a tampered gateway.
    async fn mock_gateway(
        netmap: Arc<Mutex<SignedPinNetmap>>,
        join_count: Arc<Mutex<u32>>,
        memberships_json: Arc<Mutex<String>>,
    ) -> SocketAddr {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            loop {
                let Ok((mut stream, _)) = listener.accept().await else {
                    break;
                };
                let netmap = netmap.clone();
                let join_count = join_count.clone();
                let memberships_json = memberships_json.clone();
                tokio::spawn(async move {
                    let mut buf = vec![0u8; 65536];
                    let Ok(len) = stream.read(&mut buf).await else {
                        return;
                    };
                    let request = String::from_utf8_lossy(&buf[..len]).to_string();
                    let first_line = request.lines().next().unwrap_or("").to_string();
                    let body = if first_line.contains("/v1/auth/device/challenge") {
                        format!(
                            r#"{{"nonce":"bm9uY2U=","expiresAt":{}}}"#,
                            crate::gateway_wallet::now_unix_secs() + 300
                        )
                    } else if first_line.contains("/v1/auth/device/exchange") {
                        format!(
                            r#"{{"token":"tok_test","expiresAt":{}}}"#,
                            crate::gateway_wallet::now_unix_secs() + 86400
                        )
                    } else if first_line.contains("/v1/pins/join") {
                        *join_count.lock() += 1;
                        r#"{"status":"submitted"}"#.to_string()
                    } else if first_line.contains("/sync") {
                        let signed = netmap.lock().clone();
                        serde_json::json!({
                            "membership": "active",
                            "netmap": signed,
                            "modelPolicy": [],
                            "settings": {"priorityPolicy": "pin_first"},
                        })
                        .to_string()
                    } else if first_line.contains("/v1/pins") {
                        memberships_json.lock().clone()
                    } else {
                        "{}".to_string()
                    };
                    let response = format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{}",
                        body.len(),
                        body
                    );
                    let _ = stream.write_all(response.as_bytes()).await;
                });
            }
        });
        addr
    }

    fn temp_dir() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("pin-mgr-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn test_manager(addr: SocketAddr, dir: &Path) -> Arc<PinManager> {
        PinManager::new(
            format!("http://{addr}"),
            Arc::new(NodeIdentity::load_or_create_in(dir.join("id.key")).unwrap()),
            dir.join("pin"),
            None,
        )
        .unwrap()
    }

    #[tokio::test]
    async fn sync_tofu_pins_verifies_and_caches() {
        let netmap = Arc::new(Mutex::new(signed_netmap(
            1,
            vec![member("aa", false, true, &["qwen3-4b"])],
        )));
        let joins = Arc::new(Mutex::new(0));
        let memberships = Arc::new(Mutex::new(
            r#"{"staff":[],"memberships":[{"pinId":"pin-hou","name":"Hou","status":"active"}]}"#
                .to_string(),
        ));
        let addr = mock_gateway(netmap.clone(), joins, memberships).await;
        let dir = temp_dir();
        let manager = test_manager(addr, &dir);

        let synced = manager
            .sync_once(&SyncAdvertisement::default())
            .await
            .unwrap();
        assert_eq!(synced, 1);
        // TOFU pinned + netmap cached to disk.
        assert!(dir.join("pin/gateway.pub").exists());
        assert!(dir.join("pin/pin-hou/netmap.json").exists());
        let snapshot = manager.snapshot();
        assert_eq!(snapshot.len(), 1);
        assert_eq!(snapshot[0].netmap.as_ref().unwrap().netmap.generation, 1);

        // A netmap signed by a DIFFERENT key must be rejected (TOFU pin).
        let attacker = SigningKey::from_bytes(&[66u8; 32]);
        let mut forged = signed_netmap(2, vec![member("bb", false, true, &[])]);
        let message = canonical_json(&forged.netmap).unwrap();
        forged.gateway_pubkey = hex::encode(attacker.verifying_key().as_bytes());
        forged.signature = hex::encode(attacker.sign(&message).to_bytes());
        *netmap.lock() = forged;
        let result = manager.sync_once(&SyncAdvertisement::default()).await;
        assert!(result.is_err(), "forged netmap must fail the sync");
        // Cached netmap unchanged.
        assert_eq!(
            manager.snapshot()[0]
                .netmap
                .as_ref()
                .unwrap()
                .netmap
                .generation,
            1
        );
    }

    #[tokio::test]
    async fn preseed_join_only_when_unaffiliated() {
        let netmap = Arc::new(Mutex::new(signed_netmap(1, vec![])));
        let joins = Arc::new(Mutex::new(0));
        let memberships = Arc::new(Mutex::new(r#"{"staff":[],"memberships":[]}"#.to_string()));
        let addr = mock_gateway(netmap, joins.clone(), memberships.clone()).await;
        let dir = temp_dir();
        let manager = test_manager(addr, &dir);

        manager
            .preseed_join_if_needed("HOUX-CODE-01")
            .await
            .unwrap();
        assert_eq!(*joins.lock(), 1, "unaffiliated device knocks");

        *memberships.lock() =
            r#"{"staff":[],"memberships":[{"pinId":"pin-hou","name":"Hou","status":"pending"}]}"#
                .to_string();
        manager
            .preseed_join_if_needed("HOUX-CODE-01")
            .await
            .unwrap();
        assert_eq!(*joins.lock(), 1, "pending membership suppresses re-knock");
    }

    #[tokio::test]
    async fn authorizer_and_peer_lookup_respect_netmap() {
        let netmap = Arc::new(Mutex::new(signed_netmap(
            1,
            vec![
                member("aa", false, true, &["qwen3-4b"]),
                member("bb", true, true, &["qwen3-4b"]), // disabled
                member("cc", false, false, &["qwen3-4b"]), // consumer only
            ],
        )));
        let joins = Arc::new(Mutex::new(0));
        let memberships = Arc::new(Mutex::new(
            r#"{"staff":[],"memberships":[{"pinId":"pin-hou","name":"Hou","status":"active"}]}"#
                .to_string(),
        ));
        let addr = mock_gateway(netmap, joins, memberships).await;
        let dir = temp_dir();
        let manager = test_manager(addr, &dir);
        manager
            .sync_once(&SyncAdvertisement::default())
            .await
            .unwrap();

        let authorize = manager.authorizer();
        let key = |byte: &str| {
            PublicKey::from(
                <[u8; 32]>::try_from(hex::decode(byte.repeat(32)).unwrap().as_slice()).unwrap(),
            )
        };
        assert!(authorize(&key("aa")), "active member allowed");
        assert!(!authorize(&key("bb")), "disabled member denied");
        assert!(
            authorize(&key("cc")),
            "consumer-only member may still dial us"
        );
        assert!(!authorize(&key("dd")), "unknown key denied");

        let peers = manager.serving_peers_for_model("qwen3-4b");
        assert_eq!(peers.len(), 1, "only active serving members are candidates");
        assert_eq!(peers[0].1.wg_pubkey, "aa".repeat(32));
        assert!(manager.serving_peers_for_model("missing-model").is_empty());
    }
}
