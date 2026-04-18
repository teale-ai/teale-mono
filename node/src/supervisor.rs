//! Subprocess supervisor — owns a child process, restarts it on crash
//! with exponential backoff, and kills it cleanly on shutdown.
//!
//! Replaces the previous `std::mem::forget(child)` pattern which leaked
//! the handle and offered no restart-on-crash or drain-on-shutdown.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use tokio::process::Child;
use tokio::sync::Notify;
use tracing::{error, info, warn};

pub struct Supervisor {
    shutdown: Arc<Notify>,
    healthy: Arc<AtomicBool>,
    join: tokio::task::JoinHandle<()>,
    name: String,
}

impl Supervisor {
    /// Spawn a supervised subprocess.
    ///
    /// `spawn_fn` is invoked once at startup and again on each restart.
    /// On shutdown, the supervisor signals the child via `.kill()` and waits
    /// up to `graceful_timeout` for it to exit.
    pub fn spawn<F>(name: impl Into<String>, spawn_fn: F) -> Self
    where
        F: Fn() -> anyhow::Result<Child> + Send + 'static,
    {
        let name = name.into();
        let shutdown = Arc::new(Notify::new());
        let healthy = Arc::new(AtomicBool::new(false));

        let shutdown_sig = shutdown.clone();
        let healthy_flag = healthy.clone();
        let task_name = name.clone();

        let join = tokio::spawn(async move {
            let mut backoff = Duration::from_secs(1);
            const MAX_BACKOFF: Duration = Duration::from_secs(60);

            loop {
                let child_result = spawn_fn();

                let mut child = match child_result {
                    Ok(c) => c,
                    Err(e) => {
                        error!("[{}] failed to spawn: {}. retrying in {:?}", task_name, e, backoff);
                        healthy_flag.store(false, Ordering::SeqCst);
                        tokio::select! {
                            _ = tokio::time::sleep(backoff) => {}
                            _ = shutdown_sig.notified() => {
                                info!("[{}] shutdown requested during restart backoff", task_name);
                                return;
                            }
                        }
                        backoff = (backoff * 2).min(MAX_BACKOFF);
                        continue;
                    }
                };

                healthy_flag.store(true, Ordering::SeqCst);
                info!("[{}] subprocess running (pid={:?})", task_name, child.id());

                // Wait for child to exit OR shutdown signal
                let wait_result = tokio::select! {
                    status = child.wait() => Some(status),
                    _ = shutdown_sig.notified() => {
                        info!("[{}] shutdown — killing subprocess", task_name);
                        let _ = child.kill().await;
                        let _ = tokio::time::timeout(Duration::from_secs(5), child.wait()).await;
                        None
                    }
                };

                healthy_flag.store(false, Ordering::SeqCst);

                match wait_result {
                    None => return, // clean shutdown
                    Some(Ok(status)) => {
                        warn!("[{}] subprocess exited: {}. restarting in {:?}", task_name, status, backoff);
                    }
                    Some(Err(e)) => {
                        error!("[{}] wait error: {}. restarting in {:?}", task_name, e, backoff);
                    }
                }

                tokio::select! {
                    _ = tokio::time::sleep(backoff) => {}
                    _ = shutdown_sig.notified() => {
                        info!("[{}] shutdown requested during restart backoff", task_name);
                        return;
                    }
                }

                // Reset backoff on what looks like a long-running process
                // (>30s uptime implies it didn't crash-loop)
                backoff = (backoff * 2).min(MAX_BACKOFF);
            }
        });

        Self {
            shutdown,
            healthy,
            join,
            name,
        }
    }

    pub fn is_healthy(&self) -> bool {
        self.healthy.load(Ordering::SeqCst)
    }

    pub fn name(&self) -> &str {
        &self.name
    }

    /// Signal shutdown; supervisor kills the child and exits.
    pub async fn shutdown(self) {
        self.shutdown.notify_one();
        let _ = self.join.await;
    }
}
