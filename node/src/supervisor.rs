//! Subprocess supervisor — owns a child process, restarts it on crash
//! with exponential backoff, and kills it cleanly on shutdown.
//!
//! Replaces the previous `std::mem::forget(child)` pattern which leaked
//! the handle and offered no restart-on-crash or drain-on-shutdown.

use std::sync::Arc;
use std::time::{Duration, Instant};

use tokio::process::Child;
use tokio::sync::Notify;
use tracing::{error, info, warn};

const INITIAL_BACKOFF: Duration = Duration::from_secs(1);
const MAX_BACKOFF: Duration = Duration::from_secs(60);
/// A child that stayed up at least this long did not crash-loop: its next
/// restart starts again from `INITIAL_BACKOFF`.
const HEALTHY_UPTIME: Duration = Duration::from_secs(30);

/// Restart delay after a child exits, and the backoff to carry forward to the
/// following restart.
fn restart_delay(current: Duration, uptime: Duration) -> (Duration, Duration) {
    let delay = if uptime >= HEALTHY_UPTIME {
        INITIAL_BACKOFF
    } else {
        current
    };
    (delay, (delay * 2).min(MAX_BACKOFF))
}

pub struct Supervisor {
    shutdown: Arc<Notify>,
    join: tokio::task::JoinHandle<()>,
    name: String,
}

impl Supervisor {
    /// Spawn a supervised subprocess.
    ///
    /// `spawn_fn` is invoked once at startup and again on each restart.
    /// On shutdown, the supervisor kills the child and waits up to 5 s for it
    /// to exit.
    pub fn spawn<F>(name: impl Into<String>, spawn_fn: F) -> Self
    where
        F: Fn() -> anyhow::Result<Child> + Send + 'static,
    {
        let name = name.into();
        let shutdown = Arc::new(Notify::new());

        let shutdown_sig = shutdown.clone();
        let task_name = name.clone();

        let join = tokio::spawn(async move {
            let mut backoff = INITIAL_BACKOFF;

            loop {
                let child_result = spawn_fn();

                let mut child = match child_result {
                    Ok(c) => c,
                    Err(e) => {
                        error!(
                            "[{}] failed to spawn: {}. retrying in {:?}",
                            task_name, e, backoff
                        );
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

                let started = Instant::now();
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

                let (delay, next_backoff) = restart_delay(backoff, started.elapsed());
                backoff = next_backoff;

                match wait_result {
                    None => return, // clean shutdown
                    Some(Ok(status)) => {
                        warn!(
                            "[{}] subprocess exited: {}. restarting in {:?}",
                            task_name, status, delay
                        );
                    }
                    Some(Err(e)) => {
                        error!(
                            "[{}] wait error: {}. restarting in {:?}",
                            task_name, e, delay
                        );
                    }
                }

                tokio::select! {
                    _ = tokio::time::sleep(delay) => {}
                    _ = shutdown_sig.notified() => {
                        info!("[{}] shutdown requested during restart backoff", task_name);
                        return;
                    }
                }
            }
        });

        Self {
            shutdown,
            join,
            name,
        }
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crash_loop_doubles_backoff_up_to_the_cap() {
        let quick = Duration::from_secs(2);
        let (delay, next) = restart_delay(INITIAL_BACKOFF, quick);
        assert_eq!((delay, next), (Duration::from_secs(1), Duration::from_secs(2)));
        let (delay, next) = restart_delay(next, quick);
        assert_eq!((delay, next), (Duration::from_secs(2), Duration::from_secs(4)));
        let (delay, next) = restart_delay(Duration::from_secs(40), quick);
        assert_eq!((delay, next), (Duration::from_secs(40), MAX_BACKOFF));
        assert_eq!(restart_delay(MAX_BACKOFF, quick).0, MAX_BACKOFF);
    }

    #[test]
    fn healthy_run_resets_backoff() {
        let (delay, next) = restart_delay(MAX_BACKOFF, Duration::from_secs(3600));
        assert_eq!(delay, INITIAL_BACKOFF);
        assert_eq!(next, Duration::from_secs(2));
    }
}
