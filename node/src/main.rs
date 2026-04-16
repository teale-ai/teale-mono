mod cluster;
mod config;
mod hardware;
mod identity;
mod inference;
mod relay;

use clap::Parser;
use serde_json::Value;
use tracing::{error, info, warn};

use crate::config::Config;
use crate::hardware::{build_capabilities, detect_hardware};
use crate::identity::NodeIdentity;
use crate::inference::{spawn_llama_server, spawn_mnn_server, InferenceProxy};
use crate::relay::{IncomingRelayMessage, RelayClient};

#[derive(Parser)]
#[command(name = "teale-node", about = "Cross-platform TealeNet supply node agent")]
struct Args {
    /// Path to config file (TOML)
    #[arg(short, long, default_value = "teale-node.toml")]
    config: String,

    /// Skip launching inference backend (connect to existing instance)
    #[arg(long, alias = "no-llama")]
    no_backend: bool,

    /// Override display name
    #[arg(long)]
    name: Option<String>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = Args::parse();
    let config = Config::load(&args.config)?;

    info!("teale-node v{}", env!("CARGO_PKG_VERSION"));

    // 1. Load or generate identity
    let identity = NodeIdentity::load_or_create()?;
    info!("Node ID: {}", identity.node_id());

    // 2. Detect hardware
    let hw = detect_hardware(&config.node);
    info!(
        "Hardware: {} ({}) — {:.1} GB RAM, tier {}",
        hw.chip_name, hw.chip_family, hw.total_ram_gb, hw.tier
    );

    // 3. Start inference backend (unless --no-backend)
    let (port, model_id) = match config.backend.as_str() {
        "mnn" => {
            let mnn = config.mnn.as_ref().unwrap();
            let mid = mnn.model_id.clone().unwrap_or_else(|| {
                std::path::Path::new(&mnn.model_dir)
                    .file_name()
                    .map(|f| f.to_string_lossy().to_string())
                    .unwrap_or_else(|| mnn.model_dir.clone())
            });
            (mnn.port, mid)
        }
        _ => {
            let llama = config.llama.as_ref().unwrap();
            (llama.port, llama.model.clone())
        }
    };
    let inference = InferenceProxy::new(port, &model_id);

    let _backend_child = if !args.no_backend {
        let child = match config.backend.as_str() {
            "mnn" => spawn_mnn_server(config.mnn.as_ref().unwrap())?,
            _ => spawn_llama_server(config.llama.as_ref().unwrap())?,
        };
        info!("Waiting for {} to become healthy...", config.backend);
        inference.wait_for_health(120).await?;
        Some(child)
    } else {
        info!("Skipping backend launch (--no-backend), connecting to port {}", port);
        inference.wait_for_health(10).await?;
        None
    };

    // 4. Build capabilities
    let capabilities = build_capabilities(hw, Some(&model_id));

    // 5. Build device info for hello/helloAck responses
    let device_info = build_device_info(&config, &identity, &capabilities);

    // 6. Connect to relay with reconnect loop
    let display_name = args.name.unwrap_or(config.node.display_name.clone());

    loop {
        match run_relay_session(&config.relay.url, &identity, &display_name, &capabilities, &inference, &device_info).await {
            Ok(()) => {
                info!("Relay session ended cleanly");
                break;
            }
            Err(e) => {
                error!("Relay session error: {}. Reconnecting in 5s...", e);
                tokio::time::sleep(tokio::time::Duration::from_secs(5)).await;
            }
        }
    }

    Ok(())
}

async fn run_relay_session(
    relay_url: &str,
    identity: &NodeIdentity,
    display_name: &str,
    capabilities: &hardware::NodeCapabilities,
    inference: &InferenceProxy,
    device_info: &Value,
) -> anyhow::Result<()> {
    let (relay, mut incoming) = RelayClient::connect(relay_url, identity).await?;

    // Register with relay
    relay.register(identity, display_name, capabilities)?;

    // Wait for registerAck, then discover
    info!("Waiting for relay messages...");

    while let Some(msg) = incoming.recv().await {
        match msg {
            IncomingRelayMessage::RegisterAck { node_id } => {
                info!("Registered with relay (nodeID: {}...)", &node_id[..16.min(node_id.len())]);
                relay.discover()?;
            }

            IncomingRelayMessage::DiscoverResponse { peers } => {
                info!("Discovered {} peer(s)", peers.len());
                for peer in &peers {
                    if let Some(name) = peer.get("displayName").and_then(|v| v.as_str()) {
                        let node = peer.get("nodeID").and_then(|v| v.as_str()).unwrap_or("?");
                        info!("  Peer: {} ({}...)", name, &node[..16.min(node.len())]);
                    }
                }
            }

            IncomingRelayMessage::RelayOpen(session) => {
                info!(
                    "Relay session opened by {}... (session: {}...)",
                    &session.from_node_id[..16.min(session.from_node_id.len())],
                    &session.session_id[..8.min(session.session_id.len())]
                );
                // Accept the session
                relay.send_relay_ready(&session.from_node_id, &session.session_id)?;
            }

            IncomingRelayMessage::RelayData(data) => {
                cluster::handle_relay_data(&relay, &data, inference, device_info).await;
            }

            IncomingRelayMessage::RelayClose(session) => {
                info!(
                    "Relay session closed: {}...",
                    &session.session_id[..8.min(session.session_id.len())]
                );
            }

            IncomingRelayMessage::PeerJoined(peer) => {
                info!("Peer joined: {} ({}...)", peer.display_name, &peer.node_id[..16.min(peer.node_id.len())]);
            }

            IncomingRelayMessage::PeerLeft(peer) => {
                info!("Peer left: {} ({}...)", peer.display_name, &peer.node_id[..16.min(peer.node_id.len())]);
            }

            IncomingRelayMessage::Error(err) => {
                error!("Relay error: {} — {}", err.code, err.message);
            }

            IncomingRelayMessage::Unknown(kind) => {
                warn!("Unknown relay message type: {}", kind);
            }

            _ => {}
        }
    }

    Err(anyhow::anyhow!("Relay connection lost"))
}

fn build_device_info(config: &Config, _identity: &NodeIdentity, capabilities: &hardware::NodeCapabilities) -> Value {
    serde_json::json!({
        "id": uuid::Uuid::new_v4().to_string(),
        "name": config.node.display_name,
        "hardware": capabilities.hardware,
        "registeredAt": cluster::now_reference_seconds(),
        "lastSeenAt": cluster::now_reference_seconds(),
        "isCurrentDevice": true,
        "loadedModels": capabilities.loaded_models
    })
}
