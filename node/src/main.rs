mod backend;
mod cluster;
mod config;
mod hardware;
mod identity;
mod inference;
mod litert;
mod relay;
mod supervisor;
mod swap;

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::Duration;

use clap::Parser;
use serde_json::Value;
use tokio::sync::Notify;
use tracing::{error, info, warn};

use teale_protocol::IncomingRelayMessage;

use crate::backend::Backend;
use crate::cluster::NodeRuntimeState;
use crate::config::Config;
use crate::hardware::{build_capabilities, detect_hardware};
use crate::identity::NodeIdentity;
use crate::inference::{build_llama_command, build_mnn_command, InferenceProxy};
use crate::relay::RelayClient;
use crate::supervisor::Supervisor;
use crate::swap::{ModelSlot, SwapManager};

#[derive(Parser)]
#[command(
    name = "teale-node",
    about = "Cross-platform TealeNet supply node agent"
)]
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
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .init();

    let args = Args::parse();
    let config = Config::load(&args.config)?;

    info!("teale-node v{}", env!("CARGO_PKG_VERSION"));

    let identity = NodeIdentity::load_or_create()?;
    info!("Node ID: {}", identity.node_id());

    let hw = detect_hardware(&config.node);
    info!(
        "Hardware: {} ({}) — {:.1} GB RAM, tier {}",
        hw.chip_name, hw.chip_family, hw.total_ram_gb, hw.tier
    );

    let state = Arc::new(NodeRuntimeState::new(config.node.max_concurrent_requests));
    info!(
        "Runtime: max_concurrent={}, heartbeat_every={}s, shutdown_timeout={}s",
        config.node.max_concurrent_requests,
        config.node.heartbeat_interval_seconds,
        config.node.shutdown_timeout_seconds
    );

    // Start inference backend (supervised — restarts on crash).
    let (backend, model_id, supervisor_opt) = start_backend(&config, &args).await?;

    // Build the SwapManager: owns the current backend + supervisor and can
    // swap to any of `config.node.swappable_models` on `loadModel` requests.
    // For non-Ultra nodes this is still constructed but with an empty
    // whitelist — `loadModel` then always returns NotInWhitelist cleanly.
    let llama_base = config.llama.clone().unwrap_or_else(default_llama_stub);
    let swap_slots: Vec<ModelSlot> = config
        .node
        .swappable_models
        .iter()
        .map(|e| ModelSlot::parse(e))
        .collect();
    let swap_model_ids: Vec<String> = swap_slots.iter().map(|s| s.model_id.clone()).collect();
    let swap_manager = SwapManager::new(
        backend,
        supervisor_opt,
        model_id.clone(),
        llama_base,
        swap_slots,
        state.clone(),
    );
    info!(
        "SwapManager ready (loaded={}, swappable={})",
        model_id,
        swap_model_ids.len()
    );

    let capabilities = build_capabilities(
        hw,
        Some(&model_id),
        config.node.max_concurrent_requests,
        swap_model_ids,
    );

    let device_info = build_device_info(&config, &identity, &capabilities);

    let display_name = args
        .name
        .unwrap_or_else(|| config.node.display_name.clone());

    // Signal handling — set state.shutting_down on SIGINT/SIGTERM.
    let shutdown_signal = Arc::new(Notify::new());
    install_signal_handlers(state.clone(), shutdown_signal.clone());

    // Reconnect loop
    loop {
        if state.shutting_down.load(Ordering::Relaxed) {
            break;
        }

        let session_result = run_relay_session(
            &config,
            &identity,
            &display_name,
            &capabilities,
            &swap_manager,
            &state,
            &device_info,
            shutdown_signal.clone(),
        )
        .await;

        if state.shutting_down.load(Ordering::Relaxed) {
            info!("Shutdown requested — not reconnecting");
            break;
        }

        match session_result {
            Ok(()) => {
                info!("Relay session ended cleanly");
                break;
            }
            Err(e) => {
                error!("Relay session error: {}. Reconnecting in 5s...", e);
                tokio::select! {
                    _ = tokio::time::sleep(Duration::from_secs(5)) => {}
                    _ = shutdown_signal.notified() => {
                        info!("Shutdown requested during backoff");
                        break;
                    }
                }
            }
        }
    }

    // Graceful shutdown: drain in-flight requests up to `shutdown_timeout_seconds`.
    drain_in_flight(&state, config.node.shutdown_timeout_seconds).await;

    // Kill the current subprocess cleanly via the swap manager.
    info!("shutting down swap manager");
    swap_manager.shutdown().await;

    info!("teale-node exited cleanly");
    Ok(())
}

fn default_llama_stub() -> config::LlamaConfig {
    // Used only as a template when non-llama backends are active, so that
    // SwapManager still constructs. It won't ever be used to spawn because
    // the whitelist is empty for non-llama backends.
    config::LlamaConfig {
        binary: "llama-server".to_string(),
        model: "".to_string(),
        model_id: None,
        gpu_layers: 999,
        context_size: 4096,
        port: 11436,
        extra_args: vec![],
    }
}

