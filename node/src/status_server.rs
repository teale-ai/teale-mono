//! Localhost HTTP endpoint for the tray app.
//!
//! Bound to `127.0.0.1:11437` only — NOT exposed to the network. The tray
//! process (per-user, `teale-tray.exe`) polls this every few seconds to
//! decide which icon color to show and what tooltip text to render.
//!
//! Endpoints:
//!   GET  /status   → JSON summary (state, requests_today, credits_today, on_ac)
//!   POST /pause    → user-requested pause; sets an atomic flag the
//!                    supervisor reads before accepting new requests
//!   POST /resume   → clear the user-pause flag
//!
//! This is deliberately simple: one tiny hyper service, no auth (localhost
//! only), no metrics middleware. If the port collides, the status server
//! logs a warning and exits — the node keeps serving inference; only the
//! tray UX degrades to "Disconnected."

use std::convert::Infallible;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_json::json;
use tracing::{info, warn};

/// Shared counters and flags between the node's inference path and the
/// status server. Cloneable-as-Arc on the outside; caller passes a clone
/// into `spawn()` and keeps one for the serving loop to update.
#[derive(Clone, Default)]
pub struct StatusState {
    pub requests_today: Arc<AtomicU64>,
    pub credits_today: Arc<std::sync::atomic::AtomicI64>,
    /// Epoch-seconds the node started supplying. Zero = not yet serving.
    pub supplying_since: Arc<AtomicU64>,
    pub user_paused: Arc<AtomicBool>,
    pub on_ac: Arc<AtomicBool>,
    /// "supplying" | "paused" | "error" — flipped by the main supervisor
    /// loop when relay connection drops etc.
    pub state: Arc<parking_lot::RwLock<String>>,
    pub paused_reason: Arc<parking_lot::RwLock<Option<String>>>,
}

impl StatusState {
    pub fn new() -> Self {
        Self {
            state: Arc::new(parking_lot::RwLock::new("supplying".to_string())),
            on_ac: Arc::new(AtomicBool::new(true)),
            ..Default::default()
        }
    }

    pub fn set_state(&self, state: &str, paused_reason: Option<&str>) {
        *self.state.write() = state.to_string();
        *self.paused_reason.write() = paused_reason.map(|s| s.to_string());
    }

    pub fn mark_supplying_now(&self) {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        self.supplying_since.store(now, Ordering::SeqCst);
    }
}

#[derive(Serialize)]
struct StatusDTO<'a> {
    state: &'a str,
    supplying_since: Option<String>,
    requests_today: u64,
    credits_today: i64,
    on_ac: bool,
    paused_reason: Option<&'a str>,
}

pub fn spawn(state: StatusState, port: u16) {
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
    state: StatusState,
) -> Result<(), Infallible> {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    let mut buf = [0u8; 1024];
    let n = match stream.read(&mut buf).await {
        Ok(n) => n,
        Err(_) => return Ok(()),
    };
    let req = String::from_utf8_lossy(&buf[..n]);
    let first_line = req.lines().next().unwrap_or("");
    let mut parts = first_line.split_whitespace();
    let method = parts.next().unwrap_or("");
    let path = parts.next().unwrap_or("");

    let (status, body, ctype) = match (method, path) {
        ("GET", "/status") => {
            let state_str = state.state.read().clone();
            let reason_owned = state.paused_reason.read().clone();
            let supplying_since = match state.supplying_since.load(Ordering::SeqCst) {
                0 => None,
                secs => Some(format!("{secs}")),
            };
            let dto = StatusDTO {
                state: &state_str,
                supplying_since,
                requests_today: state.requests_today.load(Ordering::SeqCst),
                credits_today: state.credits_today.load(Ordering::SeqCst),
                on_ac: state.on_ac.load(Ordering::SeqCst),
                paused_reason: reason_owned.as_deref(),
            };
            let body = serde_json::to_string(&dto).unwrap_or_else(|_| "{}".into());
            ("200 OK", body, "application/json")
        }
        ("POST", "/pause") => {
            state.user_paused.store(true, Ordering::SeqCst);
            state.set_state("paused", Some("user"));
            let body = json!({ "ok": true, "state": "paused" }).to_string();
            ("200 OK", body, "application/json")
        }
        ("POST", "/resume") => {
            state.user_paused.store(false, Ordering::SeqCst);
            // Don't force-switch to "supplying" — let the supervisor reflect
            // the true state (could be paused for battery or error).
            let body = json!({ "ok": true }).to_string();
            ("200 OK", body, "application/json")
        }
        _ => ("404 Not Found", "{}".to_string(), "application/json"),
    };

    let response = format!(
        "HTTP/1.1 {status}\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
    Ok(())
}