async fn start_backend(
    config: &Config,
    args: &Args,
) -> anyhow::Result<(Backend, String, Option<Supervisor>)> {
    match config.backend.as_str() {
        "litert" => {
            let litert_config = config.litert.as_ref().unwrap();
            let engine = litert::LiteRtEngine::new(litert_config)?;
            let model_id = engine
                .loaded_models()
                .into_iter()
                .next()
                .unwrap_or_default();
            Ok((Backend::LiteRt(engine), model_id, None))
        }

        backend_name => {
            let (port, model_id) = match backend_name {
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
                    (llama.port, llama.resolved_model_id())
                }
            };

            let inference = InferenceProxy::new(port, &model_id);

            let supervisor_opt = if args.no_backend {
                info!(
                    "--no-backend set, connecting to existing backend on port {}",
                    port
                );
                inference.wait_for_health(10).await?;
                None
            } else {
                let sup = match backend_name {
                    "mnn" => {
                        let mnn = config.mnn.as_ref().unwrap().clone();
                        Supervisor::spawn("mnn_llm", move || {
                            let mut cmd = build_mnn_command(&mnn)?;
                            let mut child = cmd
                                .spawn()
                                .map_err(|e| anyhow::anyhow!("spawn mnn_llm: {}", e))?;
                            attach_stderr_logger(&mut child, "mnn_llm");
                            Ok(child)
                        })
                    }
                    _ => {
                        let llama = config.llama.as_ref().unwrap().clone();
                        Supervisor::spawn("llama-server", move || {
                            let mut cmd = build_llama_command(&llama)?;
                            let mut child = cmd
                                .spawn()
                                .map_err(|e| anyhow::anyhow!("spawn llama-server: {}", e))?;
                            attach_stderr_logger(&mut child, "llama-server");
                            Ok(child)
                        })
                    }
                };
                info!("Waiting for {} to become healthy...", backend_name);
                inference.wait_for_health(120).await?;
                Some(sup)
            };

            Ok((Backend::Http(inference), model_id, supervisor_opt))
        }
    }
}

fn attach_stderr_logger(child: &mut tokio::process::Child, tag: &'static str) {
    use tokio::io::{AsyncBufReadExt, BufReader};
    if let Some(stderr) = child.stderr.take() {
        tokio::spawn(async move {
            let reader = BufReader::new(stderr);
            let mut lines = reader.lines();
            while let Ok(Some(line)) = lines.next_line().await {
                tracing::info!("[{}] {}", tag, line);
            }
        });
    }
}

async fn run_relay_session(
    config: &Config,
    identity: &NodeIdentity,
    display_name: &str,
    capabilities: &teale_protocol::NodeCapabilities,
    swap: &Arc<SwapManager>,
    state: &Arc<NodeRuntimeState>,
    device_info: &Value,
    shutdown_signal: Arc<Notify>,
) -> anyhow::Result<()> {
    let (relay, mut incoming) = RelayClient::connect(&config.relay.url, identity).await?;
    let relay = Arc::new(relay);

    relay.register(identity, display_name, capabilities)?;

    // Periodic re-register: keeps relay's capability cache fresh for the gateway's
    // `discover` poll. Cheap (few hundred bytes per interval) and simpler than
    // introducing a new broadcast message type the relay would have to understand.
    let heartbeat_task = {
        let relay = relay.clone();
        let identity_hex = identity.node_id();
        let signature = identity.sign_node_id();
        let pubkey = identity.public_key_hex();
        let display_name = display_name.to_string();
        let capabilities = capabilities.clone();
        let interval = config.node.heartbeat_interval_seconds;
        let state = state.clone();
        let swap = swap.clone();
        tokio::spawn(async move {
            let mut ticker = tokio::time::interval(Duration::from_secs(interval));
            ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            ticker.tick().await; // consume the immediate first tick
            loop {
                ticker.tick().await;
                if state.shutting_down.load(Ordering::Relaxed) {
                    break;
                }
                // Rebuild capabilities snapshot with live model list + runtime state.
                let mut snapshot = capabilities.clone();
                snapshot.loaded_models = swap.loaded_models().await;
                snapshot.is_available = !state.shutting_down.load(Ordering::Relaxed);
                let payload = serde_json::json!({
                    "register": {
                        "nodeID": identity_hex,
                        "publicKey": pubkey,
                        "displayName": display_name,
                        "capabilities": snapshot,
                        "signature": signature
                    }
                });
                if let Err(e) = relay.send_cluster_message(&identity_hex, "", &payload) {
                    tracing::warn!("heartbeat re-register send failed: {}", e);
                    break;
                }
                tracing::trace!(
                    "heartbeat tick: queue_depth={}, is_generating={}, ewma_tps={:?}",
                    state.queue_depth.load(Ordering::Relaxed),
                    state.is_generating.load(Ordering::Relaxed),
                    state.ewma_tokens_per_second(),
                );
            }
        })
    };

    info!("Waiting for relay messages...");

    let result = loop {
        tokio::select! {
            _ = shutdown_signal.notified() => {
                info!("Shutdown signal received inside relay loop");
                break Ok(());
            }
            msg_opt = incoming.recv() => {
                let Some(msg) = msg_opt else {
                    break Err(anyhow::anyhow!("Relay connection lost"));
                };
                dispatch(&relay, msg, swap, state, device_info).await;
            }
        }
    };

    heartbeat_task.abort();
    result
}

async fn dispatch(
    relay: &Arc<RelayClient>,
    msg: IncomingRelayMessage,
    swap: &Arc<SwapManager>,
    state: &Arc<NodeRuntimeState>,
    device_info: &Value,
) {
    match msg {
        IncomingRelayMessage::RegisterAck { node_id } => {
            info!(
                "Registered with relay (nodeID: {}...)",
                &node_id[..16.min(node_id.len())]
            );
            let _ = relay.discover();
        }

        IncomingRelayMessage::DiscoverResponse { peers } => {
            info!("Discovered {} peer(s)", peers.len());
        }

        IncomingRelayMessage::RelayOpen(session) => {
            info!(
                "Relay session opened by {}... (session: {}...)",
                &session.from_node_id[..16.min(session.from_node_id.len())],
                &session.session_id[..8.min(session.session_id.len())]
            );
            if let Err(e) = relay.send_relay_ready(&session.from_node_id, &session.session_id) {
                error!("send relayReady: {}", e);
            }
        }

        IncomingRelayMessage::RelayData(data) => {
            cluster::handle_relay_data(relay, &data, swap, state, device_info).await;
        }

        IncomingRelayMessage::RelayClose(session) => {
            info!(
                "Relay session closed: {}...",
                &session.session_id[..8.min(session.session_id.len())]
            );
        }

        IncomingRelayMessage::PeerJoined(peer) => {
            info!(
                "Peer joined: {} ({}...)",
                peer.display_name,
                &peer.node_id[..16.min(peer.node_id.len())]
            );
        }

        IncomingRelayMessage::PeerLeft(peer) => {
            info!(
                "Peer left: {} ({}...)",
                peer.display_name,
                &peer.node_id[..16.min(peer.node_id.len())]
            );
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

fn build_device_info(
    config: &Config,
    _identity: &NodeIdentity,
    capabilities: &teale_protocol::NodeCapabilities,
) -> Value {
    serde_json::json!({
        "id": uuid::Uuid::new_v4().to_string(),
        "name": config.node.display_name,
        "hardware": capabilities.hardware,
        "registeredAt": teale_protocol::now_reference_seconds(),
        "lastSeenAt": teale_protocol::now_reference_seconds(),
        "isCurrentDevice": true,
        "loadedModels": capabilities.loaded_models
    })
}

fn install_signal_handlers(state: Arc<NodeRuntimeState>, notify: Arc<Notify>) {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{signal, SignalKind};
        let state_sigint = state.clone();
        let notify_sigint = notify.clone();
        tokio::spawn(async move {
            let mut sigterm = match signal(SignalKind::terminate()) {
                Ok(s) => s,
                Err(e) => {
                    error!("Failed to install SIGTERM handler: {}", e);
                    return;
                }
            };
            let mut sigint = match signal(SignalKind::interrupt()) {
                Ok(s) => s,
                Err(e) => {
                    error!("Failed to install SIGINT handler: {}", e);
                    return;
                }
            };
            tokio::select! {
                _ = sigterm.recv() => {
                    warn!("SIGTERM received — initiating graceful shutdown");
                }
                _ = sigint.recv() => {
                    warn!("SIGINT received — initiating graceful shutdown");
                }
            }
            state_sigint.shutting_down.store(true, Ordering::SeqCst);
            notify_sigint.notify_waiters();
        });
    }

    #[cfg(windows)]
    {
        let state_win = state.clone();
        let notify_win = notify.clone();
        tokio::spawn(async move {
            if tokio::signal::ctrl_c().await.is_ok() {
                warn!("Ctrl-C received — initiating graceful shutdown");
                state_win.shutting_down.store(true, Ordering::SeqCst);
                notify_win.notify_waiters();
            }
        });
    }
}

async fn drain_in_flight(state: &Arc<NodeRuntimeState>, timeout_seconds: u64) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(timeout_seconds);
    let mut poll = tokio::time::interval(Duration::from_millis(250));

    loop {
        let queue = state.queue_depth.load(Ordering::Relaxed);
        if queue == 0 {
            info!("No in-flight requests — shutdown complete");
            return;
        }
        if tokio::time::Instant::now() > deadline {
            warn!(
                "Shutdown deadline reached with {} request(s) still in flight — forcing exit",
                queue
            );
            return;
        }
        info!("Draining: {} request(s) in flight", queue);
        poll.tick().await;
    }
}
